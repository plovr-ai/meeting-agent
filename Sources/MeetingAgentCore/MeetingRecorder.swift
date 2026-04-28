import Foundation

public enum MeetingRecorderState: Equatable {
    case idle
    case prepared(UUID)
    case recording(UUID)
}

public final class MeetingRecorder {
    private let store: MeetingStore
    private var activeRecord: MeetingRecord?
    private let captureSessionFactory: () -> AudioCaptureSessionManaging
    private let wavWriterFactory: (URL, UInt32, UInt16) throws -> AudioFrameWriting
    private let transcriberFactory: (SpeechTranscriptionConfiguration, URL, Double, Int) async throws -> AudioFrameTranscriber
    private var captureSession: AudioCaptureSessionManaging?
    private var writer: AudioFrameWriting?
    private var transcriber: AudioFrameTranscriber?
    private var diagnosticsTracker: CaptureDiagnosticsTracker?
    private var pendingTranscriptionFrames: [AudioFrame] = []
    private var isStartingTranscriber = false
    private let pendingTranscriptionFrameLimit = 512

    public private(set) var state: MeetingRecorderState = .idle
    public weak var realtimeFrameConsumer: RealtimeFrameConsumer?

    public convenience init(store: MeetingStore = MeetingStore()) {
        self.init(
            store: store,
            captureSessionFactory: { AudioCaptureSession() },
            wavWriterFactory: { url, sampleRate, channelCount in
                try WavFileWriter(url: url, sampleRate: sampleRate, channelCount: channelCount)
            },
            transcriberFactory: { configuration, transcriptURL, sampleRate, channelCount in
                try await StreamingSpeechTranscriberFactory.startTranscriber(
                    configuration: configuration,
                    transcriptURL: transcriptURL,
                    sampleRate: sampleRate,
                    channelCount: channelCount
                )
            }
        )
    }

    init(
        store: MeetingStore,
        captureSessionFactory: @escaping () -> AudioCaptureSessionManaging,
        wavWriterFactory: @escaping (URL, UInt32, UInt16) throws -> AudioFrameWriting,
        transcriberFactory: @escaping (SpeechTranscriptionConfiguration, URL, Double, Int) async throws -> AudioFrameTranscriber
    ) {
        self.store = store
        self.captureSessionFactory = captureSessionFactory
        self.wavWriterFactory = wavWriterFactory
        self.transcriberFactory = transcriberFactory
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

    public func prepareRecord(
        _ record: MeetingRecord,
        for target: AudioCaptureTarget
    ) throws -> MeetingRecord {
        guard case .idle = state else {
            throw ProbeError.invalidArguments("A meeting recording is already active")
        }

        activeRecord = record
        diagnosticsTracker = CaptureDiagnosticsTracker(target: target)
        state = .prepared(record.id)
        try store.save(record)
        return record
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
        updatedRecord.transcriptionProviderID = effectiveConfiguration.effectiveTranscriptionProviderID
        updatedRecord.speechLocaleIdentifier = effectiveConfiguration.localeIdentifier
        updatedRecord.transcriptionStatus = .transcribing
        updatedRecord.transcriptionFailureReason = nil
        activeRecord = updatedRecord
        pendingTranscriptionFrames = []
        isStartingTranscriber = false
        try store.save(updatedRecord)

        let session = captureSessionFactory()
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
            writer = try wavWriterFactory(
                audioURL,
                UInt32(session.outputSampleRate.rounded()),
                UInt16(session.outputChannelCount)
            )
        }

        if let transcriptURL = updatedRecord.transcriptURL {
            do {
                isStartingTranscriber = true
                let startedTranscriber = try await transcriberFactory(
                    effectiveConfiguration,
                    transcriptURL,
                    session.outputSampleRate,
                    session.outputChannelCount
                )
                transcriber = startedTranscriber
                isStartingTranscriber = false
                try flushPendingTranscriptionFrames()
            } catch {
                isStartingTranscriber = false
                pendingTranscriptionFrames = []
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
            if transcriber != nil {
                try appendFrameToTranscriber(frame)
            } else if isStartingTranscriber {
                bufferPendingTranscriptionFrame(frame)
            }
        }
        deliverFramesToRealtimeConsumerForTesting(frames)
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

    public func deliverFramesToRealtimeConsumerForTesting(_ frames: [AudioFrame]) {
        guard !frames.isEmpty else { return }
        realtimeFrameConsumer?.consumeRealtimeFrames(frames)
    }

    private func persistTranscriptionFailure(_ message: String) throws {
        try markTranscriptionFailed(message)
    }

    private func flushPendingTranscriptionFrames() throws {
        let frames = pendingTranscriptionFrames
        pendingTranscriptionFrames = []
        for frame in frames {
            try appendFrameToTranscriber(frame)
        }
    }

    private func appendFrameToTranscriber(_ frame: AudioFrame) throws {
        do {
            try transcriber?.append(frame)
        } catch {
            try persistTranscriptionFailure("Speech recognition failed: \(error)")
            transcriber?.finish()
            transcriber = nil
        }
    }

    private func bufferPendingTranscriptionFrame(_ frame: AudioFrame) {
        pendingTranscriptionFrames.append(frame)
        if pendingTranscriptionFrames.count > pendingTranscriptionFrameLimit {
            pendingTranscriptionFrames.removeFirst(pendingTranscriptionFrames.count - pendingTranscriptionFrameLimit)
        }
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
