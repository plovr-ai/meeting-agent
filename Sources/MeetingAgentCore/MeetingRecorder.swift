import Foundation

public enum MeetingRecorderState: Equatable {
    case idle
    case prepared(UUID)
    case recording(UUID)
}

public final class MeetingRecorder {
    private let store: MeetingStore
    private var activeRecord: MeetingRecord?

    public private(set) var state: MeetingRecorderState = .idle

    public init(store: MeetingStore = MeetingStore()) {
        self.store = store
    }

    public func prepareRecord(
        for target: AudioCaptureTarget,
        startedAt: Date = Date()
    ) throws -> MeetingRecord {
        guard case .idle = state else {
            throw ProbeError.invalidArguments("A meeting recording is already active")
        }

        let stored = try store.createMeeting(
            name: target.displayName,
            startedAt: startedAt
        )
        activeRecord = stored.record
        state = .prepared(stored.record.id)
        return stored.record
    }

    public func markStopped(at endedAt: Date = Date()) throws -> MeetingRecord? {
        guard var record = activeRecord else {
            state = .idle
            return nil
        }

        record.endedAt = endedAt
        try store.save(record)
        activeRecord = nil
        state = .idle
        return record
    }
}
