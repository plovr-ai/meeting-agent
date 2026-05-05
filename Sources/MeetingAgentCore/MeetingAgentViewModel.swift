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
    private var realtimeCaptionSession: RealtimeCaptionSession
    private var realtimeCaptionSessionUsesCaptionTranslationProvider = false
    private var realtimeCaptionSessionHasTranslationProvider = false
    private var latestRealtimeCaptionSnapshot: LiveCaptionPipelineSnapshot?
    private var liveCaptionPipeline: LiveCaptionPipeline
    private var liveCaptionPipelineUsesCaptionTranslationProvider = false
    private var liveCaptionPipelineHasTranslationProvider = false
    private var activeCaptionApplySequence = 0
    private var activeCaptionApplyTask: Task<Void, Never>?
    private var activeCaptionTranslationTask: Task<Void, Never>?
    private var activeCaptionTranslationGeneration = 0
    private var liveCaptionReplayTask: Task<Void, Never>?
    private var liveCaptionReplaySequence = 0
    private var activeCaptionDocumentSignature: String?
    private var selectedMeetingReplaySignature: SelectedMeetingReplaySignature?
    private var selectedMeetingReplayFileSignature: SelectedMeetingTranscriptFileSignature?
    private var nextSelectedMeetingPendingTranslationRetryAt: Date?
    private let liveCaptionSnapshotDebounceNanoseconds: UInt64
    private let draftCaptionInputThrottleNanoseconds: UInt64
    private var pendingDraftCaptionInput: PendingDraftCaptionInput?
    private var pendingDraftCaptionInputTask: Task<Void, Never>?
    private var pendingDraftCaptionInputGeneration = 0
    private var hasPublishedActiveDraftCaptionInput = false
    private var pendingLiveCaptionSnapshot: LiveCaptionPipelineSnapshot?
    private var pendingLiveCaptionSnapshotIsRealtime = false
    private var pendingLiveCaptionSnapshotTask: Task<Void, Never>?
    private var pendingLiveCaptionSnapshotGeneration = 0
    private static let selectedMeetingPendingTranslationRetryInterval: TimeInterval = 1.5
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

    private struct ActiveCaptionTranslationContext: Equatable {
        let activeMeetingID: UUID?
        let selectedMeetingID: UUID?
    }

    private enum CaptionSnapshotPublicationKind: String {
        case original = "caption_original_snapshot_published"
        case translationOverlay = "caption_translation_overlay_published"
    }

    private struct PendingDraftCaptionInput {
        var results: [TranscriptSegmentAccumulationResult]
        var context: ActiveCaptionApplyContext
        var latestChangedSegmentID: String?
        var changedSegmentCount: Int
    }

    private struct SelectedMeetingReplaySignature: Equatable {
        var meetingID: UUID
        var captionDocumentSignature: String
        var sourceLocaleIdentifier: String
        var targetLocaleIdentifier: String
        var hasTranslationProvider: Bool
    }

    private struct SelectedMeetingTranscriptFileSignature: Equatable {
        var meetingID: UUID
        var path: String
        var modificationTime: TimeInterval?
        var fileSize: UInt64?
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
        liveCaptionSnapshotDebounceNanoseconds: UInt64 = 0,
        draftCaptionInputThrottleNanoseconds: UInt64 = 200_000_000,
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
        self.liveCaptionSnapshotDebounceNanoseconds = liveCaptionSnapshotDebounceNanoseconds
        self.draftCaptionInputThrottleNanoseconds = draftCaptionInputThrottleNanoseconds
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
        let initialLiveCaptionPipeline = Self.makeLiveCaptionPipeline(
            configuration: resolvedSpeechConfiguration,
            translationProvider: nil
        )
        liveCaptionPipeline = initialLiveCaptionPipeline
        realtimeCaptionSession = RealtimeCaptionSession(
            pipeline: Self.makeLiveCaptionPipeline(
                configuration: resolvedSpeechConfiguration,
                translationProvider: nil
            )
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
        let normalizedGoals = Self.normalizedMeetingGoals(update.meetingGoals, legacyGoal: update.meetingGoal)
        record.meetingGoals = normalizedGoals
        record.meetingGoal = normalizedGoals.first

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
            if !isRecording && activeMeetingID == nil {
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
            if shouldThrottleDraftCaptionInput(transcriptResults, context: context) {
                submitDraftCaptionInput(transcriptResults, context: context)
            } else {
                cancelPendingDraftCaptionInput(reason: "non_delayable_update")
                activeCaptionApplyTask = Task { [weak self] in
                    guard let self else { return }
                    await applyTranscriptAccumulationResultsToLiveCaptions(transcriptResults, context: context)
                    if meetingProgressCoordinator != nil {
                        await refreshMeetingProgress()
                    }
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
        let provider = summaryProviderFactory(speechConfiguration)
        let summary = try await provider.generateSummary(
            input: MeetingSummaryInput(
                meetingName: meeting.name,
                startedAt: meeting.startedAt,
                endedAt: meeting.endedAt,
                language: speechLocaleIdentifier,
                targetLanguage: speechConfiguration.targetLocaleIdentifier,
                meetingGoal: summaryGoalContext(for: progress),
                segments: transcript.segments,
                generatedAt: generatedAt
            )
        )
        try MeetingSummaryWriter.write(summary, jsonURL: summaryJSONURL, markdownURL: summaryMarkdownURL)
        try applyGeneratedTitleIfNeeded(summary: summary, meetingID: meetingID)
        statusText = summary.status == .succeeded ? "Summary generated" : "Summary failed"
        objectWillChange.send()
    }

    private func summaryGoalContext(for progress: MeetingProgressState?) -> String? {
        guard let progress else { return nil }
        var lines = [
            "Goal: \(progress.goal.title)",
            "Current status: \(progress.status.displayText)"
        ]
        appendSummaryContextSection("Confirmed items", progress.confirmedItems, to: &lines)
        appendSummaryContextSection("Unresolved items", progress.unresolvedItems, to: &lines)
        appendSummaryContextSection(
            "Suggested follow-up questions",
            progress.suggestedQuestions.map(\.english),
            to: &lines
        )
        return lines.joined(separator: "\n")
    }

    private func appendSummaryContextSection(_ title: String, _ items: [String], to lines: inout [String]) {
        let visibleItems = items
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !visibleItems.isEmpty else { return }
        lines.append("\(title):")
        lines.append(contentsOf: visibleItems.map { "- \($0)" })
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
        let effectiveMeetingID = activeMeetingID ?? id
        selectedMeetingID = effectiveMeetingID
        meetingGoal = selectedMeeting?.meetingGoal
        resetMeetingProgressState()
        restoreMeetingProgressStateForSelectedMeeting()
        configureMeetingProgressCoordinator()
        if effectiveMeetingID != nil, effectiveMeetingID == activeMeetingID {
            bindLiveCaptionTurnsToActiveRecording()
        } else {
            resetLiveCaptionPipeline()
            refreshLiveCaptionTurnsFromSelectedMeeting()
        }
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

    private static func normalizedMeetingGoals(_ goals: [MeetingGoal], legacyGoal: MeetingGoal?) -> [MeetingGoal] {
        let sourceGoals: [MeetingGoal]
        if !goals.isEmpty {
            sourceGoals = goals
        } else if let legacyGoal {
            sourceGoals = [legacyGoal]
        } else {
            sourceGoals = []
        }
        return sourceGoals.compactMap(normalizedMeetingGoal)
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
        persistTranslation: ((CaptionTranslationAttachmentTarget, String, Bool) -> Bool)? = nil
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
            persistTranslation: { [weak self] target, translatedText, isFinal in
                if let self, self.activeMeetingID == self.selectedMeetingID {
                    if (try? self.recorder.updateActiveTranscriptTranslation(
                        segmentID: target.primarySourceSegmentID,
                        text: translatedText,
                        targetLocale: target.targetLocale,
                        isFinal: isFinal
                    )) == true {
                        return true
                    }
                }
                do {
                    try TranscriptFileWriter.updateSegmentTranslation(
                        segmentID: target.primarySourceSegmentID,
                        text: translatedText,
                        targetLocale: target.targetLocale,
                        isFinal: isFinal,
                        textURL: textURL,
                        structuredURL: structuredURL
                    )
                    return true
                } catch {
                    return false
                }
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
        latestRealtimeCaptionSnapshot = nil
        resetLiveCaptionPipeline()
        clearLiveCaptionTurns()
        meetingProgressHealth.caption = .idle
        meetingProgressHealth.translation = .idle
        resetMeetingProgressState()
        configureMeetingProgressCoordinator()
    }

    private func resetLiveCaptionPipeline() {
        liveCaptionReplayTask?.cancel()
        liveCaptionReplayTask = nil
        liveCaptionReplaySequence += 1
        activeCaptionDocumentSignature = nil
        selectedMeetingReplaySignature = nil
        selectedMeetingReplayFileSignature = nil
        nextSelectedMeetingPendingTranslationRetryAt = nil
        resetDraftCaptionInputThrottleState(reason: "pipeline_reset")
        clearLiveCaptionTurns()
        liveCaptionPipeline = makeLiveCaptionPipeline()
        liveCaptionPipelineUsesCaptionTranslationProvider = false
        liveCaptionPipelineHasTranslationProvider = false
        realtimeCaptionSession.replacePipeline(makeLiveCaptionPipeline())
        realtimeCaptionSessionUsesCaptionTranslationProvider = false
        realtimeCaptionSessionHasTranslationProvider = false
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
        let goals = meetingGoal.map { [$0] } ?? []
        meetings[index].meetingGoals = goals
        meetings[index].meetingGoal = goals.first
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
            clearLiveCaptionTurns()
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
        guard let selectedMeetingID,
              let transcriptJSONURL = selectedMeeting?.transcriptJSONURL else {
            liveCaptionReplayTask = nil
            activeCaptionDocumentSignature = nil
            selectedMeetingReplaySignature = nil
            selectedMeetingReplayFileSignature = nil
            nextSelectedMeetingPendingTranslationRetryAt = nil
            clearLiveCaptionTurns()
            meetingProgressHealth.caption = .idle
            return
        }
        let fileSignature = Self.selectedMeetingTranscriptFileSignature(
            meetingID: selectedMeetingID,
            transcriptJSONURL: transcriptJSONURL
        )
        if selectedMeetingReplayFileSignature == fileSignature,
           let selectedMeetingReplaySignature,
           selectedMeetingReplaySignature.hasTranslationProvider,
           selectedMeetingReplaySignature.hasTranslationProvider == liveCaptionPipelineHasTranslationProvider {
            schedulePendingLiveTranslationsForUnchangedReplayIfNeeded()
            return
        }
        guard let document = selectedTranscriptDocument() else {
            liveCaptionReplayTask = nil
            activeCaptionDocumentSignature = nil
            selectedMeetingReplaySignature = nil
            selectedMeetingReplayFileSignature = nil
            nextSelectedMeetingPendingTranslationRetryAt = nil
            clearLiveCaptionTurns()
            meetingProgressHealth.caption = .idle
            return
        }
        let translationProvider = liveCaptionPipelineHasTranslationProvider
            ? nil
            : captionTranslationProviderForCurrentConfiguration(document: document)
        let replaySignature = SelectedMeetingReplaySignature(
            meetingID: selectedMeetingID,
            captionDocumentSignature: Self.captionDocumentSignature(document),
            sourceLocaleIdentifier: speechConfiguration.localeIdentifier,
            targetLocaleIdentifier: speechConfiguration.targetLocaleIdentifier,
            hasTranslationProvider: liveCaptionPipelineHasTranslationProvider || translationProvider != nil
        )
        guard selectedMeetingReplaySignature != replaySignature else {
            selectedMeetingReplayFileSignature = fileSignature
            schedulePendingLiveTranslationsForUnchangedReplayIfNeeded()
            return
        }
        liveCaptionReplayTask?.cancel()
        liveCaptionReplaySequence += 1
        let sequence = liveCaptionReplaySequence
        if !liveCaptionPipelineUsesCaptionTranslationProvider
            || (translationProvider != nil && !liveCaptionPipelineHasTranslationProvider) {
            liveCaptionPipeline = makeLiveCaptionPipeline(translationProvider: translationProvider)
            liveCaptionPipelineUsesCaptionTranslationProvider = true
            liveCaptionPipelineHasTranslationProvider = translationProvider != nil
        }
        activeCaptionDocumentSignature = replaySignature.captionDocumentSignature
        selectedMeetingReplaySignature = replaySignature
        selectedMeetingReplayFileSignature = fileSignature
        nextSelectedMeetingPendingTranslationRetryAt = Self.nextSelectedMeetingPendingTranslationRetryDate()
        publishLiveCaptionPipelineSnapshot(liveCaptionPipeline.replayCaptionsOnly(document))
        liveCaptionReplayTask = Task { [weak self] in
            guard let self else { return }
            guard liveCaptionReplaySequence == sequence else { return }
            let snapshot = await liveCaptionPipeline.scheduleLivePendingTranslations()
            guard liveCaptionReplaySequence == sequence else { return }
            publishLiveCaptionPipelineSnapshot(snapshot)
        }
    }

    private func schedulePendingLiveTranslationsForUnchangedReplayIfNeeded() {
        guard liveCaptionTurns.contains(where: { $0.translationHealth == .pending }) else {
            nextSelectedMeetingPendingTranslationRetryAt = nil
            return
        }
        let now = Date()
        if let nextSelectedMeetingPendingTranslationRetryAt,
           now < nextSelectedMeetingPendingTranslationRetryAt {
            return
        }
        nextSelectedMeetingPendingTranslationRetryAt = Self.nextSelectedMeetingPendingTranslationRetryDate(from: now)
        liveCaptionReplayTask = Task { [weak self] in
            guard let self else { return }
            let snapshot = await liveCaptionPipeline.scheduleLivePendingTranslations()
            publishLiveCaptionPipelineSnapshot(snapshot)
        }
    }

    private static func nextSelectedMeetingPendingTranslationRetryDate(from date: Date = Date()) -> Date {
        date.addingTimeInterval(selectedMeetingPendingTranslationRetryInterval)
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
            clearLiveCaptionTurns()
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
        activeCaptionDocumentSignature = Self.captionDocumentSignature(document)
        let snapshot = await liveCaptionPipeline.replay(document)
        if let sequence {
            guard liveCaptionReplaySequence == sequence else { return }
        } else {
            guard !Task.isCancelled else { return }
        }
        publishLiveCaptionPipelineSnapshot(snapshot)
    }

    private func bindLiveCaptionTurnsToActiveRecording() {
        liveCaptionReplayTask?.cancel()
        liveCaptionReplayTask = nil
        liveCaptionReplaySequence += 1
        selectedMeetingReplaySignature = nil
        selectedMeetingReplayFileSignature = nil
        nextSelectedMeetingPendingTranslationRetryAt = nil
        cancelPendingDraftCaptionInput(reason: "active_recording_selected")
        if let latestRealtimeCaptionSnapshot {
            publishLiveCaptionPipelineSnapshotImmediately(latestRealtimeCaptionSnapshot)
        } else {
            clearLiveCaptionTurns()
            meetingProgressHealth.caption = .idle
            meetingProgressHealth.translation = .idle
        }
    }

    private func selectedTranscriptDocument() -> TranscriptDocument? {
        guard let meeting = selectedMeeting,
              let transcriptJSONURL = meeting.transcriptJSONURL
        else {
            return nil
        }
        return try? TranscriptFileWriter.readDocument(from: transcriptJSONURL)
    }

    private static func captionDocumentSignature(_ document: TranscriptDocument) -> String {
        var parts = [String(document.version)]
        parts.reserveCapacity(document.segments.count + 1)
        for segment in document.segments {
            parts.append([
                segment.id,
                segment.speakerID ?? "",
                segment.speakerLabel ?? "",
                segment.text,
                segment.language ?? "",
                segment.sourceProvider,
                segment.isFinal ? "final" : "draft",
                segment.speechFinal ? "speechFinal" : "open"
            ].joined(separator: "\u{1F}"))
        }
        return parts.joined(separator: "\u{1E}")
    }

    private static func selectedMeetingTranscriptFileSignature(
        meetingID: UUID,
        transcriptJSONURL: URL
    ) -> SelectedMeetingTranscriptFileSignature {
        let attributes = try? FileManager.default.attributesOfItem(atPath: transcriptJSONURL.path)
        return SelectedMeetingTranscriptFileSignature(
            meetingID: meetingID,
            path: transcriptJSONURL.path,
            modificationTime: (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970,
            fileSize: (attributes?[.size] as? NSNumber)?.uint64Value
        )
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
        if !realtimeCaptionSessionUsesCaptionTranslationProvider {
            let translationProvider = captionTranslationProviderForCurrentConfiguration(document: latest.document)
            realtimeCaptionSession.replacePipeline(makeLiveCaptionPipeline(translationProvider: translationProvider))
            realtimeCaptionSessionUsesCaptionTranslationProvider = true
            realtimeCaptionSessionHasTranslationProvider = translationProvider != nil
        }
        activeCaptionDocumentSignature = Self.captionDocumentSignature(latest.document)
        let snapshot = await realtimeCaptionSession.apply(latest)
        guard !Task.isCancelled, isCurrentActiveCaptionApply(context) else { return }
        publishRealtimeCaptionPipelineSnapshot(snapshot)
        logCaptionSnapshotPublication(.original, snapshot: snapshot, path: "realtime")
        startRealtimeCaptionTranslationPumpIfNeeded(
            context: currentActiveCaptionTranslationContext(),
            snapshot: snapshot
        )
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
        invalidateActiveCaptionTranslationTasks()
        cancelPendingDraftCaptionInput(reason: "active_apply_invalidated")
    }

    private func invalidateActiveCaptionTranslationTasks() {
        activeCaptionTranslationGeneration += 1
        activeCaptionTranslationTask?.cancel()
        activeCaptionTranslationTask = nil
    }

    private func cancelPendingDraftCaptionInput(reason: String) {
        guard pendingDraftCaptionInput != nil || pendingDraftCaptionInputTask != nil else {
            return
        }
        currentPerformanceEventLogger()?.log(
            "caption_input_throttle_cancelled",
            metadata: [
                "reason": reason,
                "delayMilliseconds": String(draftCaptionInputThrottleNanoseconds / 1_000_000)
            ]
        )
        pendingDraftCaptionInputGeneration += 1
        pendingDraftCaptionInputTask?.cancel()
        pendingDraftCaptionInputTask = nil
        pendingDraftCaptionInput = nil
    }

    private func resetDraftCaptionInputThrottleState(reason: String) {
        cancelPendingDraftCaptionInput(reason: reason)
        hasPublishedActiveDraftCaptionInput = false
    }

    private func isCurrentActiveCaptionApply(_ context: ActiveCaptionApplyContext) -> Bool {
        context.sequence == activeCaptionApplySequence
            && context.activeMeetingID == activeMeetingID
            && context.selectedMeetingID == selectedMeetingID
    }

    private func currentActiveCaptionTranslationContext() -> ActiveCaptionTranslationContext {
        ActiveCaptionTranslationContext(
            activeMeetingID: activeMeetingID,
            selectedMeetingID: selectedMeetingID
        )
    }

    private func isCurrentActiveCaptionTranslation(_ context: ActiveCaptionTranslationContext) -> Bool {
        context.activeMeetingID == activeMeetingID
            && context.selectedMeetingID == selectedMeetingID
    }

    private func shouldThrottleDraftCaptionInput(
        _ results: [TranscriptSegmentAccumulationResult],
        context: ActiveCaptionApplyContext
    ) -> Bool {
        guard draftCaptionInputThrottleNanoseconds > 0 else { return false }
        guard isCurrentActiveCaptionApply(context) else { return false }
        guard activeMeetingID != nil else { return false }
        guard let latest = results.last else { return false }
        guard latest.plainTextReplacement == nil else { return false }
        guard !latest.changedSegmentIDs.isEmpty else { return false }
        let changedSegmentIDs = Set(latest.changedSegmentIDs)
        let changedSegments = latest.document.segments.filter { changedSegmentIDs.contains($0.id) }
        guard !changedSegments.isEmpty else { return false }
        return changedSegments.allSatisfy { segment in
            !segment.isFinal && segment.speechFinal != true
        }
    }

    private func latestChangedSegmentID(in results: [TranscriptSegmentAccumulationResult]) -> String? {
        results.last?.changedSegmentIDs.last
    }

    private func changedSegmentCount(in results: [TranscriptSegmentAccumulationResult]) -> Int {
        results.last?.changedSegmentIDs.count ?? 0
    }

    private func submitDraftCaptionInput(
        _ results: [TranscriptSegmentAccumulationResult],
        context: ActiveCaptionApplyContext
    ) {
        guard hasPublishedActiveDraftCaptionInput else {
            hasPublishedActiveDraftCaptionInput = true
            activeCaptionApplyTask = Task { [weak self] in
                guard let self else { return }
                await applyTranscriptAccumulationResultsToLiveCaptions(results, context: context)
                if meetingProgressCoordinator != nil {
                    await refreshMeetingProgress()
                }
            }
            return
        }

        let pending = PendingDraftCaptionInput(
            results: results,
            context: context,
            latestChangedSegmentID: latestChangedSegmentID(in: results),
            changedSegmentCount: changedSegmentCount(in: results)
        )
        let hadPending = pendingDraftCaptionInput != nil
        pendingDraftCaptionInput = pending
        pendingDraftCaptionInputGeneration += 1
        let generation = pendingDraftCaptionInputGeneration
        let delay = draftCaptionInputThrottleNanoseconds
        pendingDraftCaptionInputTask?.cancel()
        currentPerformanceEventLogger()?.log(
            hadPending ? "caption_input_throttle_coalesced" : "caption_input_throttle_scheduled",
            segmentID: pending.latestChangedSegmentID,
            metadata: draftCaptionInputThrottleMetadata(
                for: pending,
                reason: hadPending ? "replaced_pending" : "scheduled"
            )
        )
        pendingDraftCaptionInputTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await self?.firePendingDraftCaptionInput(generation: generation)
        }
    }

    private func firePendingDraftCaptionInput(generation: Int) async {
        guard generation == pendingDraftCaptionInputGeneration,
              let pending = pendingDraftCaptionInput
        else {
            return
        }
        pendingDraftCaptionInputTask = nil
        pendingDraftCaptionInput = nil
        currentPerformanceEventLogger()?.log(
            "caption_input_throttle_fired",
            segmentID: pending.latestChangedSegmentID,
            metadata: draftCaptionInputThrottleMetadata(for: pending, reason: "delay_elapsed")
        )
        guard isCurrentActiveCaptionApply(pending.context) else { return }
        activeCaptionApplyTask = Task { [weak self] in
            guard let self else { return }
            await applyTranscriptAccumulationResultsToLiveCaptions(pending.results, context: pending.context)
            if meetingProgressCoordinator != nil {
                await refreshMeetingProgress()
            }
        }
    }

    private func draftCaptionInputThrottleMetadata(
        for pending: PendingDraftCaptionInput,
        reason: String
    ) -> [String: String] {
        var metadata: [String: String] = [
            "delayMilliseconds": String(draftCaptionInputThrottleNanoseconds / 1_000_000),
            "changedSegmentCount": String(pending.changedSegmentCount),
            "reason": reason
        ]
        if let latestChangedSegmentID = pending.latestChangedSegmentID {
            metadata["latestChangedSegmentID"] = latestChangedSegmentID
        }
        if let activeMeetingID = pending.context.activeMeetingID {
            metadata["activeMeetingID"] = activeMeetingID.uuidString
        }
        if let selectedMeetingID = pending.context.selectedMeetingID {
            metadata["selectedMeetingID"] = selectedMeetingID.uuidString
        }
        return metadata
    }

    private func isCurrentCaptionFlush(_ context: ActiveCaptionApplyContext) -> Bool {
        context.sequence == activeCaptionApplySequence
            && context.selectedMeetingID == selectedMeetingID
    }

    private func clearLiveCaptionTurns() {
        cancelPendingDraftCaptionInput(reason: "caption_turns_cleared")
        cancelPendingLiveCaptionSnapshotPublication()
        liveCaptionTurns = []
    }

    private func cancelPendingLiveCaptionSnapshotPublication() {
        pendingLiveCaptionSnapshotGeneration += 1
        pendingLiveCaptionSnapshotTask?.cancel()
        pendingLiveCaptionSnapshotTask = nil
        pendingLiveCaptionSnapshot = nil
        pendingLiveCaptionSnapshotIsRealtime = false
    }

    private func publishLiveCaptionPipelineSnapshot(_ snapshot: LiveCaptionPipelineSnapshot) {
        publishLiveCaptionPipelineSnapshot(snapshot, isRealtimeSnapshot: false)
    }

    private func publishRealtimeCaptionPipelineSnapshot(_ snapshot: LiveCaptionPipelineSnapshot) {
        publishLiveCaptionPipelineSnapshot(snapshot, isRealtimeSnapshot: true)
    }

    private func publishLiveCaptionPipelineSnapshot(
        _ snapshot: LiveCaptionPipelineSnapshot,
        isRealtimeSnapshot: Bool
    ) {
        guard shouldDebounceLiveCaptionSnapshot(snapshot) else {
            cancelPendingLiveCaptionSnapshotPublication()
            if isRealtimeSnapshot {
                latestRealtimeCaptionSnapshot = snapshot
            }
            publishLiveCaptionPipelineSnapshotImmediately(snapshot)
            return
        }

        if let pendingLiveCaptionSnapshot {
            currentPerformanceEventLogger()?.log(
                "caption_snapshot_publication_coalesced",
                metadata: [
                    "pendingTurnCount": String(pendingLiveCaptionSnapshot.turns.count),
                    "replacementTurnCount": String(snapshot.turns.count),
                    "debounceMilliseconds": String(liveCaptionSnapshotDebounceNanoseconds / 1_000_000)
                ]
            )
        }
        pendingLiveCaptionSnapshot = snapshot
        pendingLiveCaptionSnapshotIsRealtime = isRealtimeSnapshot
        pendingLiveCaptionSnapshotGeneration += 1
        let generation = pendingLiveCaptionSnapshotGeneration
        let delay = liveCaptionSnapshotDebounceNanoseconds
        pendingLiveCaptionSnapshotTask?.cancel()
        pendingLiveCaptionSnapshotTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self?.publishPendingLiveCaptionSnapshot(generation: generation)
        }
    }

    private func shouldDebounceLiveCaptionSnapshot(_ snapshot: LiveCaptionPipelineSnapshot) -> Bool {
        guard liveCaptionSnapshotDebounceNanoseconds > 0 else { return false }
        guard !snapshot.turns.isEmpty else { return false }
        guard snapshot.captionHealth == .live else { return false }
        switch snapshot.translationHealth {
        case .failed, .degraded:
            return false
        case .idle, .pending, .live:
            break
        }
        let previousTurns = pendingLiveCaptionSnapshot?.turns ?? liveCaptionTurns
        guard !previousTurns.isEmpty else {
            return snapshot.turns.allSatisfy(isDelayableDraftCaptionTurn)
        }
        let previousTurnsByID = Dictionary(uniqueKeysWithValues: previousTurns.map { ($0.id, $0) })
        let snapshotTurnsByID = Dictionary(uniqueKeysWithValues: snapshot.turns.map { ($0.id, $0) })
        let changedSnapshotTurns = snapshot.turns.filter { previousTurnsByID[$0.id] != $0 }
        let removedPreviousTurns = previousTurns.filter { snapshotTurnsByID[$0.id] == nil }
        guard !changedSnapshotTurns.isEmpty || !removedPreviousTurns.isEmpty else {
            return false
        }
        return changedSnapshotTurns.allSatisfy(isDelayableDraftCaptionTurn)
            && removedPreviousTurns.allSatisfy(isDelayableDraftCaptionTurn)
    }

    private func isDelayableDraftCaptionTurn(_ turn: LiveCaptionTurn) -> Bool {
        turn.displayState == .draft
            && !turn.isFinal
            && turn.boundaryStrength != .hard
            && turn.captionHealth == .live
    }

    private func publishPendingLiveCaptionSnapshot(generation: Int) {
        guard generation == pendingLiveCaptionSnapshotGeneration,
              let snapshot = pendingLiveCaptionSnapshot
        else {
            return
        }
        let isRealtimeSnapshot = pendingLiveCaptionSnapshotIsRealtime
        pendingLiveCaptionSnapshotTask = nil
        pendingLiveCaptionSnapshot = nil
        pendingLiveCaptionSnapshotIsRealtime = false
        if isRealtimeSnapshot {
            latestRealtimeCaptionSnapshot = snapshot
        }
        publishLiveCaptionPipelineSnapshotImmediately(snapshot)
    }

    private func publishLiveCaptionPipelineSnapshotImmediately(_ snapshot: LiveCaptionPipelineSnapshot) {
        liveCaptionTurns = snapshot.turns
        meetingProgressHealth.caption = snapshot.captionHealth
        meetingProgressHealth.translation = snapshot.translationHealth
    }

    private func logCaptionSnapshotPublication(
        _ kind: CaptionSnapshotPublicationKind,
        snapshot: LiveCaptionPipelineSnapshot,
        path: String
    ) {
        currentPerformanceEventLogger()?.log(
            kind.rawValue,
            metadata: [
                "path": path,
                "turnCount": String(snapshot.turns.count),
                "captionHealth": String(describing: snapshot.captionHealth),
                "translationHealth": String(describing: snapshot.translationHealth)
            ]
        )
    }

    private func startRealtimeCaptionTranslationPumpIfNeeded(
        context: ActiveCaptionTranslationContext,
        snapshot: LiveCaptionPipelineSnapshot
    ) {
        guard realtimeCaptionSessionHasTranslationProvider || hasSameLanguagePendingTranslation(in: snapshot) else { return }
        guard isCurrentActiveCaptionTranslation(context) else { return }
        guard activeCaptionTranslationTask == nil else { return }
        activeCaptionTranslationGeneration += 1
        let generation = activeCaptionTranslationGeneration
        activeCaptionTranslationTask = Task { [weak self] in
            guard let self else { return }
            await runRealtimeCaptionTranslationPump(context: context, generation: generation)
        }
    }

    private func runRealtimeCaptionTranslationPump(
        context: ActiveCaptionTranslationContext,
        generation: Int
    ) async {
        while !Task.isCancelled {
            guard generation == activeCaptionTranslationGeneration,
                  isCurrentActiveCaptionTranslation(context)
            else {
                break
            }

            let snapshot = await realtimeCaptionSession.scheduleLivePendingTranslations()

            guard !Task.isCancelled,
                  generation == activeCaptionTranslationGeneration,
                  isCurrentActiveCaptionTranslation(context)
            else {
                break
            }

            publishRealtimeCaptionPipelineSnapshot(snapshot)
            logCaptionSnapshotPublication(.translationOverlay, snapshot: snapshot, path: "realtime")

            guard snapshot.turns.contains(where: { $0.translationHealth == .pending }) else {
                break
            }
            guard realtimeCaptionSessionHasTranslationProvider || hasSameLanguagePendingTranslation(in: snapshot) else {
                break
            }

            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        if generation == activeCaptionTranslationGeneration {
            activeCaptionTranslationTask = nil
        }
    }

    private func hasSameLanguagePendingTranslation(in snapshot: LiveCaptionPipelineSnapshot) -> Bool {
        snapshot.turns.contains { turn in
            turn.translationHealth == .pending
                && TranslationOptions(
                    sourceLocale: turn.sourceLocale,
                    targetLocale: turn.targetLocale
                ).isSameLanguage
        }
    }

    private func flushLiveCaptionPipeline(reason: LiveCaptionFreezeReason) {
        cancelPendingDraftCaptionInput(reason: "flush")
        let context = beginActiveCaptionApply()
        activeCaptionApplyTask?.cancel()
        let flushedSnapshot = realtimeCaptionSession.flushCaptionsOnly(reason: reason)
        publishRealtimeCaptionPipelineSnapshot(flushedSnapshot)
        activeCaptionApplyTask = Task { [weak self] in
            guard let self else { return }
            let snapshot = await realtimeCaptionSession.schedulePendingTranslations()
            guard !Task.isCancelled, isCurrentCaptionFlush(context) else { return }
            publishRealtimeCaptionPipelineSnapshot(snapshot)
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
