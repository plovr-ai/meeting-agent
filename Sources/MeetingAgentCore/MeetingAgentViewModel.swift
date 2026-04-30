import Combine
import Foundation

@MainActor
public final class MeetingAgentViewModel: ObservableObject {
    public static let supportedLocaleIdentifiers = [
        "en-US",
        "zh-CN",
        "zh-TW",
        "ja-JP",
        "ko-KR",
        "fr-FR",
        "de-DE",
        "es-ES"
    ]

    @Published public private(set) var meetings: [MeetingRecord] = []
    @Published public private(set) var selectedMeetingID: UUID?
    @Published public private(set) var pendingCandidate: AudioCaptureTarget?
    @Published public private(set) var statusText: String = "Idle"
    @Published public private(set) var speechConfiguration: SpeechTranscriptionConfiguration
    @Published public private(set) var liveCaptionTurns: [LiveCaptionTurn] = []
    @Published public private(set) var meetingProgressState: MeetingProgressState?
    @Published public private(set) var meetingProgressHealth = MeetingProgressHealth(
        caption: .idle,
        translation: .idle,
        analysis: .idle
    )
    @Published public private(set) var activeMeetingID: UUID?
    @Published public private(set) var primaryChainPreflightResult = PrimaryChainPreflightResult(
        status: .unavailable,
        messages: ["Primary chain is not checked"]
    )

    private let store: MeetingStore
    private let speechConfigurationStore: SpeechTranscriptionConfigurationStore
    private let recorder: MeetingRecorder
    private let exportService: MeetingExportService
    private var liveCaptionPipeline: LiveCaptionPipeline
    private var liveCaptionPipelineUsesCaptionTranslationProvider = false
    private var liveCaptionPipelineHasTranslationProvider = false
    private var activeCaptionApplySequence = 0
    private var activeCaptionApplyTask: Task<Void, Never>?
    private var liveCaptionReplayTask: Task<Void, Never>?
    private var liveCaptionReplaySequence = 0
    @Published public private(set) var meetingGoal: MeetingGoal?
    public var recommendedQuestions: [FollowUpQuestionSuggestion] {
        Array((meetingProgressState?.suggestedQuestions ?? []).prefix(2))
    }
    private var meetingProgressCoordinator: MeetingProgressCoordinator?
    private let captionTranslationProviderFactory: (SpeechTranscriptionConfiguration) -> TextTranslationProvider?
    private let summaryProviderFactory: (SpeechTranscriptionConfiguration) -> MeetingSummaryProvider
    private let processTargetsProvider: () -> [AudioCaptureTarget]
    private let processMonitor = MeetingProcessMonitor()
    private var activeTarget: AudioCaptureTarget?

    struct ActiveCaptionApplyContext: Equatable {
        let sequence: Int
        let activeMeetingID: UUID?
        let selectedMeetingID: UUID?
    }

    public init(
        store: MeetingStore = MeetingStore(),
        recorder: MeetingRecorder? = nil,
        speechLocaleIdentifier: String = Locale.current.identifier,
        speechProvider: SpeechProvider = .whisper,
        speechConfiguration: SpeechTranscriptionConfiguration? = nil,
        speechConfigurationStore: SpeechTranscriptionConfigurationStore = SpeechTranscriptionConfigurationStore(),
        exportService: MeetingExportService = MeetingExportService(),
        captionTranslationProviderFactory: @escaping (SpeechTranscriptionConfiguration) -> TextTranslationProvider? = MeetingAgentViewModel.openRouterCaptionTranslationProvider,
        summaryProviderFactory: ((SpeechTranscriptionConfiguration) -> MeetingSummaryProvider)? = nil,
        processTargetsProvider: @escaping () -> [AudioCaptureTarget] = RunningProcessDiscovery.currentTargets
    ) {
        self.store = store
        self.speechConfigurationStore = speechConfigurationStore
        self.recorder = recorder ?? MeetingRecorder(store: store)
        self.exportService = exportService
        self.captionTranslationProviderFactory = captionTranslationProviderFactory
        self.summaryProviderFactory = summaryProviderFactory ?? { configuration in
            Self.summaryProvider(for: configuration)
        }
        self.processTargetsProvider = processTargetsProvider
        let resolvedSpeechConfiguration: SpeechTranscriptionConfiguration
        if let speechConfiguration {
            resolvedSpeechConfiguration = speechConfiguration
        } else if speechProvider != .whisper || speechLocaleIdentifier != Locale.current.identifier {
            resolvedSpeechConfiguration = SpeechTranscriptionConfiguration(
                provider: speechProvider,
                localeIdentifier: speechLocaleIdentifier,
                whisperBinaryPath: nil,
                whisperModelPath: nil
            )
        } else {
            resolvedSpeechConfiguration = (try? speechConfigurationStore.load()) ?? .default
        }
        self.speechConfiguration = resolvedSpeechConfiguration
        liveCaptionPipeline = Self.makeLiveCaptionPipeline(
            configuration: resolvedSpeechConfiguration,
            translationProvider: nil
        )
        refreshPrimaryChainPreflightResult()
    }

    public func loadMeetings() throws {
        meetings = try store.loadMeetings()
        selectedMeetingID = meetings.first?.id
        meetingGoal = selectedMeeting?.meetingGoal
        resetMeetingProgressState()
        restoreMeetingProgressStateForSelectedMeeting()
        configureMeetingProgressCoordinator()
    }

    public func setPendingCandidate(_ target: AudioCaptureTarget) {
        pendingCandidate = target
        statusText = "Meeting detected: \(target.displayName)"
    }

    public func rejectPendingCandidate() {
        pendingCandidate = nil
        statusText = "Idle"
    }

