import Combine
import Foundation

@MainActor
public final class MeetingAgentViewModel: ObservableObject {
    @Published public private(set) var meetings: [MeetingRecord] = []
    @Published public private(set) var selectedMeetingID: UUID?
    @Published public private(set) var pendingCandidate: AudioCaptureTarget?
    @Published public private(set) var statusText: String = "Idle"
    @Published public private(set) var speechLocaleIdentifier: String
    @Published public private(set) var speechProvider: SpeechProvider

    private let store: MeetingStore
    private let recorder: MeetingRecorder
    private let processMonitor = MeetingProcessMonitor()
    private var activeTarget: AudioCaptureTarget?

    public init(
        store: MeetingStore = MeetingStore(),
        recorder: MeetingRecorder? = nil,
        speechLocaleIdentifier: String = Locale.current.identifier,
        speechProvider: SpeechProvider = .whisper
    ) {
        self.store = store
        self.recorder = recorder ?? MeetingRecorder(store: store)
        self.speechLocaleIdentifier = Self.normalizedSpeechLocaleIdentifier(speechLocaleIdentifier)
        self.speechProvider = speechProvider
    }

    public func loadMeetings() throws {
        meetings = try store.loadMeetings()
        selectedMeetingID = meetings.first?.id
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
        let record = try recorder.prepareRecord(for: candidate, startedAt: startedAt)
        meetings.insert(record, at: 0)
        selectedMeetingID = record.id
        pendingCandidate = nil
        statusText = "Recording \(record.name)"
    }

    public func updateSpeechLocaleIdentifier(_ localeIdentifier: String) {
        speechLocaleIdentifier = Self.normalizedSpeechLocaleIdentifier(localeIdentifier)
    }

    public func startRecordingForPendingCandidate(localeIdentifier: String? = nil) async throws {
        guard let candidate = pendingCandidate else { return }
        try await startRecording(for: candidate, localeIdentifier: localeIdentifier)
    }

    public func startRecording(for candidate: AudioCaptureTarget, localeIdentifier: String? = nil) async throws {
        let record = try recorder.prepareRecord(for: candidate)
        meetings.insert(record, at: 0)
        selectedMeetingID = record.id
        activeTarget = candidate
        pendingCandidate = nil
        let recordingLocaleIdentifier = localeIdentifier.map(Self.normalizedSpeechLocaleIdentifier) ?? speechLocaleIdentifier
        do {
            try await recorder.startRecording(
                target: candidate,
                record: record,
                speechProvider: speechProvider,
                localeIdentifier: recordingLocaleIdentifier
            )
        } catch {
            if let stopped = try? recorder.stopRecording(),
               let index = meetings.firstIndex(where: { $0.id == stopped.id }) {
                meetings[index] = stopped
            }
            activeTarget = nil
            throw error
        }
        statusText = "Recording \(record.name)"
    }

    public func setRecordingStartError(_ error: Error) {
        statusText = "Recording failed: \(error)"
    }

    public func drainRecordingFrames() {
        try? recorder.drainFrames()
        updateRecordingStatus()
        objectWillChange.send()
    }

    public func stopRecording(at endedAt: Date = Date()) {
        if let stopped = try? recorder.stopRecording(at: endedAt),
           let index = meetings.firstIndex(where: { $0.id == stopped.id }) {
            meetings[index] = stopped
        }
        activeTarget = nil
        statusText = "Idle"
    }

    public func selectMeeting(_ id: UUID?) {
        selectedMeetingID = id
    }

    public func pollForMeetingCandidates() -> AudioCaptureTarget? {
        let targets = RunningProcessDiscovery.currentTargets()
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

    public var selectedMeeting: MeetingRecord? {
        meetings.first { $0.id == selectedMeetingID }
    }

    private static func normalizedSpeechLocaleIdentifier(_ localeIdentifier: String) -> String {
        let trimmed = localeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "en-US" : trimmed
    }
}
