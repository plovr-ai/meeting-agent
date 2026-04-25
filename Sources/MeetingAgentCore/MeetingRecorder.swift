import Foundation

public enum MeetingRecorderState: Equatable {
    case idle
    case prepared(UUID)
    case recording(UUID)
}

public final class MeetingRecorder {
    private let store: MeetingStore
    private var activeRecord: MeetingRecord?
    private var captureSession: AudioCaptureSession?
    private var writer: WavFileWriter?
    private var transcriber: AudioFrameTranscriber?

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

    public func startRecording(
        target: AudioCaptureTarget,
        record: MeetingRecord,
        speechProvider: SpeechProvider = .local,
        localeIdentifier: String = "en-US"
    ) async throws {
        guard case .prepared(record.id) = state else {
            throw ProbeError.invalidArguments("Meeting must be prepared before recording starts")
        }

        let session = AudioCaptureSession()
        try session.start(target: target)
        captureSession = session

        if let audioURL = record.audioURL {
            writer = try WavFileWriter(
                url: audioURL,
                sampleRate: UInt32(session.outputSampleRate.rounded()),
                channelCount: UInt16(session.outputChannelCount)
            )
        }

        if let transcriptURL = record.transcriptURL {
            let provider = SpeechTranscriptionProviderFactory.provider(for: speechProvider)
            transcriber = try await provider.start(
                transcriptURL: transcriptURL,
                localeIdentifier: localeIdentifier
            )
        }

        state = .recording(record.id)
    }

    public func drainFrames() throws {
        guard let session = captureSession else { return }
        let frames = session.frameBuffer.drain()
        for frame in frames {
            try writer?.append(frame)
            try transcriber?.append(frame)
        }
    }

    public func stopRecording(at endedAt: Date = Date()) throws -> MeetingRecord? {
        try writer?.close()
        transcriber?.finish()
        captureSession?.stop()
        writer = nil
        transcriber = nil
        captureSession = nil
        return try markStopped(at: endedAt)
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
