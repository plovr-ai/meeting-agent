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
    private var diagnosticsTracker: CaptureDiagnosticsTracker?

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
        diagnosticsTracker = CaptureDiagnosticsTracker(target: target)
        state = .prepared(stored.record.id)
        return stored.record
    }

    public func startRecording(
        target: AudioCaptureTarget,
        record: MeetingRecord,
        speechProvider: SpeechProvider = .local,
        localeIdentifier: String = "en-US",
        speechConfiguration: SpeechTranscriptionConfiguration? = nil
    ) async throws {
        guard case .prepared(record.id) = state else {
            throw ProbeError.invalidArguments("Meeting must be prepared before recording starts")
        }
        var updatedRecord = record
        let effectiveConfiguration = speechConfiguration ?? SpeechTranscriptionConfiguration(
            provider: speechProvider,
            localeIdentifier: localeIdentifier,
            whisperBinaryPath: nil,
            whisperModelPath: nil
        )
        updatedRecord.speechProvider = effectiveConfiguration.provider
        updatedRecord.speechLocaleIdentifier = effectiveConfiguration.localeIdentifier
        updatedRecord.transcriptionStatus = .transcribing
        updatedRecord.transcriptionFailureReason = nil
        activeRecord = updatedRecord
        try store.save(updatedRecord)

        let session = AudioCaptureSession()
        do {
            try session.start(target: target)
        } catch {
            diagnosticsTracker?.finish(endedReason: .captureFailed)
            try diagnosticsTracker?.snapshot().writeIfPossible(to: updatedRecord.diagnosticsURL)
            throw error
        }
        captureSession = session
        diagnosticsTracker?.markRecording(
            sampleRate: session.outputSampleRate,
            channelCount: session.outputChannelCount
        )

        if let audioURL = updatedRecord.audioURL {
            writer = try WavFileWriter(
                url: audioURL,
                sampleRate: UInt32(session.outputSampleRate.rounded()),
                channelCount: UInt16(session.outputChannelCount)
            )
        }

        if let transcriptURL = updatedRecord.transcriptURL {
            let provider = SpeechTranscriptionProviderFactory.provider(
                for: effectiveConfiguration.provider,
                configuration: effectiveConfiguration
            )
            do {
                transcriber = try await provider.start(
                    transcriptURL: transcriptURL,
                    localeIdentifier: effectiveConfiguration.localeIdentifier
                )
            } catch {
                try markTranscriptionFailed("Speech recognition unavailable: \(error)")
                transcriber = nil
            }
        }

        state = .recording(record.id)
    }

    public func drainFrames() throws {
        guard let session = captureSession else { return }
        let bufferBacklog = session.frameBuffer.count
        let droppedFrameCount = session.frameBuffer.droppedFrameCount
        let frames = session.frameBuffer.drain()
        diagnosticsTracker?.record(
            frames: frames,
            bufferBacklog: bufferBacklog,
            droppedFrameCount: droppedFrameCount
        )
        for frame in frames {
            try writer?.append(frame)
            do {
                try transcriber?.append(frame)
            } catch {
                try persistTranscriptionFailure("Speech recognition failed: \(error)")
                transcriber?.finish()
                transcriber = nil
            }
        }
    }

    public func stopRecording(
        at endedAt: Date = Date(),
        endedReason: CaptureEndedReason = .saved
    ) throws -> MeetingRecord? {
        try writer?.close()
        let activeTranscriber = transcriber
        activeTranscriber?.finish()
        if let failureReason = activeTranscriber?.failureReason {
            try markTranscriptionFailed(failureReason)
        }
        captureSession?.stop()
        diagnosticsTracker?.finish(endedReason: endedReason)
        writer = nil
        transcriber = nil
        captureSession = nil
        return try markStopped(at: endedAt, endedReason: endedReason)
    }

    public func markStopped(
        at endedAt: Date = Date(),
        endedReason: CaptureEndedReason = .saved
    ) throws -> MeetingRecord? {
        guard var record = activeRecord else {
            state = .idle
            return nil
        }

        record.endedAt = endedAt
        if record.transcriptionStatus == .transcribing {
            record.transcriptionStatus = .transcribed
            record.transcriptionFailureReason = nil
        }
        diagnosticsTracker?.finish(endedReason: endedReason)
        try diagnosticsTracker?.snapshot().writeIfPossible(to: record.diagnosticsURL)
        diagnosticsTracker = nil
        try store.save(record)
        activeRecord = nil
        state = .idle
        return record
    }

    public var currentCaptureStatus: CaptureStatus? {
        diagnosticsTracker?.liveStatus
    }

    private func persistTranscriptionFailure(_ message: String) throws {
        try markTranscriptionFailed(message)
    }

    private func markTranscriptionFailed(_ message: String) throws {
        guard var record = activeRecord else { return }
        record.transcriptionStatus = .failed
        record.transcriptionFailureReason = message
        activeRecord = record
        try store.save(record)
    }
}

private extension CaptureDiagnostics {
    func writeIfPossible(to url: URL?) throws {
        guard let url else { return }
        try write(to: url)
    }
}