    public func ignorePendingCandidate() {
        if let pendingCandidate {
            processMonitor.ignore(processID: pendingCandidate.processID)
        }
        rejectPendingCandidate()
    }

    public func acceptPendingCandidate(startedAt: Date = Date()) throws {
        guard let candidate = pendingCandidate else { return }
        var record = try recorder.prepareRecord(for: candidate, startedAt: startedAt)
        record.meetingGoal = meetingGoal
        meetings.insert(record, at: 0)
        selectedMeetingID = record.id
        persistMeetingGoalForSelectedMeeting()
        resetLiveCaptionStore()
        pendingCandidate = nil
        activeTarget = candidate
        activeMeetingID = record.id
        statusText = "Recording \(record.name)"
    }

    public func updateSpeechLocaleIdentifier(_ localeIdentifier: String) {
        speechConfiguration.localeIdentifier = Self.normalizedSpeechLocaleIdentifier(localeIdentifier)
        persistSpeechConfiguration()
    }

    public func updateSpeechProvider(_ provider: SpeechProvider) {
        speechConfiguration.provider = provider
        persistSpeechConfiguration()
    }

    public func updateWhisperBinaryPath(_ path: String) {
        speechConfiguration.whisperBinaryPath = SpeechTranscriptionConfiguration.normalized(path)
        persistSpeechConfiguration()
    }

    public func updateWhisperModelPath(_ path: String) {
        speechConfiguration.whisperModelPath = SpeechTranscriptionConfiguration.normalized(path)
        persistSpeechConfiguration()
    }

    public func saveSpeechConfiguration(_ configuration: SpeechTranscriptionConfiguration) {
        speechConfiguration = SpeechTranscriptionConfiguration(
            provider: configuration.provider,
            localeIdentifier: configuration.localeIdentifier,
            targetLocaleIdentifier: configuration.targetLocaleIdentifier,
            bilingualPipelineProfileID: Self.derivedBilingualPipelineProfileID(
                transcriptionExecutionMode: configuration.transcriptionExecutionMode,
                translationExecutionMode: configuration.translationExecutionMode
            ),
            whisperBinaryPath: configuration.whisperBinaryPath,
            whisperModelPath: configuration.whisperModelPath,
            transcriptionExecutionMode: configuration.transcriptionExecutionMode,
            translationExecutionMode: configuration.translationExecutionMode,
            localTranscriptionProviderID: configuration.localTranscriptionProviderID,
            localTranslationProviderID: configuration.localTranslationProviderID,
            hostedTranscriptionProviderID: configuration.hostedTranscriptionProviderID,
            hostedTranslationProviderID: configuration.hostedTranslationProviderID,
            hostedTranscriptionModelID: configuration.hostedTranscriptionModelID,
            hostedTranslationModelID: configuration.hostedTranslationModelID,
            openRouterAPIKey: configuration.openRouterAPIKey,
            openAIRealtimeAPIKey: configuration.openAIRealtimeAPIKey,
            deepgramAPIKey: configuration.deepgramAPIKey,
            deepgramModelID: configuration.deepgramModelID
        )
        persistSpeechConfiguration()
        statusText = "Settings saved"
    }

    public func startRecordingForPendingCandidate(localeIdentifier: String? = nil) async throws {
        guard let candidate = pendingCandidate else { return }
        try await startRecording(for: candidate, localeIdentifier: localeIdentifier)
    }

    public func startRecording(for candidate: AudioCaptureTarget, localeIdentifier: String? = nil) async throws {
        var record = try recorder.prepareRecord(for: candidate)
        record.meetingGoal = meetingGoal
        meetings.insert(record, at: 0)
        selectedMeetingID = record.id
        persistMeetingGoalForSelectedMeeting()
        try await startRecordingPreparedRecord(record, target: candidate, localeIdentifier: localeIdentifier)
    }

    public func startRecording(
        for candidate: AudioCaptureTarget,
        meetingID: UUID,
        localeIdentifier: String? = nil
    ) async throws {
        guard let index = meetings.firstIndex(where: { $0.id == meetingID }) else {
            throw ProbeError.invalidArguments("Meeting not found")
        }

        let record = try recorder.prepareRecord(meetings[index], for: candidate)
        selectedMeetingID = record.id
        meetingGoal = record.meetingGoal
        try await startRecordingPreparedRecord(record, target: candidate, localeIdentifier: localeIdentifier)
    }

    private func startRecordingPreparedRecord(
        _ record: MeetingRecord,
        target candidate: AudioCaptureTarget,
        localeIdentifier: String?
    ) async throws {
        resetLiveCaptionStore()
        activeTarget = candidate
        activeMeetingID = record.id
        pendingCandidate = nil
        let recordingLocaleIdentifier = localeIdentifier.map(Self.normalizedSpeechLocaleIdentifier) ?? speechConfiguration.localeIdentifier
        var recordingConfiguration = speechConfiguration
        recordingConfiguration.localeIdentifier = recordingLocaleIdentifier
        do {
            try await recorder.startRecording(
                target: candidate,
                record: record,
                speechConfiguration: recordingConfiguration
            )
            refreshMeetingFromStore(record.id)
        } catch {
            if let stopped = try? recorder.stopRecording(),
               let index = meetings.firstIndex(where: { $0.id == stopped.id }) {
                meetings[index] = stopped
            }
            activeTarget = nil
            activeMeetingID = nil
            throw error
        }
        statusText = "Recording \(record.name)"
    }

    private func refreshMeetingFromStore(_ id: UUID) {
        guard let refreshed = try? store.loadMeetings().first(where: { $0.id == id }),
              let index = meetings.firstIndex(where: { $0.id == id })
        else { return }

        meetings[index] = refreshed
    }

    public func setRecordingStartError(_ error: Error) {
        statusText = "Recording failed: \(error)"
    }

