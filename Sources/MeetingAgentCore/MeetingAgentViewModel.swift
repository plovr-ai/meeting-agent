import Combine
import Foundation

@MainActor
public final class MeetingAgentViewModel: ObservableObject {
    @Published public private(set) var meetings: [MeetingRecord] = []
    @Published public private(set) var selectedMeetingID: UUID?
    @Published public private(set) var pendingCandidate: AudioCaptureTarget?
    @Published public private(set) var statusText: String = "Idle"

    private let store: MeetingStore
    private let recorder: MeetingRecorder
    private let processMonitor = MeetingProcessMonitor()
    private var activeTarget: AudioCaptureTarget?

    public init(store: MeetingStore = MeetingStore(), recorder: MeetingRecorder? = nil) {
        self.store = store
        self.recorder = recorder ?? MeetingRecorder(store: store)
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

    public func startRecordingForPendingCandidate(localeIdentifier: String = "en-US") async throws {
        guard let candidate = pendingCandidate else { return }
        let record = try recorder.prepareRecord(for: candidate)
        meetings.insert(record, at: 0)
        selectedMeetingID = record.id
        activeTarget = candidate
        pendingCandidate = nil
        try await recorder.startRecording(
            target: candidate,
            record: record,
            speechProvider: .local,
            localeIdentifier: localeIdentifier
        )
        statusText = "Recording \(record.name)"
    }

    public func drainRecordingFrames() {
        try? recorder.drainFrames()
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

    public var selectedMeeting: MeetingRecord? {
        meetings.first { $0.id == selectedMeetingID }
    }
}
