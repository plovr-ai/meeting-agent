import Combine
import Foundation

@MainActor
public final class MeetingAgentViewModel: ObservableObject {
    public static let supportedLocaleIdentifiers = [
        "en-US",
        "zh-Hans",
        "zh-TW",
        "ja-JP",
        "ko-KR",
        "fr-FR",
        "de-DE",
        "es-ES"
    ]

    @Published public private(set) var meetings: [MeetingRecord] = []
    @Published public private(set) var selectedMeetingID: UUID?
    @Published public private(set) var selectedMeetingArtifactSnapshot: MeetingArtifactSnapshot?
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
    private var latestRealtimeCaptionSnapshot: LiveCaptionPipelineSnapshot?
    private var liveCaptionPipeline: LiveCaptionPipeline
    private var activeCaptionApplySequence = 0
    private var activeCaptionApplyTask: Task<Void, Never>?
    private var liveCaptionReplayTask: Task<Void, Never>?
    private var liveCaptionReplaySequence = 0
    private var realtimeSpeakerIdentificationRuntime: RealtimeSpeakerIdentificationRuntime?
    private var speakerIdentityMap: [String: SpeakerIdentityResolution] = [:]
    private var activeCaptionDocumentSignature: String?
    private var selectedMeetingReplaySignature: SelectedMeetingReplaySignature?
    private var selectedMeetingReplayFileSignature: SelectedMeetingTranscriptFileSignature?
    private var recentlyStoppedLiveMeetingID: UUID?
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
    @Published public private(set) var meetingGoal: MeetingGoal?
    public var recommendedQuestions: [FollowUpQuestionSuggestion] {
        Array((meetingProgressState?.suggestedQuestions ?? []).prefix(2))
    }
    private var meetingProgressCoordinator: MeetingProgressCoordinator?
    private let summaryProviderFactory: (SpeechTranscriptionConfiguration) -> MeetingSummaryProvider
    private let processTargetsProvider: () -> [AudioCaptureTarget]
    private let processMonitor = MeetingProcessMonitor()
    private var activeSource: AudioCaptureSource?
    private var recorderEventTask: Task<Void, Never>?

    private var activeTarget: AudioCaptureTarget? {
        activeSource?.processTarget
    }

    struct ActiveCaptionApplyContext: Equatable {
        let sequence: Int
        let activeMeetingID: UUID?
        let selectedMeetingID: UUID?
    }