    public func setMeetingGoal(_ goal: MeetingGoal?) {
        meetingGoal = goal
        resetMeetingProgressState()
        persistMeetingGoalForSelectedMeeting()
        configureMeetingProgressCoordinator()
    }

    public func saveAgenda(for meetingID: UUID, update: MeetingAgendaUpdate) throws {
        guard let index = meetings.firstIndex(where: { $0.id == meetingID }) else {
            throw ProbeError.invalidArguments("Meeting not found")
        }

        var record = meetings[index]
        let normalizedName = Self.normalizedSingleLine(update.name)
        if !normalizedName.isEmpty {
            record.name = normalizedName
        }
        record.attendees = update.attendees.compactMap(Self.normalizedAttendee)
        record.agendaTopics = update.agendaTopics.compactMap(Self.normalizedAgendaTopic)
        record.scheduledStartAt = update.scheduledStartAt
        record.scheduledEndAt = update.scheduledEndAt
        record.meetingGoal = Self.normalizedMeetingGoal(update.meetingGoal)

        try store.save(record)
        meetings[index] = record
        if selectedMeetingID == meetingID {
            meetingGoal = record.meetingGoal
            resetMeetingProgressState()
            restoreMeetingProgressStateForSelectedMeeting()
            configureMeetingProgressCoordinator()
        }
        statusText = "Agenda saved"
    }

    public func createAgendaMeeting(
        name: String = "New Meeting",
        scheduledStartAt: Date = Date(),
        scheduledEndAt: Date? = nil
    ) throws -> MeetingRecord {
        let normalizedName = Self.normalizedSingleLine(name)
        let stored = try store.createMeeting(
            name: normalizedName.isEmpty ? "New Meeting" : normalizedName,
            startedAt: scheduledStartAt
        )
        var record = stored.record
        record.scheduledStartAt = scheduledStartAt
        record.scheduledEndAt = scheduledEndAt
        try store.save(record)
        meetings.insert(record, at: 0)
        selectedMeetingID = record.id
        meetingGoal = record.meetingGoal
        resetMeetingProgressState()
        configureMeetingProgressCoordinator()
        statusText = "Agenda created"
        return record
    }

    public func refreshMeetingProgress() async {
        guard let meetingProgressCoordinator else {
            meetingProgressState = nil
            meetingProgressHealth.analysis = .idle
            return
        }
        await meetingProgressCoordinator.process(turns: liveCaptionTurns)
        meetingProgressState = meetingProgressCoordinator.state
        meetingProgressHealth.analysis = meetingProgressCoordinator.analysisHealth
    }

    public func drainRecordingFrames(endedAt: Date = Date()) {
        try? recorder.drainFrames()
        if stopRecordingIfTargetProcessEnded(at: endedAt) {
            objectWillChange.send()
            return
        }
        updateRecordingStatus()
        let transcriptResults = recorder.drainTranscriptUpdates()
        if transcriptResults.isEmpty {
            if isRecording || activeMeetingID != nil {
                refreshActiveLiveCaptionTurnsFromSelectedMeetingIfSafe()
            } else {
                refreshLiveCaptionTurnsFromSelectedMeetingSynchronously()
            }
            if meetingProgressCoordinator != nil {
                Task { [weak self] in
                    await self?.refreshMeetingProgress()
                }
            }
        } else {
            let context = beginActiveCaptionApply()
            activeCaptionApplyTask?.cancel()
            activeCaptionApplyTask = Task { [weak self] in
                guard let self else { return }
                await applyTranscriptAccumulationResultsToLiveCaptions(transcriptResults, context: context)
                if meetingProgressCoordinator != nil {
                    await refreshMeetingProgress()
                }
            }
        }
        objectWillChange.send()
    }

    public func stopRecording(at endedAt: Date = Date()) {
        if let stopped = try? recorder.stopRecording(at: endedAt),
           let index = meetings.firstIndex(where: { $0.id == stopped.id }) {
            meetings[index] = stopped
        }
        invalidateActiveCaptionApplyTasks()
        flushLiveCaptionPipeline(reason: .manualStop)
        allowActiveTargetReprompt()
        activeTarget = nil
        activeMeetingID = nil
        statusText = "Idle"
    }

    public func stopRecordingAndGenerateSummary(
        at endedAt: Date = Date(),
        generatedAt: Date = Date()
    ) async throws {
        let stoppedID: UUID?
        if let stopped = try? recorder.stopRecording(at: endedAt),
           let index = meetings.firstIndex(where: { $0.id == stopped.id }) {
            meetings[index] = stopped
            stoppedID = stopped.id
        } else {
            stoppedID = nil
        }
        invalidateActiveCaptionApplyTasks()
        allowActiveTargetReprompt()
        activeTarget = nil
        activeMeetingID = nil

        guard let stoppedID else {
            statusText = "Idle"
            return
        }

        try await generateSummary(for: stoppedID, generatedAt: generatedAt)
    }

