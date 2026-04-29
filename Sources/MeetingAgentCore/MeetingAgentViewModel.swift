import Combine
import Foundation

private struct CaptionTranslationRequest {
    let turn: LiveCaptionTurn
    let key: String
    let isDraft: Bool
    let revision: Int
    let performanceEventLogger: PerformanceEventLogger?
}

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
    @Published public private(set) var realtimeTranslationStatus: RealtimeTranslationStatus = .idle
    @Published public private(set) var liveTranslationTurns: [LiveTranslationTurn] = []
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
    private let realtimeTranslationController: RealtimeTranslationController
    private var liveCaptionStore = LiveCaptionStore()
    private var liveCaptionChunker = LiveCaptionChunker(sourceLocale: "en-US", targetLocale: "zh-CN")
    private var processedLiveCaptionSegmentSignaturesByID: [String: String] = [:]
    @Published public private(set) var meetingGoal: MeetingGoal?
    private var meetingProgressCoordinator: MeetingProgressCoordinator?
    private var attachedRealtimeTranslationTurnIDs = Set<String>()
    private var realtimeTranslationAttachmentCountsByCaptionID: [String: Int] = [:]
    private var draftTranslationKeysByTurnID: [String: String] = [:]
    private var draftTranslationInFlightByTurnID: [String: Int] = [:]
    private var draftTranslationCharacterCountsByTurnID: [String: Int] = [:]
    private var draftTranslationAttemptDatesByTurnID: [String: Date] = [:]
    private var finalTranslationKeysByTurnID: [String: String] = [:]
    private var finalTranslationInFlightTurnIDs = Set<String>()
    private let minDraftTranslationCharacterDelta = 80
    private let minDraftTranslationInterval: TimeInterval = 2
    private let captionTranslationProviderFactory: (SpeechTranscriptionConfiguration) -> TextTranslationProvider?
    private let summaryProviderFactory: (SpeechTranscriptionConfiguration) -> MeetingSummaryProvider
    private let processTargetsProvider: () -> [AudioCaptureTarget]
    private let processMonitor = MeetingProcessMonitor()
    private var activeTarget: AudioCaptureTarget?

    public init(
        store: MeetingStore = MeetingStore(),
        recorder: MeetingRecorder? = nil,
        speechLocaleIdentifier: String = Locale.current.identifier,
        speechProvider: SpeechProvider = .whisper,
        speechConfiguration: SpeechTranscriptionConfiguration? = nil,
        speechConfigurationStore: SpeechTranscriptionConfigurationStore = SpeechTranscriptionConfigurationStore(),
        exportService: MeetingExportService = MeetingExportService(),
        realtimeTranslationController: RealtimeTranslationController = RealtimeTranslationController(
            playbackSink: LocalAudioPlaybackSink()
        ),
        captionTranslationProviderFactory: @escaping (SpeechTranscriptionConfiguration) -> TextTranslationProvider? = MeetingAgentViewModel.openRouterCaptionTranslationProvider,
        summaryProviderFactory: ((SpeechTranscriptionConfiguration) -> MeetingSummaryProvider)? = nil,
        processTargetsProvider: @escaping () -> [AudioCaptureTarget] = RunningProcessDiscovery.currentTargets
    ) {
        self.store = store
        self.speechConfigurationStore = speechConfigurationStore
        self.recorder = recorder ?? MeetingRecorder(store: store)
        self.exportService = exportService
        self.realtimeTranslationController = realtimeTranslationController
        self.captionTranslationProviderFactory = captionTranslationProviderFactory
        self.summaryProviderFactory = summaryProviderFactory ?? { configuration in
            Self.summaryProvider(for: configuration)
        }
        self.processTargetsProvider = processTargetsProvider
        self.recorder.realtimeFrameConsumer = realtimeTranslationController
        if let speechConfiguration {
            self.speechConfiguration = speechConfiguration
        } else if speechProvider != .whisper || speechLocaleIdentifier != Locale.current.identifier {
            self.speechConfiguration = SpeechTranscriptionConfiguration(
                provider: speechProvider,
                localeIdentifier: speechLocaleIdentifier,
                whisperBinaryPath: nil,
                whisperModelPath: nil
            )
        } else {
            self.speechConfiguration = (try? speechConfigurationStore.load()) ?? .default
        }
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

    public func setRecordingStartError(_ error: Error) {
        statusText = "Recording failed: \(error)"
    }

    public func startRealtimeTranslation(targetLocale: String) async {
        guard isRecording else {
            realtimeTranslationStatus = .failed("Start recording before live translation")
            return
        }
        let configuredAPIKey = SpeechTranscriptionConfiguration.normalized(speechConfiguration.openAIRealtimeAPIKey)
        let configuration: RealtimeTranslationConfiguration
        if let configuredAPIKey {
            configuration = RealtimeTranslationConfiguration(apiKey: configuredAPIKey, targetLocale: targetLocale)
        } else {
            configuration = RealtimeTranslationConfiguration(targetLocale: targetLocale)
        }
        await realtimeTranslationController.start(configuration: configuration)
        syncRealtimeTranslationState()
    }

    public func stopRealtimeTranslation() async {
        await realtimeTranslationController.stop()
        syncRealtimeTranslationState()
    }

    public func syncRealtimeTranslationState() {
        realtimeTranslationStatus = realtimeTranslationController.status
        liveTranslationTurns = realtimeTranslationController.liveTranslationTurns
        attachRealtimeTranslationsToLiveCaptions()
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
        refreshLiveCaptionTurnsFromSelectedMeeting()
        if meetingProgressCoordinator != nil {
            Task { [weak self] in
                await self?.refreshMeetingProgress()
            }
        }
        syncRealtimeTranslationState()
        objectWillChange.send()
    }

    public func stopRecording(at endedAt: Date = Date()) {
        if let stopped = try? recorder.stopRecording(at: endedAt),
           let index = meetings.firstIndex(where: { $0.id == stopped.id }) {
            meetings[index] = stopped
        }
        freezeOpenLiveCaptionChunk(reason: .manualStop)
        allowActiveTargetReprompt()
        Task { await stopRealtimeTranslation() }
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
        await stopRealtimeTranslation()
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
        refreshLiveCaptionTurnsFromSelectedMeeting()
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
        refreshLiveCaptionTurnsFromSelectedMeeting()
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
                try TranscriptFileWriter(url: transcriptURL).replace(with: document.segments)
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
        freezeOpenLiveCaptionChunk(reason: .manualStop)
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

    private nonisolated static func summaryProvider(
        for configuration: SpeechTranscriptionConfiguration,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> MeetingSummaryProvider {
        let provider = environment["MEETING_AGENT_SUMMARY_PROVIDER"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if provider == "openrouter" {
            return OpenRouterMeetingSummaryProvider(configuration: OpenRouterChatConfiguration(
                apiKey: SpeechTranscriptionConfiguration.normalized(configuration.openRouterAPIKey)
                    ?? environment["MEETING_AGENT_OPENROUTER_API_KEY"],
                model: SpeechTranscriptionConfiguration.normalized(configuration.hostedSummaryModelID)
                    ?? environment["MEETING_AGENT_OPENROUTER_MODEL"]
            ))
        }
        return ExtractiveMeetingSummaryProvider()
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

    private func resetLiveCaptionStore() {
        liveCaptionStore.reset(
            sourceLocale: speechConfiguration.localeIdentifier,
            targetLocale: speechConfiguration.targetLocaleIdentifier
        )
        resetLiveCaptionPipeline(keepStore: true)
        liveCaptionTurns = []
        meetingProgressHealth.caption = .idle
        meetingProgressHealth.translation = .idle
        resetMeetingProgressState()
        configureMeetingProgressCoordinator()
    }

    private func resetLiveCaptionPipeline(keepStore: Bool = false) {
        if !keepStore {
            liveCaptionStore.reset(
                sourceLocale: speechConfiguration.localeIdentifier,
                targetLocale: speechConfiguration.targetLocaleIdentifier
            )
            liveCaptionTurns = []
        }
        liveCaptionChunker = LiveCaptionChunker(
            sourceLocale: speechConfiguration.localeIdentifier,
            targetLocale: speechConfiguration.targetLocaleIdentifier
        )
        processedLiveCaptionSegmentSignaturesByID.removeAll()
        attachedRealtimeTranslationTurnIDs.removeAll()
        realtimeTranslationAttachmentCountsByCaptionID.removeAll()
        draftTranslationKeysByTurnID.removeAll()
        draftTranslationInFlightByTurnID.removeAll()
        draftTranslationCharacterCountsByTurnID.removeAll()
        draftTranslationAttemptDatesByTurnID.removeAll()
        finalTranslationKeysByTurnID.removeAll()
        finalTranslationInFlightTurnIDs.removeAll()
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
        guard let meeting = selectedMeeting,
              let transcriptJSONURL = meeting.transcriptJSONURL,
              let document = try? TranscriptFileWriter.readDocument(from: transcriptJSONURL)
        else {
            liveCaptionTurns = []
            return
        }
        let currentSegmentIDs = Set(document.segments.map(\.id))
        liveCaptionStore.removeNonFinalTurnsNotIn(segmentIDs: currentSegmentIDs)
        processedLiveCaptionSegmentSignaturesByID = processedLiveCaptionSegmentSignaturesByID.filter {
            currentSegmentIDs.contains($0.key)
        }
        for segment in document.segments where segment.isFinal {
            let signatureSpeakerID: String
            if let speakerID = segment.speakerID {
                signatureSpeakerID = speakerID
            } else {
                signatureSpeakerID = ""
            }
            let signatureSpeakerLabel: String
            if let speakerLabel = segment.speakerLabel {
                signatureSpeakerLabel = speakerLabel
            } else {
                signatureSpeakerLabel = ""
            }
            let signature = [
                segment.text,
                segment.speechFinal ? "speechFinal" : "open",
                signatureSpeakerID,
                signatureSpeakerLabel
            ].joined(separator: "\u{1F}")
            guard processedLiveCaptionSegmentSignaturesByID[segment.id] != signature else { continue }
            processedLiveCaptionSegmentSignaturesByID[segment.id] = signature
            currentPerformanceEventLogger()?.logSegment(
                "caption_segment_ingested",
                segment: segment,
                metadata: ["path": "final"]
            )
            for update in liveCaptionChunker.append(segment) {
                liveCaptionStore.upsert(update.turn)
                logCaptionTurnUpdate(update.turn)
            }
        }
        for segment in document.segments where !segment.isFinal {
            currentPerformanceEventLogger()?.logSegment(
                "caption_segment_ingested",
                segment: segment,
                metadata: ["path": "interim"]
            )
            _ = liveCaptionStore.append(segment)
        }
        liveCaptionTurns = liveCaptionStore.turns
        meetingProgressHealth.caption = liveCaptionTurns.isEmpty ? .idle : .live
        attachRealtimeTranslationsToLiveCaptions()
        scheduleCaptionTextTranslationIfNeeded()
    }

    private func freezeOpenLiveCaptionChunk(reason: LiveCaptionFreezeReason) {
        for update in liveCaptionChunker.flushOpenChunk(reason: reason) {
            liveCaptionStore.upsert(update.turn)
            logCaptionTurnUpdate(update.turn, metadata: ["flushReason": reason.rawValue])
        }
        liveCaptionTurns = liveCaptionStore.turns
        scheduleCaptionTextTranslationIfNeeded()
    }

    private func currentPerformanceEventLogger() -> PerformanceEventLogger? {
        selectedMeeting?.performanceEventsURL.map { PerformanceEventLogger(url: $0) }
    }

    private func logCaptionTurnUpdate(
        _ turn: LiveCaptionTurn,
        metadata extraMetadata: [String: String] = [:]
    ) {
        var metadata = translationMetadata(for: turn, isDraft: turn.displayState == .draft)
        metadata["displayState"] = String(describing: turn.displayState)
        metadata["chunkState"] = String(describing: turn.chunkState)
        metadata["translationRevision"] = String(turn.translationRevision)
        for (key, value) in extraMetadata {
            metadata[key] = value
        }
        currentPerformanceEventLogger()?.log(
            "caption_turn_updated",
            segmentID: turn.id,
            isFinal: turn.isFinal,
            textLength: turn.originalText.count,
            metadata: metadata
        )
    }

    private func logTranslationScheduled(
        _ turn: LiveCaptionTurn,
        isDraft: Bool,
        logger: PerformanceEventLogger?
    ) {
        logger?.log(
            "caption_translation_scheduled",
            segmentID: turn.id,
            isFinal: !isDraft,
            textLength: turn.originalText.count,
            metadata: translationMetadata(for: turn, isDraft: isDraft)
        )
    }

    private func translationMetadata(
        for turn: LiveCaptionTurn,
        isDraft: Bool,
        extra: [String: String] = [:]
    ) -> [String: String] {
        var metadata: [String: String] = [
            "turnID": turn.id,
            "sourceSegmentID": turn.sourceSegmentID,
            "sourceSegmentIDs": turn.sourceSegmentIDs.joined(separator: ","),
            "sourceLocale": turn.sourceLocale,
            "targetLocale": turn.targetLocale,
            "translationKind": isDraft ? "draft" : "final"
        ]
        if let boundaryStrength = turn.boundaryStrength {
            metadata["boundaryStrength"] = String(describing: boundaryStrength)
        }
        if let boundaryReason = turn.boundaryReason {
            metadata["boundaryReason"] = boundaryReason.rawValue
        }
        for (key, value) in extra {
            metadata[key] = value
        }
        return metadata
    }

    private func scheduleCaptionTextTranslationIfNeeded() {
        completeSameLanguageCaptionTranslationsIfNeeded()
        let draftCandidates = liveCaptionStore.turns.filter { turn in
            guard turn.translationHealth == .pending,
                  shouldScheduleDraftTranslation(for: turn),
                  draftTranslationInFlightByTurnID[turn.id] != turn.translationRevision
            else { return false }
            return true
        }

        let finalCandidates = liveCaptionStore.turns.filter { turn in
            guard turn.displayState == .sealed,
                  turn.boundaryStrength == .hard,
                  turn.translationHealth == .pending
            else { return false }
            let key = finalCaptionTranslationKey(for: turn)
            return finalTranslationKeysByTurnID[turn.id] != key
                && !finalTranslationInFlightTurnIDs.contains(turn.id)
        }

        guard !draftCandidates.isEmpty || !finalCandidates.isEmpty else { return }
        guard let provider = captionTranslationProviderFactory(speechConfiguration) else { return }

        let performanceEventLogger = currentPerformanceEventLogger()
        let draftRequests = draftCandidates.map { turn -> CaptionTranslationRequest in
            let key = draftCaptionTranslationKey(for: turn)
            draftTranslationInFlightByTurnID[turn.id] = turn.translationRevision
            draftTranslationAttemptDatesByTurnID[turn.id] = Date()
            logTranslationScheduled(
                turn,
                isDraft: true,
                logger: performanceEventLogger
            )
            return CaptionTranslationRequest(
                turn: turn,
                key: key,
                isDraft: true,
                revision: turn.translationRevision,
                performanceEventLogger: performanceEventLogger
            )
        }

        let finalRequests = finalCandidates.map { turn -> CaptionTranslationRequest in
            let key = finalCaptionTranslationKey(for: turn)
            finalTranslationInFlightTurnIDs.insert(turn.id)
            logTranslationScheduled(
                turn,
                isDraft: false,
                logger: performanceEventLogger
            )
            return CaptionTranslationRequest(
                turn: turn,
                key: key,
                isDraft: false,
                revision: turn.translationRevision,
                performanceEventLogger: performanceEventLogger
            )
        }

        let requests = draftRequests + finalRequests
        guard !requests.isEmpty else { return }
        Task { [weak self, provider, requests] in
            await self?.translateCaptionTurns(requests, using: provider)
        }
    }

    private func completeSameLanguageCaptionTranslationsIfNeeded() {
        var completedAny = false
        for turn in liveCaptionStore.turns where turn.translationHealth == .pending {
            let options = TranslationOptions(sourceLocale: turn.sourceLocale, targetLocale: turn.targetLocale)
            guard options.isSameLanguage else { continue }
            completeCaptionTranslationWithoutProvider(for: turn)
            completedAny = true
        }
        guard completedAny else { return }
        liveCaptionTurns = liveCaptionStore.turns
        updateTranslationHealthFromRealtimeStatus()
    }

    private func shouldScheduleDraftTranslation(for turn: LiveCaptionTurn) -> Bool {
        guard turn.translationState != .final else {
            return false
        }
        if turn.displayState == .draft {
            return shouldTranslateDraftCaption(turn)
        }
        if turn.displayState == .sealed, turn.boundaryStrength == .soft {
            return true
        }
        return false
    }

    private func shouldTranslateDraftCaption(_ turn: LiveCaptionTurn, now: Date = Date()) -> Bool {
        let key = draftCaptionTranslationKey(for: turn)
        if draftTranslationKeysByTurnID[turn.id] == nil {
            return true
        }
        if draftTranslationKeysByTurnID[turn.id] == key {
            return false
        }
        let previousCount = draftTranslationCharacterCountsByTurnID[turn.id] ?? 0
        if turn.originalText.count - previousCount >= minDraftTranslationCharacterDelta {
            return true
        }
        let previousAttempt = draftTranslationAttemptDatesByTurnID[turn.id] ?? .distantPast
        return now.timeIntervalSince(previousAttempt) >= minDraftTranslationInterval
    }

    private func translateCaptionTurns(_ requests: [CaptionTranslationRequest], using provider: TextTranslationProvider) async {
        for request in requests {
            let turn = request.turn
            let sourceText = translationSourceText(for: turn, final: !request.isDraft)
            let options = TranslationOptions(sourceLocale: turn.sourceLocale, targetLocale: turn.targetLocale)
            if options.isSameLanguage {
                completeCaptionTranslationWithoutProvider(for: turn)
                liveCaptionTurns = liveCaptionStore.turns
                continue
            }
            let segment = TranscriptSegment(
                id: turn.sourceSegmentID,
                speaker: turn.speaker,
                text: sourceText,
                language: turn.sourceLocale,
                isFinal: turn.isFinal,
                createdAt: turn.createdAt
            )
            do {
                request.performanceEventLogger?.log(
                    "caption_translation_started",
                    segmentID: turn.id,
                    isFinal: !request.isDraft,
                    textLength: sourceText.count,
                    metadata: translationMetadata(for: turn, isDraft: request.isDraft)
                )
                let translated = try await provider.translate(
                    transcript: TranscriptDocument(segments: [segment]),
                    options: options
                )
                let translatedText = translated.segments.first { $0.id == turn.sourceSegmentID }?.targetText ?? ""
                request.performanceEventLogger?.log(
                    "caption_translation_finished",
                    segmentID: turn.id,
                    isFinal: !request.isDraft,
                    textLength: translatedText.count,
                    metadata: translationMetadata(for: turn, isDraft: request.isDraft)
                )
                if request.isDraft {
                    acceptDraftTranslation(request, translatedText: translatedText)
                } else {
                    acceptFinalTranslation(request, translatedText: translatedText)
                }
            } catch {
                let nsError = error as NSError
                request.performanceEventLogger?.log(
                    "caption_translation_failed",
                    segmentID: turn.id,
                    isFinal: !request.isDraft,
                    textLength: sourceText.count,
                    metadata: translationMetadata(
                        for: turn,
                        isDraft: request.isDraft,
                        extra: ["error": "\(nsError.domain) error \(nsError.code)"]
                    )
                )
                liveCaptionStore.markTranslationFailed(forTurnID: turn.id, message: "\(nsError.domain) error \(nsError.code)")
                liveCaptionTurns = liveCaptionStore.turns
                clearTranslationInFlight(request)
            }
        }
        updateTranslationHealthFromRealtimeStatus()
    }

    private func completeCaptionTranslationWithoutProvider(for turn: LiveCaptionTurn) {
        liveCaptionStore.markTranslationCompleteWithoutText(forTurnID: turn.id)
        draftTranslationKeysByTurnID[turn.id] = draftCaptionTranslationKey(for: turn)
        draftTranslationCharacterCountsByTurnID[turn.id] = turn.originalText.count
        finalTranslationKeysByTurnID[turn.id] = finalCaptionTranslationKey(for: turn)
        draftTranslationInFlightByTurnID.removeValue(forKey: turn.id)
        finalTranslationInFlightTurnIDs.remove(turn.id)
    }

    private func translationSourceText(for turn: LiveCaptionTurn, final: Bool) -> String {
        guard final else {
            return turn.originalText
        }
        let groups = LiveCaptionSpeakerGroup.groups(from: liveCaptionStore.turns)
        guard let group = groups.first(where: { $0.turns.contains(where: { $0.id == turn.id }) }) else {
            return turn.originalText
        }
        var texts: [String] = []
        for candidate in group.turns {
            texts.append(candidate.originalText)
            if candidate.id == turn.id {
                break
            }
        }
        return texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func acceptDraftTranslation(_ request: CaptionTranslationRequest, translatedText: String) {
        defer { clearTranslationInFlight(request) }
        guard let current = liveCaptionStore.turns.first(where: { $0.id == request.turn.id }),
              current.translationRevision == request.revision,
              current.translationState != .final,
              shouldScheduleDraftTranslation(for: current)
        else {
            return
        }
        liveCaptionStore.attachTranslation(translatedText, toTurnID: request.turn.id)
        request.performanceEventLogger?.log(
            "caption_translation_attached",
            segmentID: request.turn.id,
            isFinal: false,
            textLength: translatedText.count,
            metadata: translationMetadata(for: request.turn, isDraft: true)
        )
        draftTranslationKeysByTurnID[request.turn.id] = request.key
        draftTranslationCharacterCountsByTurnID[request.turn.id] = current.originalText.count
        liveCaptionTurns = liveCaptionStore.turns
    }

    private func acceptFinalTranslation(_ request: CaptionTranslationRequest, translatedText: String) {
        defer { clearTranslationInFlight(request) }
        guard liveCaptionStore.turns.contains(where: {
            $0.id == request.turn.id
                && $0.displayState == .sealed
                && $0.boundaryStrength == .hard
        }) else {
            return
        }
        liveCaptionStore.attachTranslation(translatedText, toTurnID: request.turn.id)
        liveCaptionStore.markTranslationFinal(forTurnID: request.turn.id)
        request.performanceEventLogger?.log(
            "caption_translation_attached",
            segmentID: request.turn.id,
            isFinal: true,
            textLength: translatedText.count,
            metadata: translationMetadata(for: request.turn, isDraft: false)
        )
        finalTranslationKeysByTurnID[request.turn.id] = request.key
        liveCaptionTurns = liveCaptionStore.turns
    }

    private func clearTranslationInFlight(_ request: CaptionTranslationRequest) {
        if request.isDraft {
            if draftTranslationInFlightByTurnID[request.turn.id] == request.revision {
                draftTranslationInFlightByTurnID.removeValue(forKey: request.turn.id)
            }
        } else {
            finalTranslationInFlightTurnIDs.remove(request.turn.id)
        }
    }

    private func draftCaptionTranslationKey(for turn: LiveCaptionTurn) -> String {
        captionTranslationKey(for: turn)
    }

    private func finalCaptionTranslationKey(for turn: LiveCaptionTurn) -> String {
        captionTranslationKey(for: turn)
    }

    private func captionTranslationKey(for turn: LiveCaptionTurn) -> String {
        "\(turn.sourceSegmentIDs.joined(separator: ","))|\(turn.sourceLocale)|\(turn.targetLocale)|\(turn.originalText)"
    }

    private func attachRealtimeTranslationsToLiveCaptions() {
        let unattachedFinalTranslations = liveTranslationTurns
            .filter { $0.isFinal && !attachedRealtimeTranslationTurnIDs.contains($0.id) }
        guard !unattachedFinalTranslations.isEmpty else {
            updateTranslationHealthFromRealtimeStatus()
            return
        }
        for translation in unattachedFinalTranslations {
            guard let caption = liveCaptionStore.turns.first(where: {
                $0.isFinal && realtimeTranslationAttachmentCount(for: $0) < $0.sourceSegmentIDs.count
            }) else {
                break
            }
            liveCaptionStore.appendTranslation(translation.text, toTurnID: caption.id)
            realtimeTranslationAttachmentCountsByCaptionID[caption.id, default: 0] += 1
            attachedRealtimeTranslationTurnIDs.insert(translation.id)
        }
        liveCaptionTurns = liveCaptionStore.turns
        updateTranslationHealthFromRealtimeStatus()
    }

    private func realtimeTranslationAttachmentCount(for caption: LiveCaptionTurn) -> Int {
        realtimeTranslationAttachmentCountsByCaptionID[caption.id, default: 0]
    }

    private func updateTranslationHealthFromRealtimeStatus() {
        if liveCaptionTurns.contains(where: { $0.translationHealth == .live }) {
            meetingProgressHealth.translation = .live
            return
        }
        switch realtimeTranslationStatus {
        case .connected:
            meetingProgressHealth.translation = .pending
        case .connecting:
            meetingProgressHealth.translation = .pending
        case .degraded(let message):
            meetingProgressHealth.translation = .degraded(message)
        case .failed(let message):
            meetingProgressHealth.translation = .failed(message)
        case .idle:
            meetingProgressHealth.translation = .idle
        }
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