    private enum CaptionSnapshotPublicationKind: String {
        case original = "caption_original_snapshot_published"
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
        summaryProviderFactory: ((SpeechTranscriptionConfiguration) -> MeetingSummaryProvider)? = nil,
        liveCaptionSnapshotDebounceNanoseconds: UInt64 = 0,
        draftCaptionInputThrottleNanoseconds: UInt64 = 200_000_000,
        processTargetsProvider: @escaping () -> [AudioCaptureTarget] = RunningProcessDiscovery.currentTargets
    ) {
        self.store = store
        self.speechConfigurationStore = speechConfigurationStore
        self.recorder = recorder ?? MeetingRecorder(store: store)
        self.exportService = exportService
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
            configuration: resolvedSpeechConfiguration
        )
        liveCaptionPipeline = initialLiveCaptionPipeline
        realtimeCaptionSession = RealtimeCaptionSession(
            pipeline: Self.makeLiveCaptionPipeline(
                configuration: resolvedSpeechConfiguration
            )
        )
        refreshPrimaryChainPreflightResult()
        startRecorderEventListener()
    }

    deinit {
        recorderEventTask?.cancel()
    }

    public func loadMeetings() throws {
        meetings = try store.loadMeetings()
        selectedMeetingID = meetings.first?.id
        refreshSelectedMeetingArtifactSnapshot()
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
        refreshSelectedMeetingArtifactSnapshot()
        persistMeetingGoalForSelectedMeeting()
        resetLiveCaptionStore()
        pendingCandidate = nil
        activeSource = .process(candidate)
        activeMeetingID = record.id
        startRealtimeSpeakerIdentificationRuntime()
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
            hostedSummaryModelID: configuration.hostedSummaryModelID,
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
        refreshSelectedMeetingArtifactSnapshot()
        persistMeetingGoalForSelectedMeeting()
        try await startRecordingPreparedRecord(
            record,
            target: candidate,
            localeIdentifier: localeIdentifier ?? speechConfiguration.localeIdentifier
        )
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
        refreshSelectedMeetingArtifactSnapshot()
        meetingGoal = record.meetingGoal
        try await startRecordingPreparedRecord(record, target: candidate, localeIdentifier: localeIdentifier)
    }

    private func startRecordingPreparedRecord(
        _ record: MeetingRecord,
        target candidate: AudioCaptureTarget,
        localeIdentifier: String?
    ) async throws {
        resetLiveCaptionStore()
        activeSource = .process(candidate)
        activeMeetingID = record.id
        startRealtimeSpeakerIdentificationRuntime()
        pendingCandidate = nil
        let recordingLocaleIdentifier = localeIdentifier.map(Self.normalizedSpeechLocaleIdentifier)
            ?? Self.normalizedSpeechLocaleIdentifier(record.speechLocaleIdentifier)
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
            activeSource = nil
            activeMeetingID = nil
            throw error
        }
        statusText = "Recording \(record.name)"
    }

    public func startOfflineMicrophoneRecording(
        name: String = "New Meeting",
        localeIdentifier: String? = nil,
        startedAt: Date = Date()
    ) async throws {
        let source = AudioCaptureSource.microphone(displayName: "Computer Microphone")
        var record = try recorder.prepareRecord(named: name, source: source, startedAt: startedAt)
        record.meetingGoal = meetingGoal
        meetings.insert(record, at: 0)
        selectedMeetingID = record.id
        refreshSelectedMeetingArtifactSnapshot()
        persistMeetingGoalForSelectedMeeting()
        resetLiveCaptionStore()
        activeSource = source
        activeMeetingID = record.id
        startRealtimeSpeakerIdentificationRuntime()
        pendingCandidate = nil

        let recordingLocaleIdentifier = localeIdentifier.map(Self.normalizedSpeechLocaleIdentifier) ?? speechConfiguration.localeIdentifier
        var recordingConfiguration = speechConfiguration
        recordingConfiguration.localeIdentifier = recordingLocaleIdentifier
        do {
            try await recorder.startRecording(
                source: source,
                record: record,
                speechConfiguration: recordingConfiguration
            )
            refreshMeetingFromStore(record.id)
        } catch {
            if let stopped = try? recorder.stopRecording(),
               let index = meetings.firstIndex(where: { $0.id == stopped.id }) {
                meetings[index] = stopped
            }
            activeSource = nil
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
        if selectedMeetingID == id {
            refreshSelectedMeetingArtifactSnapshot()
        }
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
            refreshSelectedMeetingArtifactSnapshot()
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
        refreshSelectedMeetingArtifactSnapshot()
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
        updateRecordingStatus()
        let transcriptResults = recorder.drainTranscriptUpdates()
        if handleTranscriptResults(transcriptResults) {
            objectWillChange.send()
        }
    }

    @discardableResult
    public func pollActiveRecordingProcess(endedAt: Date = Date()) -> Bool {
        let didStop = stopRecordingIfTargetProcessEnded(at: endedAt)
        if didStop {
            objectWillChange.send()
        }
        return didStop
    }

    private func startRecorderEventListener() {
        recorderEventTask?.cancel()
        recorderEventTask = Task { [weak self, recorder] in
            for await event in recorder.events {
                self?.handleRecorderEvent(event)
            }
        }
    }

    private func handleRecorderEvent(_ event: MeetingRecorderEvent) {
        var shouldNotifyComputedStateChanged = true
        switch event {
        case .statusChanged(let snapshot):
            updateRecordingStatus(snapshot: snapshot)
        case .transcriptUpdates(let results):
            shouldNotifyComputedStateChanged = handleTranscriptResults(results)
        case .failed(let failure):
            statusText = "Recording failed: \(failure.message)"
        case .stopped(let stopped):
            if let stopped,
               let index = meetings.firstIndex(where: { $0.id == stopped.id }) {
                meetings[index] = stopped
                recentlyStoppedLiveMeetingID = stopped.id
                if selectedMeetingID == stopped.id {
                    refreshSelectedMeetingArtifactSnapshot()
                }
            }
        }
        if shouldNotifyComputedStateChanged {
            objectWillChange.send()
        }
    }

    private func handleTranscriptResults(_ transcriptResults: [TranscriptSegmentAccumulationResult]) -> Bool {
        if !transcriptResults.isEmpty && activeMeetingID == nil {
            return false
        }
        var shouldNotifyComputedStateChanged = isRecording || activeMeetingID != nil
        if transcriptResults.isEmpty {
            if !isRecording && activeMeetingID == nil && !shouldKeepRecentlyStoppedLiveCaptions() {
                refreshLiveCaptionTurnsFromSelectedMeetingSynchronously()
            }
            if meetingProgressCoordinator != nil {
                shouldNotifyComputedStateChanged = true
                Task { [weak self] in
                    await self?.refreshMeetingProgress()
                }
            }
        } else {
            shouldNotifyComputedStateChanged = true
            let currentContext = currentActiveCaptionApplyContext()
            if shouldThrottleDraftCaptionInput(transcriptResults, context: currentContext) {
                submitDraftCaptionInput(transcriptResults, context: currentContext)
            } else {
                let context = beginActiveCaptionApply()
                activeCaptionApplyTask?.cancel()
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
        return shouldNotifyComputedStateChanged
    }

    private func shouldKeepRecentlyStoppedLiveCaptions() -> Bool {
        guard let recentlyStoppedLiveMeetingID,
              selectedMeetingID == recentlyStoppedLiveMeetingID,
              !liveCaptionTurns.isEmpty
        else {
            return false
        }
        return true
    }

    public func stopRecording(at endedAt: Date = Date()) {
        if let stopped = try? recorder.stopRecording(at: endedAt),
           let index = meetings.firstIndex(where: { $0.id == stopped.id }) {
            meetings[index] = stopped
            recentlyStoppedLiveMeetingID = stopped.id
            if selectedMeetingID == stopped.id {
                refreshSelectedMeetingArtifactSnapshot()
            }
        }
        invalidateActiveCaptionApplyTasks(cancelTranslationExperience: false)
        flushLiveCaptionPipeline(reason: .manualStop)
        stopRealtimeSpeakerIdentificationRuntime()
        allowActiveTargetReprompt()
        activeSource = nil
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
            recentlyStoppedLiveMeetingID = stopped.id
            if selectedMeetingID == stopped.id {
                refreshSelectedMeetingArtifactSnapshot()
            }
        } else {
            stoppedID = nil
        }
        invalidateActiveCaptionApplyTasks(cancelTranslationExperience: false)
        flushLiveCaptionPipeline(reason: .manualStop)
        stopRealtimeSpeakerIdentificationRuntime()
        allowActiveTargetReprompt()
        activeSource = nil
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

        let transcript = try MeetingTranscriptStore.readDocument(from: transcriptJSONURL)
        let consumptionView = TranscriptConsumptionView.project(meetingID: meeting.id, document: transcript)
        let progress = progressState(for: meeting)
        let provider = summaryProviderFactory(speechConfiguration)
        let summary = try await provider.generateSummary(
            input: MeetingSummaryInput(
                meetingName: meeting.name,
                startedAt: meeting.startedAt,
                endedAt: meeting.endedAt,
                language: speechLocaleIdentifier,
                targetLanguage: speechConfiguration.localeIdentifier,
                meetingGoal: summaryGoalContext(for: progress),
                transcript: consumptionView,
                generatedAt: generatedAt
            )
        )
        try MeetingSummaryWriter.write(summary, jsonURL: summaryJSONURL, markdownURL: summaryMarkdownURL)
        try applyGeneratedTitleIfNeeded(summary: summary, meetingID: meetingID)
        if selectedMeetingID == meetingID {
            refreshSelectedMeetingArtifactSnapshot()
        }
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
        if selectedMeetingID == meetingID {
            refreshSelectedMeetingArtifactSnapshot()
        }
    }

    public func selectMeeting(_ id: UUID?) {
        let effectiveMeetingID = activeMeetingID ?? id
        if effectiveMeetingID != recentlyStoppedLiveMeetingID {
            recentlyStoppedLiveMeetingID = nil
        }
        selectedMeetingID = effectiveMeetingID
        refreshSelectedMeetingArtifactSnapshot()
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

    public func exportKnowledgePackage(for meetingID: UUID, to destinationURL: URL) throws {
        try export("Knowledge package", for: meetingID) { record in
            let summary = record.summaryJSONURL.flatMap { try? MeetingSummaryWriter.read(from: $0) }
            try exportService.exportKnowledgePackage(for: record, summary: summary, to: destinationURL)
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
        let retryLocaleIdentifier = Self.normalizedSpeechLocaleIdentifier(record.speechLocaleIdentifier)
        record.speechLocaleIdentifier = retryLocaleIdentifier
        meetings[index] = record
        try? store.save(record)
        if selectedMeetingID == meetingID {
            refreshSelectedMeetingArtifactSnapshot()
        }

        record.transcriptionStatus = .transcribing
        meetings[index] = record
        try? store.save(record)

        do {
            let previousTranscript = try? String(contentsOf: transcriptURL, encoding: .utf8)
            if speechConfiguration.usesDeepgram {
                var retryConfiguration = speechConfiguration
                retryConfiguration.localeIdentifier = retryLocaleIdentifier
                let provider = DeepgramAudioTranscriptionProvider(appConfiguration: retryConfiguration)
                let document = try await provider.transcribe(
                    audio: AudioInput(wavURL: audioURL, localeIdentifier: retryLocaleIdentifier),
                    options: TranscriptionOptions(sourceLocale: retryLocaleIdentifier)
                )
                try FileBackedTranscriptUpdateSink(transcriptURL: transcriptURL).persist(.replaceAll(document.segments))
            } else {
                var retryConfiguration = speechConfiguration
                retryConfiguration.localeIdentifier = retryLocaleIdentifier
                let provider = SpeechTranscriptionProviderFactory.provider(
                    for: retryConfiguration.provider,
                    configuration: retryConfiguration
                )
                try await provider.transcribeExistingAudio(context: SpeechTranscriptionContext(
                    inputAudioURL: audioURL,
                    transcriptURL: transcriptURL,
                    localeIdentifier: retryLocaleIdentifier,
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
        guard let activeSource, let status = recorder.currentCaptureStatus else { return }
        updateRecordingStatus(status: status, displayName: activeSource.displayName)
    }

    private func updateRecordingStatus(snapshot: MeetingRecorderStatusSnapshot) {
        guard let activeSource, let status = snapshot.captureStatus else { return }
        updateRecordingStatus(status: status, displayName: activeSource.displayName)
    }

    private func updateRecordingStatus(status: CaptureStatus, displayName: String) {
        switch status {
        case .preparingCapture:
            statusText = "Preparing capture for \(displayName)"
        case .recording:
            statusText = "Recording \(displayName)"
        case .recordingNoAudioDetected:
            statusText = "Recording \(displayName), but no audio detected"
        case .recordingSilentAudio:
            statusText = "Recording silent audio from \(displayName)"
        case .targetProcessEnded:
            statusText = "Target process ended: \(displayName)"
        case .captureFailed:
            statusText = "Capture failed: \(displayName)"
        case .recordingSaved:
            statusText = "Recording saved: \(displayName)"
        }
    }

    private func stopRecordingIfTargetProcessEnded(at endedAt: Date = Date()) -> Bool {
        guard let activeSource, case .process(let activeTarget) = activeSource else { return false }
        let targets = processTargetsProvider()
        guard processMonitor.hasProcessEnded(processID: activeTarget.processID, in: targets) else {
            return false
        }
        if let stopped = try? recorder.stopRecording(at: endedAt, endedReason: .targetProcessEnded),
           let index = meetings.firstIndex(where: { $0.id == stopped.id }) {
            meetings[index] = stopped
            recentlyStoppedLiveMeetingID = stopped.id
            if selectedMeetingID == stopped.id {
                refreshSelectedMeetingArtifactSnapshot()
            }
        }
        flushLiveCaptionPipeline(reason: .manualStop)
        statusText = "Target process ended: \(activeTarget.displayName)"
        self.activeSource = nil
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

    private func refreshSelectedMeetingArtifactSnapshot() {
        guard let selectedMeeting else {
            selectedMeetingArtifactSnapshot = nil
            return
        }
        selectedMeetingArtifactSnapshot = MeetingArtifactSnapshot.load(for: selectedMeeting)
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
        performanceEventLogger: PerformanceEventLogger? = nil
    ) -> LiveCaptionPipeline {
        LiveCaptionPipeline(
            sourceLocale: configuration.localeIdentifier,
            targetLocale: configuration.localeIdentifier,
            translationProvider: nil,
            performanceEventLogger: performanceEventLogger
        )
    }

    private func makeLiveCaptionPipeline() -> LiveCaptionPipeline {
        return Self.makeLiveCaptionPipeline(
            configuration: speechConfiguration,
            performanceEventLogger: currentPerformanceEventLogger()
        )
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
        resetDraftCaptionInputThrottleState(reason: "pipeline_reset")
        clearLiveCaptionTurns()
        liveCaptionPipeline = makeLiveCaptionPipeline()
        realtimeCaptionSession.replacePipeline(makeLiveCaptionPipeline())
        realtimeCaptionSessionUsesCaptionTranslationProvider = false
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
           selectedMeetingReplaySignature.meetingID == selectedMeetingID {
            return
        }
        guard let document = selectedTranscriptDocument() else {
            liveCaptionReplayTask = nil
            activeCaptionDocumentSignature = nil
            selectedMeetingReplaySignature = nil
            selectedMeetingReplayFileSignature = nil
            clearLiveCaptionTurns()
            meetingProgressHealth.caption = .idle
            return
        }
        let replaySignature = SelectedMeetingReplaySignature(
            meetingID: selectedMeetingID,
            captionDocumentSignature: Self.captionDocumentSignature(document),
            sourceLocaleIdentifier: speechConfiguration.localeIdentifier
        )
        guard selectedMeetingReplaySignature != replaySignature else {
            selectedMeetingReplayFileSignature = fileSignature
            return
        }
        liveCaptionReplayTask?.cancel()
        liveCaptionReplaySequence += 1
        liveCaptionPipeline = makeLiveCaptionPipeline()
        activeCaptionDocumentSignature = replaySignature.captionDocumentSignature
        selectedMeetingReplaySignature = replaySignature
        selectedMeetingReplayFileSignature = fileSignature
        publishLiveCaptionPipelineSnapshot(liveCaptionPipeline.replayCaptionsOnly(document))
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
        liveCaptionPipeline = makeLiveCaptionPipeline()
        activeCaptionDocumentSignature = Self.captionDocumentSignature(document)
        let captionSnapshot = liveCaptionPipeline.replayCaptionsOnly(document)
        if let sequence {
            guard liveCaptionReplaySequence == sequence else { return }
        } else {
            guard !Task.isCancelled else { return }
        }
        publishLiveCaptionPipelineSnapshot(captionSnapshot)
    }

    private func bindLiveCaptionTurnsToActiveRecording() {
        liveCaptionReplayTask?.cancel()
        liveCaptionReplayTask = nil
        liveCaptionReplaySequence += 1
        selectedMeetingReplaySignature = nil
        selectedMeetingReplayFileSignature = nil
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
        guard let document = try? TranscriptFileWriter.readDocument(from: transcriptJSONURL) else {
            return nil
        }
        return document
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

    func applySpeakerIdentityResolutionForTesting(_ resolution: SpeakerIdentityResolution) {
        applySpeakerIdentityResolution(resolution)
    }

    private func applyTranscriptAccumulationResultsToLiveCaptions(
        _ results: [TranscriptSegmentAccumulationResult],
        context: ActiveCaptionApplyContext
    ) async {
        guard let latest = results.last else { return }
        guard isCurrentActiveCaptionApply(context) else { return }
        if !realtimeCaptionSessionUsesCaptionTranslationProvider {
            realtimeCaptionSession.replacePipeline(makeLiveCaptionPipeline())
            realtimeCaptionSessionUsesCaptionTranslationProvider = true
        }
        activeCaptionDocumentSignature = Self.captionDocumentSignature(latest.document)
        var latestSnapshot: LiveCaptionPipelineSnapshot?
        for result in results {
            guard isCurrentActiveCaptionApply(context) else { return }
            latestSnapshot = await realtimeCaptionSession.apply(result)
        }
        guard let snapshot = latestSnapshot else { return }
        guard !Task.isCancelled, isCurrentActiveCaptionApply(context) else { return }
        publishRealtimeCaptionPipelineSnapshot(snapshot)
        logCaptionSnapshotPublication(.original, snapshot: snapshot, path: "realtime")
        submitRealtimeSpeakerIdentification(
            document: latest.document,
            changedSegmentIDs: Array(Set(results.flatMap(\.changedSegmentIDs)))
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

    private func currentActiveCaptionApplyContext() -> ActiveCaptionApplyContext {
        ActiveCaptionApplyContext(
            sequence: activeCaptionApplySequence,
            activeMeetingID: activeMeetingID,
            selectedMeetingID: selectedMeetingID
        )
    }

    private func invalidateActiveCaptionApplyTasks(cancelTranslationExperience: Bool = true) {
        activeCaptionApplySequence += 1
        activeCaptionApplyTask?.cancel()
        activeCaptionApplyTask = nil
        cancelPendingDraftCaptionInput(reason: "active_apply_invalidated")
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

    private func shouldThrottleDraftCaptionInput(
        _ results: [TranscriptSegmentAccumulationResult],
        context: ActiveCaptionApplyContext
    ) -> Bool {
        guard draftCaptionInputThrottleNanoseconds > 0 else { return false }
        guard isCurrentActiveCaptionApply(context) else { return false }
        guard activeMeetingID != nil else { return false }
        guard !results.isEmpty else { return false }
        guard results.allSatisfy({ $0.plainTextReplacement == nil }) else { return false }
        let changedSegments = results.flatMap { result in
            let changedSegmentIDs = Set(result.changedSegmentIDs)
            return result.document.segments.filter { changedSegmentIDs.contains($0.id) }
        }
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
        liveCaptionTurns = applyingSpeakerIdentityLabels(to: snapshot.turns)
        meetingProgressHealth.caption = snapshot.captionHealth
        meetingProgressHealth.translation = snapshot.translationHealth
    }

    private func startRealtimeSpeakerIdentificationRuntime() {
        speakerIdentityMap = [:]
        realtimeSpeakerIdentificationRuntime = RealtimeSpeakerIdentificationRuntime(
            embeddingProvider: SidecarSpeakerEmbeddingProvider(),
            performanceEventLogger: currentPerformanceEventLogger(),
            clipProvider: { [weak self] segments, destinationURL, minimumDurationSeconds in
                guard let self else { return nil }
                return try self.recorder.speakerEvidenceClip(
                    for: segments,
                    to: destinationURL,
                    minimumDurationSeconds: minimumDurationSeconds
                )
            },
            resolutionHandler: { [weak self] resolution in
                self?.applySpeakerIdentityResolution(resolution)
            }
        )
    }

    private func stopRealtimeSpeakerIdentificationRuntime() {
        realtimeSpeakerIdentificationRuntime?.reset()
        realtimeSpeakerIdentificationRuntime = nil
    }

    private func submitRealtimeSpeakerIdentification(
        document: TranscriptDocument,
        changedSegmentIDs: [String]
    ) {
        guard let realtimeSpeakerIdentificationRuntime,
              activeMeetingID != nil,
              !changedSegmentIDs.isEmpty
        else {
            return
        }
        let meetingID = activeMeetingID
        Task { [weak realtimeSpeakerIdentificationRuntime] in
            await realtimeSpeakerIdentificationRuntime?.submit(
                document: document,
                changedSegmentIDs: changedSegmentIDs,
                meetingID: meetingID
            )
        }
    }

    private func applySpeakerIdentityResolution(_ resolution: SpeakerIdentityResolution) {
        guard let speakerID = resolution.localSpeaker.identifier else { return }
        speakerIdentityMap[speakerID] = resolution
        let updatedTurns = applyingSpeakerIdentityLabels(to: liveCaptionTurns)
        let visibleTurnCount = updatedTurns.filter { $0.speaker.identifier == speakerID }.count
        liveCaptionTurns = updatedTurns
        currentPerformanceEventLogger()?.log(
            "speaker_identity_label_visible",
            segmentID: speakerID,
            metadata: [
                "speakerID": speakerID,
                "profileID": resolution.profile.id.uuidString,
                "decision": resolution.decision.rawValue,
                "displayLabel": resolution.displayLabel,
                "confidence": Self.metricString(resolution.confidence),
                "visibleTurnCount": String(visibleTurnCount)
            ]
        )
        objectWillChange.send()
    }

    private func applyingSpeakerIdentityLabels(to turns: [LiveCaptionTurn]) -> [LiveCaptionTurn] {
        turns.map { turn in
            guard let speakerID = turn.speaker.identifier,
                  let resolution = speakerIdentityMap[speakerID]
            else {
                return turn
            }
            var updated = turn
            updated.speaker = TranscriptSpeaker(identifier: speakerID, label: resolution.displayLabel)
            return updated
        }
    }

    private static func metricString(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.3f", value)
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

    private func flushLiveCaptionPipeline(reason: LiveCaptionFreezeReason) {
        cancelPendingDraftCaptionInput(reason: "flush")
        activeCaptionApplyTask?.cancel()
        let flushedSnapshot = realtimeCaptionSession.flushCaptionsOnly(reason: reason)
        publishRealtimeCaptionPipelineSnapshot(flushedSnapshot)
    }

    private func currentPerformanceEventLogger() -> PerformanceEventLogger? {
        selectedMeeting?.performanceEventsURL.map { PerformanceEventLogger(url: $0) }
    }

    public nonisolated static func openRouterCaptionTranslationProvider(
        for configuration: SpeechTranscriptionConfiguration
    ) -> TextTranslationProvider? {
        nil
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