    public func generateSummary(for meetingID: UUID, generatedAt: Date = Date()) async throws {
        guard let meeting = meetings.first(where: { $0.id == meetingID }) else {
            throw ProbeError.invalidArguments("Meeting not found")
        }
        guard let transcriptJSONURL = meeting.transcriptJSONURL else {
            throw ProbeError.invalidArguments("Meeting has no structured transcript URL")
        }
        guard let summaryJSONURL = meeting.summaryJSONURL,
              let summaryMarkdownURL = meeting.summaryMarkdownURL
        else {
            throw ProbeError.invalidArguments("Meeting has no summary output URL")
        }

        let transcript = try TranscriptFileWriter.readDocument(from: transcriptJSONURL)
        let progress = progressState(for: meeting)
        let summary: MeetingSummary
        if progress != nil {
            summary = GoalOrientedSummaryProvider().generate(
                transcript: transcript,
                progress: progress,
                generatedAt: generatedAt
            )
        } else {
            let provider = summaryProviderFactory(speechConfiguration)
            summary = try await provider.generateSummary(
                input: MeetingSummaryInput(
                    meetingName: meeting.name,
                    startedAt: meeting.startedAt,
                    endedAt: meeting.endedAt,
                    language: speechLocaleIdentifier,
                    meetingGoal: nil,
                    segments: transcript.segments,
                    generatedAt: generatedAt
                )
            )
        }
        try MeetingSummaryWriter.write(summary, jsonURL: summaryJSONURL, markdownURL: summaryMarkdownURL)
        try applyGeneratedTitleIfNeeded(summary: summary, meetingID: meetingID)
        statusText = summary.status == .succeeded ? "Summary generated" : "Summary failed"
        objectWillChange.send()
    }

    private func applyGeneratedTitleIfNeeded(summary: MeetingSummary, meetingID: UUID) throws {
        guard summary.status == .succeeded,
              let generatedTitle = summary.autoGeneratedTitle,
              !generatedTitle.isEmpty,
              let index = meetings.firstIndex(where: { $0.id == meetingID }),
              MeetingSummaryTitleGenerator.isGenericMeetingName(meetings[index].name)
        else { return }

        var record = meetings[index]
        record.name = generatedTitle
        try store.save(record)
        meetings[index] = record
    }

    public func selectMeeting(_ id: UUID?) {
        selectedMeetingID = id
        meetingGoal = selectedMeeting?.meetingGoal
        resetLiveCaptionPipeline()
        resetMeetingProgressState()
        restoreMeetingProgressStateForSelectedMeeting()
        configureMeetingProgressCoordinator()
        refreshLiveCaptionTurnsFromSelectedMeeting()
    }

    public func exportTranscript(for meetingID: UUID, to destinationURL: URL) throws {
        try export("Transcript", for: meetingID) { record in
            try exportService.exportTranscript(for: record, to: destinationURL)
        }
    }

    public func exportSummary(for meetingID: UUID, to destinationURL: URL) throws {
        try export("Summary", for: meetingID) { record in
            try exportService.exportSummary(for: record, to: destinationURL)
        }
    }

    public func exportMeetingData(for meetingID: UUID, to destinationURL: URL) throws {
        try export("Meeting data", for: meetingID) { record in
            try exportService.exportMeetingData(for: record, to: destinationURL)
        }
    }

    public func exportSubtitles(
        for meetingID: UUID,
        format: SubtitleExportFormat,
        to destinationURL: URL
    ) throws {
        try export(format == .srt ? "SRT subtitles" : "VTT subtitles", for: meetingID) { record in
            try exportService.exportSubtitles(for: record, format: format, to: destinationURL)
        }
    }

    public func exportReadinessReport(for meetingID: UUID, to destinationURL: URL) throws {
        try export("Readiness report", for: meetingID) { record in
            try exportService.exportReadinessReport(for: record, to: destinationURL)
        }
    }

    public func summaryTextForClipboard(for meetingID: UUID) throws -> String {
        guard let record = meetings.first(where: { $0.id == meetingID }) else {
            let error = MeetingExportError.missingArtifact("meeting")
            statusText = "Copy summary failed: \(Self.errorMessage(error))"
            throw error
        }
        do {
            let summary = try exportService.summaryText(for: record)
            statusText = "Summary copied"
            return summary
        } catch {
            statusText = "Copy summary failed: \(Self.errorMessage(error))"
            throw error
        }
    }

    public func updateSpeakerLabel(
        for meetingID: UUID,
        speakerID: String,
        label: String
    ) async throws {
        guard let record = meetings.first(where: { $0.id == meetingID }) else {
            throw MeetingExportError.missingArtifact("meeting")
        }
        try TranscriptFileWriter.updateSpeakerLabel(
            speakerID: speakerID,
            label: label,
            textURL: record.transcriptURL,
            structuredURL: record.transcriptJSONURL
        )
        resetLiveCaptionPipeline()
        await refreshLiveCaptionTurnsFromSelectedMeetingAsync()
        statusText = "Speaker label updated"
        objectWillChange.send()
    }

    public func updateTranscriptSegmentText(
        for meetingID: UUID,
        segmentID: String,
        text: String
    ) async throws {
        guard let record = meetings.first(where: { $0.id == meetingID }) else {
            throw MeetingExportError.missingArtifact("meeting")
        }
        try TranscriptFileWriter.updateSegmentText(
            segmentID: segmentID,
            text: text,
            textURL: record.transcriptURL,
            structuredURL: record.transcriptJSONURL
        )
        await invalidateDownstreamArtifactsAfterTranscriptChange(for: meetingID)
        resetLiveCaptionPipeline()
        await refreshLiveCaptionTurnsFromSelectedMeetingAsync()
        statusText = "Transcript corrected; summary needs regeneration"
        objectWillChange.send()
    }

    public func retryTranscription(for meetingID: UUID) async {
        guard let index = meetings.firstIndex(where: { $0.id == meetingID }) else { return }
        var record = meetings[index]
        guard let audioURL = record.audioURL, let transcriptURL = record.transcriptURL else {
            record.transcriptionStatus = .failed
            record.transcriptionFailureReason = "No saved audio is available for transcription retry"
            meetings[index] = record
            try? store.save(record)
            return
        }

        record.transcriptionStatus = .retryRequested
        record.transcriptionFailureReason = nil
        record.speechProvider = speechConfiguration.provider
        record.transcriptionProviderID = speechConfiguration.effectiveTranscriptionProviderID
        record.speechLocaleIdentifier = speechConfiguration.localeIdentifier
        meetings[index] = record
        try? store.save(record)

        record.transcriptionStatus = .transcribing
        meetings[index] = record
        try? store.save(record)

        do {
            let previousTranscript = try? String(contentsOf: transcriptURL, encoding: .utf8)
            if speechConfiguration.usesDeepgram {
                let provider = DeepgramAudioTranscriptionProvider(appConfiguration: speechConfiguration)
                let document = try await provider.transcribe(
                    audio: AudioInput(wavURL: audioURL, localeIdentifier: speechConfiguration.localeIdentifier),
                    options: TranscriptionOptions(sourceLocale: speechConfiguration.localeIdentifier)
                )
                try FileBackedTranscriptUpdateSink(transcriptURL: transcriptURL).persist(.replaceAll(document.segments))
            } else {
                let provider = SpeechTranscriptionProviderFactory.provider(
                    for: speechConfiguration.provider,
                    configuration: speechConfiguration
                )
                try await provider.transcribeExistingAudio(context: SpeechTranscriptionContext(
                    inputAudioURL: audioURL,
                    transcriptURL: transcriptURL,
                    localeIdentifier: speechConfiguration.localeIdentifier,
                    meetingID: record.id,
                    previousTranscript: previousTranscript
                ))
            }
            record.transcriptionStatus = .transcribed
            record.transcriptionFailureReason = nil
            await invalidateDownstreamArtifactsAfterTranscriptChange(for: meetingID)
            statusText = "Transcript regenerated"
        } catch {
            record.transcriptionStatus = .failed
            record.transcriptionFailureReason = "Speech recognition failed: \(error)"
            statusText = "Transcription failed"
        }

        meetings[index] = record
        try? store.save(record)
    }

    public func invalidateDownstreamArtifactsAfterTranscriptChange(for meetingID: UUID) async {
        guard let meeting = meetings.first(where: { $0.id == meetingID }) else { return }
        let urls = Set([
            meeting.summaryURL,
            meeting.summaryJSONURL,
            meeting.summaryMarkdownURL,
            meeting.meetingProgressJSONURL
        ].compactMap { $0 })
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
        if selectedMeetingID == meetingID {
            meetingProgressState = nil
            meetingProgressHealth.analysis = .idle
        }
        statusText = "Transcript updated; summary needs regeneration"
        objectWillChange.send()
    }

    public func pollForMeetingCandidates() -> AudioCaptureTarget? {
        let targets = processTargetsProvider()
        processMonitor.reconcileRunningProcessIDs(Set(targets.map(\.processID)))
        let candidates = processMonitor.detectNewCandidates(
            in: targets,
            isRecording: isRecording
        )
        guard let candidate = candidates.first else { return nil }
        setPendingCandidate(candidate)
        return candidate
    }

    public var isRecording: Bool {
        if case .recording = recorder.state { return true }
        if case .prepared = recorder.state { return true }
        return false
    }

    private func updateRecordingStatus() {
        guard let activeTarget, let status = recorder.currentCaptureStatus else { return }
        switch status {
        case .preparingCapture:
            statusText = "Preparing capture for \(activeTarget.displayName)"
        case .recording:
            statusText = "Recording \(activeTarget.displayName)"
        case .recordingNoAudioDetected:
            statusText = "Recording \(activeTarget.displayName), but no audio detected"
        case .recordingSilentAudio:
            statusText = "Recording silent audio from \(activeTarget.displayName)"
        case .targetProcessEnded:
            statusText = "Target process ended: \(activeTarget.displayName)"
        case .captureFailed:
            statusText = "Capture failed: \(activeTarget.displayName)"
        case .recordingSaved:
            statusText = "Recording saved: \(activeTarget.displayName)"
        }
    }

    private func stopRecordingIfTargetProcessEnded(at endedAt: Date = Date()) -> Bool {
        guard let activeTarget else { return false }
        let targets = processTargetsProvider()
        guard processMonitor.hasProcessEnded(processID: activeTarget.processID, in: targets) else {
            return false
        }
        if let stopped = try? recorder.stopRecording(at: endedAt, endedReason: .targetProcessEnded),
           let index = meetings.firstIndex(where: { $0.id == stopped.id }) {
            meetings[index] = stopped
        }
        flushLiveCaptionPipeline(reason: .manualStop)
        statusText = "Target process ended: \(activeTarget.displayName)"
        self.activeTarget = nil
        activeMeetingID = nil
        return true
    }

    private func allowActiveTargetReprompt() {
        guard let activeTarget else { return }
        processMonitor.allowReprompt(processID: activeTarget.processID)
    }

    public var selectedMeeting: MeetingRecord? {
        meetings.first { $0.id == selectedMeetingID }
    }

    public var speechLocaleIdentifier: String {
        speechConfiguration.localeIdentifier
    }

    public var speechProvider: SpeechProvider {
        speechConfiguration.provider
    }

    public var speechConfigurationStatus: SpeechConfigurationValidationStatus {
        speechConfiguration.validationStatus()
    }

    public var primaryChainPreflightSummary: String {
        switch primaryChainPreflightResult.status {
        case .available:
            return "Primary chain ready"
        case .unavailable:
            return primaryChainPreflightResult.messages.joined(separator: "; ")
        }
    }

    private static func normalizedSpeechLocaleIdentifier(_ localeIdentifier: String) -> String {
        let trimmed = localeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "en-US" : trimmed
    }

    private static func normalizedSingleLine(_ value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func normalizedAttendee(_ attendee: MeetingAttendee) -> MeetingAttendee? {
        let name = normalizedSingleLine(attendee.name)
        guard !name.isEmpty else { return nil }
        let role = attendee.role.map(normalizedSingleLine).flatMap { $0.isEmpty ? nil : $0 }
        return MeetingAttendee(id: attendee.id, name: name, role: role)
    }

    private static func normalizedAgendaTopic(_ topic: MeetingAgendaTopic) -> MeetingAgendaTopic? {
        let title = normalizedSingleLine(topic.title)
        guard !title.isEmpty else { return nil }
        return MeetingAgendaTopic(id: topic.id, title: title)
    }

    private static func normalizedMeetingGoal(_ goal: MeetingGoal?) -> MeetingGoal? {
        guard var goal else { return nil }
        goal.title = normalizedSingleLine(goal.title)
        return goal.title.isEmpty ? nil : goal
    }

    private static func derivedBilingualPipelineProfileID(
        transcriptionExecutionMode: ProviderExecutionMode,
        translationExecutionMode: ProviderExecutionMode
    ) -> String {
        switch (transcriptionExecutionMode, translationExecutionMode) {
        case (.hosted, .hosted):
            return "hosted-transcribe-hosted-translation"
        case (.local, .local):
            return "local-whisper-local-translation"
        default:
            return "local-whisper-hosted-translation"
        }
    }

    nonisolated static func summaryProvider(
        for configuration: SpeechTranscriptionConfiguration,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> MeetingSummaryProvider {
        OpenRouterMeetingSummaryProvider(configuration: OpenRouterChatConfiguration(
            apiKey: SpeechTranscriptionConfiguration.normalized(configuration.openRouterAPIKey)
                ?? environment["MEETING_AGENT_OPENROUTER_API_KEY"],
            model: SpeechTranscriptionConfiguration.normalized(configuration.hostedSummaryModelID)
                ?? environment["MEETING_AGENT_OPENROUTER_MODEL"]
        ))
    }

    private func persistSpeechConfiguration() {
        try? speechConfigurationStore.save(speechConfiguration)
        refreshPrimaryChainPreflightResult()
    }

    private func refreshPrimaryChainPreflightResult() {
        primaryChainPreflightResult = PrimaryChainPreflight.evaluate(
            configuration: speechConfiguration
        )
    }

    private static func makeLiveCaptionPipeline(
        configuration: SpeechTranscriptionConfiguration,
        translationProvider: TextTranslationProvider?,
        performanceEventLogger: PerformanceEventLogger? = nil,
        persistTranslation: ((LiveCaptionTurn, String, Bool) -> Void)? = nil
    ) -> LiveCaptionPipeline {
        LiveCaptionPipeline(
            sourceLocale: configuration.localeIdentifier,
            targetLocale: configuration.targetLocaleIdentifier,
            translationProvider: translationProvider,
            performanceEventLogger: performanceEventLogger,
            persistTranslation: persistTranslation
        )
    }

    private func makeLiveCaptionPipeline(
        translationProvider: TextTranslationProvider? = nil
    ) -> LiveCaptionPipeline {
        let textURL = selectedMeeting?.transcriptURL
        let structuredURL = selectedMeeting?.transcriptJSONURL
        return Self.makeLiveCaptionPipeline(
            configuration: speechConfiguration,
            translationProvider: translationProvider,
            performanceEventLogger: currentPerformanceEventLogger(),
            persistTranslation: { turn, translatedText, isFinal in
                try? TranscriptFileWriter.updateSegmentTranslation(
                    segmentID: turn.sourceSegmentID,
                    text: translatedText,
                    targetLocale: turn.targetLocale,
                    isFinal: isFinal,
                    textURL: textURL,
                    structuredURL: structuredURL
                )
            }
        )
    }

    private func captionTranslationProviderForCurrentConfiguration() -> TextTranslationProvider? {
        let options = TranslationOptions(
            sourceLocale: speechConfiguration.localeIdentifier,
            targetLocale: speechConfiguration.targetLocaleIdentifier
        )
        guard !options.isSameLanguage else { return nil }
        return captionTranslationProviderFactory(speechConfiguration)
    }

    private func captionTranslationProviderForCurrentConfiguration(document: TranscriptDocument) -> TextTranslationProvider? {
        let targetLocale = speechConfiguration.targetLocaleIdentifier
        let pendingSegments = document.segments.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if !pendingSegments.isEmpty,
           pendingSegments.allSatisfy({
               TranslationOptions(
                   sourceLocale: $0.language ?? speechConfiguration.localeIdentifier,
                   targetLocale: targetLocale
               ).isSameLanguage
           }) {
            return nil
        }
        return captionTranslationProviderForCurrentConfiguration()
    }

    private func resetLiveCaptionStore() {
        resetLiveCaptionPipeline()
        liveCaptionTurns = []
        meetingProgressHealth.caption = .idle
        meetingProgressHealth.translation = .idle
        resetMeetingProgressState()
        configureMeetingProgressCoordinator()
    }

    private func resetLiveCaptionPipeline() {
        liveCaptionReplayTask?.cancel()
        liveCaptionReplayTask = nil
        liveCaptionReplaySequence += 1
        liveCaptionTurns = []
        liveCaptionPipeline = makeLiveCaptionPipeline()
        liveCaptionPipelineUsesCaptionTranslationProvider = false
        liveCaptionPipelineHasTranslationProvider = false
        invalidateActiveCaptionApplyTasks()
    }

    private func resetMeetingProgressState() {
        meetingProgressState = nil
        meetingProgressHealth.analysis = .idle
    }

    private func persistMeetingGoalForSelectedMeeting() {
        guard let selectedMeetingID,
              let index = meetings.firstIndex(where: { $0.id == selectedMeetingID })
        else {
            return
        }
        meetings[index].meetingGoal = meetingGoal
        try? store.save(meetings[index])
    }

    private func restoreMeetingProgressStateForSelectedMeeting() {
        guard let meetingGoal,
              let progressURL = selectedMeeting?.meetingProgressJSONURL,
              let data = try? Data(contentsOf: progressURL),
              let restored = try? JSONDecoder.meetingAgent.decode(MeetingProgressState.self, from: data),
              restored.goal.id == meetingGoal.id
        else {
            return
        }
        meetingProgressState = restored
        meetingProgressHealth = restored.health
    }

    private func progressState(for meeting: MeetingRecord) -> MeetingProgressState? {
        guard let progressURL = meeting.meetingProgressJSONURL,
              let data = try? Data(contentsOf: progressURL),
              let progress = try? JSONDecoder.meetingAgent.decode(MeetingProgressState.self, from: data)
        else {
            return nil
        }
        if let meetingGoal = meeting.meetingGoal {
            return progress.goal.id == meetingGoal.id ? progress : nil
        }
        return progress
    }

    private func refreshLiveCaptionTurnsFromSelectedMeeting() {
        guard let document = selectedTranscriptDocument(), !document.segments.isEmpty else {
            liveCaptionTurns = []
            meetingProgressHealth.caption = .idle
            return
        }
        liveCaptionReplayTask?.cancel()
        liveCaptionReplaySequence += 1
        let sequence = liveCaptionReplaySequence
        liveCaptionReplayTask = Task { [weak self] in
            await self?.refreshLiveCaptionTurnsFromSelectedMeetingAsync(document: document, sequence: sequence)
        }
    }

    private func refreshLiveCaptionTurnsFromSelectedMeetingSynchronously() {
        guard let document = selectedTranscriptDocument() else {
            liveCaptionReplayTask = nil
            liveCaptionTurns = []
            meetingProgressHealth.caption = .idle
            return
        }
        liveCaptionReplayTask?.cancel()
        liveCaptionReplaySequence += 1
        let sequence = liveCaptionReplaySequence
        let translationProvider = liveCaptionPipelineHasTranslationProvider
            ? nil
            : captionTranslationProviderForCurrentConfiguration(document: document)
        if !liveCaptionPipelineUsesCaptionTranslationProvider
            || (translationProvider != nil && !liveCaptionPipelineHasTranslationProvider) {
            liveCaptionPipeline = makeLiveCaptionPipeline(translationProvider: translationProvider)
            liveCaptionPipelineUsesCaptionTranslationProvider = true
            liveCaptionPipelineHasTranslationProvider = translationProvider != nil
        }
        publishLiveCaptionPipelineSnapshot(liveCaptionPipeline.replayCaptionsOnly(document))
        liveCaptionReplayTask = Task { [weak self] in
            guard let self else { return }
            guard liveCaptionReplaySequence == sequence else { return }
            let snapshot = await liveCaptionPipeline.schedulePendingTranslations()
            guard liveCaptionReplaySequence == sequence else { return }
            publishLiveCaptionPipelineSnapshot(snapshot)
        }
    }

    private func refreshActiveLiveCaptionTurnsFromSelectedMeetingIfSafe() {
        guard let document = selectedTranscriptDocument(), !document.segments.isEmpty else {
            return
        }
        liveCaptionReplayTask?.cancel()
        liveCaptionReplaySequence += 1
        let sequence = liveCaptionReplaySequence
        let translationProvider = liveCaptionPipelineHasTranslationProvider
            ? nil
            : captionTranslationProviderForCurrentConfiguration(document: document)
        if !liveCaptionPipelineUsesCaptionTranslationProvider
            || (translationProvider != nil && !liveCaptionPipelineHasTranslationProvider) {
            liveCaptionPipeline = makeLiveCaptionPipeline(translationProvider: translationProvider)
            liveCaptionPipelineUsesCaptionTranslationProvider = true
            liveCaptionPipelineHasTranslationProvider = translationProvider != nil
        }
        publishLiveCaptionPipelineSnapshot(liveCaptionPipeline.replayCaptionsOnly(document))
        liveCaptionReplayTask = Task { [weak self] in
            guard let self else { return }
            guard liveCaptionReplaySequence == sequence else { return }
            let snapshot = await liveCaptionPipeline.scheduleLivePendingTranslations()
            guard liveCaptionReplaySequence == sequence else { return }
            publishLiveCaptionPipelineSnapshot(snapshot)
        }
    }

    func waitForLiveCaptionReplayForTesting() async {
        await liveCaptionReplayTask?.value
    }

    private func refreshLiveCaptionTurnsFromSelectedMeetingAsync(
        document providedDocument: TranscriptDocument? = nil,
        sequence: Int? = nil
    ) async {
        guard !Task.isCancelled else { return }
        guard let document = providedDocument ?? selectedTranscriptDocument() else {
            liveCaptionTurns = []
            meetingProgressHealth.caption = .idle
            return
        }
        if let sequence {
            guard liveCaptionReplaySequence == sequence else { return }
        } else {
            guard !Task.isCancelled else { return }
        }
        let translationProvider = captionTranslationProviderForCurrentConfiguration(document: document)
        liveCaptionPipeline = makeLiveCaptionPipeline(translationProvider: translationProvider)
        liveCaptionPipelineUsesCaptionTranslationProvider = true
        liveCaptionPipelineHasTranslationProvider = translationProvider != nil
        let snapshot = await liveCaptionPipeline.replay(document)
        if let sequence {
            guard liveCaptionReplaySequence == sequence else { return }
        } else {
            guard !Task.isCancelled else { return }
        }
        publishLiveCaptionPipelineSnapshot(snapshot)
    }

    private func selectedTranscriptDocument() -> TranscriptDocument? {
        guard let meeting = selectedMeeting,
              let transcriptJSONURL = meeting.transcriptJSONURL
        else {
            return nil
        }
        return try? TranscriptFileWriter.readDocument(from: transcriptJSONURL)
    }

    func applyTranscriptAccumulationResultsForTesting(
        _ results: [TranscriptSegmentAccumulationResult]
    ) async {
        let context = beginActiveCaptionApply()
        await applyTranscriptAccumulationResultsToLiveCaptions(results, context: context)
    }

    func beginActiveCaptionApplyForTesting() -> ActiveCaptionApplyContext {
        beginActiveCaptionApply()
    }

    func applyTranscriptAccumulationResultsForTesting(
        _ results: [TranscriptSegmentAccumulationResult],
        context: ActiveCaptionApplyContext
    ) async {
        await applyTranscriptAccumulationResultsToLiveCaptions(results, context: context)
    }

    private func applyTranscriptAccumulationResultsToLiveCaptions(
        _ results: [TranscriptSegmentAccumulationResult],
        context: ActiveCaptionApplyContext
    ) async {
        guard let latest = results.last else { return }
        guard isCurrentActiveCaptionApply(context) else { return }
        if !liveCaptionPipelineUsesCaptionTranslationProvider {
            let translationProvider = captionTranslationProviderForCurrentConfiguration(document: latest.document)
            liveCaptionPipeline = makeLiveCaptionPipeline(translationProvider: translationProvider)
            liveCaptionPipelineUsesCaptionTranslationProvider = true
            liveCaptionPipelineHasTranslationProvider = translationProvider != nil
        }
        let snapshot = await liveCaptionPipeline.apply(latest)
        guard !Task.isCancelled, isCurrentActiveCaptionApply(context) else { return }
        publishLiveCaptionPipelineSnapshot(snapshot)
    }

    private func beginActiveCaptionApply() -> ActiveCaptionApplyContext {
        activeCaptionApplySequence += 1
        return ActiveCaptionApplyContext(
            sequence: activeCaptionApplySequence,
            activeMeetingID: activeMeetingID,
            selectedMeetingID: selectedMeetingID
        )
    }

    private func invalidateActiveCaptionApplyTasks() {
        activeCaptionApplySequence += 1
        activeCaptionApplyTask?.cancel()
        activeCaptionApplyTask = nil
    }

    private func isCurrentActiveCaptionApply(_ context: ActiveCaptionApplyContext) -> Bool {
        context.sequence == activeCaptionApplySequence
            && context.activeMeetingID == activeMeetingID
            && context.selectedMeetingID == selectedMeetingID
    }

    private func isCurrentCaptionFlush(_ context: ActiveCaptionApplyContext) -> Bool {
        context.sequence == activeCaptionApplySequence
            && context.selectedMeetingID == selectedMeetingID
    }

    private func publishLiveCaptionPipelineSnapshot(_ snapshot: LiveCaptionPipelineSnapshot) {
        liveCaptionTurns = snapshot.turns
        meetingProgressHealth.caption = snapshot.captionHealth
        meetingProgressHealth.translation = snapshot.translationHealth
    }

    private func flushLiveCaptionPipeline(reason: LiveCaptionFreezeReason) {
        let context = beginActiveCaptionApply()
        activeCaptionApplyTask?.cancel()
        publishLiveCaptionPipelineSnapshot(liveCaptionPipeline.flushCaptionsOnly(reason: reason))
        activeCaptionApplyTask = Task { [weak self] in
            guard let self else { return }
            let snapshot = await liveCaptionPipeline.schedulePendingTranslations()
            guard !Task.isCancelled, isCurrentCaptionFlush(context) else { return }
            publishLiveCaptionPipelineSnapshot(snapshot)
        }
    }

    private func currentPerformanceEventLogger() -> PerformanceEventLogger? {
        selectedMeeting?.performanceEventsURL.map { PerformanceEventLogger(url: $0) }
    }

    public nonisolated static func openRouterCaptionTranslationProvider(
        for configuration: SpeechTranscriptionConfiguration
    ) -> TextTranslationProvider? {
        guard configuration.translationExecutionMode == .hosted,
              configuration.hostedTranslationProviderID == SpeechTranscriptionConfiguration.defaultHostedTranslationProviderID,
              let apiKey = SpeechTranscriptionConfiguration.normalized(configuration.openRouterAPIKey)
                ?? SpeechTranscriptionConfiguration.normalized(ProcessInfo.processInfo.environment["MEETING_AGENT_OPENROUTER_API_KEY"]),
              let model = SpeechTranscriptionConfiguration.normalized(configuration.hostedTranslationModelID)
        else {
            return nil
        }
        return OpenRouterTextTranslationProvider(configuration: OpenRouterChatConfiguration(apiKey: apiKey, model: model))
    }

    private func configureMeetingProgressCoordinator() {
        guard let goal = meetingGoal,
              let progressURL = selectedMeeting?.meetingProgressJSONURL
        else {
            meetingProgressCoordinator = nil
            return
        }
        meetingProgressCoordinator = MeetingProgressCoordinator(
            goal: goal,
            agendaTopics: selectedMeeting?.agendaTopics ?? [],
            analyzer: DeterministicMeetingProgressAnalyzer(meetingID: selectedMeeting?.id ?? UUID()),
            progressURL: progressURL
        )
    }

    private func export(_ label: String, for meetingID: UUID, operation: (MeetingRecord) throws -> Void) throws {
        guard let record = meetings.first(where: { $0.id == meetingID }) else {
            let error = MeetingExportError.missingArtifact("meeting")
            statusText = "\(label) export failed: \(Self.errorMessage(error))"
            throw error
        }

        do {
            try operation(record)
            statusText = "\(label) exported"
        } catch {
            statusText = "\(label) export failed: \(Self.errorMessage(error))"
            throw error
        }
    }

    private static func errorMessage(_ error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }
        return String(describing: error)
    }
}
