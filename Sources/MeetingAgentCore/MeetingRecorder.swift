import Foundation

public enum MeetingRecorderState: Equatable {
    case idle
    case prepared(UUID)
    case recording(UUID)
}

public struct MeetingRecorderStatusSnapshot: Equatable {
    public let state: MeetingRecorderState
    public let captureStatus: CaptureStatus?
    public let bufferBacklog: Int
    public let droppedFrameCount: Int

    public init(
        state: MeetingRecorderState,
        captureStatus: CaptureStatus?,
        bufferBacklog: Int,
        droppedFrameCount: Int
    ) {
        self.state = state
        self.captureStatus = captureStatus
        self.bufferBacklog = bufferBacklog
        self.droppedFrameCount = droppedFrameCount
    }
}

public struct MeetingRecorderFailure: Equatable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

public enum MeetingRecorderEvent: Equatable {
    case statusChanged(MeetingRecorderStatusSnapshot)
    case transcriptUpdates([TranscriptSegmentAccumulationResult])
    case failed(MeetingRecorderFailure)
    case stopped(MeetingRecord?)
}

private extension MeetingCaptureMode {
    init(_ sourceKind: AudioCaptureSourceKind) {
        switch sourceKind {
        case .process:
            self = .process
        case .microphone:
            self = .microphone
        case .processWithMicrophone:
            self = .processWithMicrophone
        }
    }
}

public final class MeetingRecorder {
    private let store: MeetingStore
    private var activeRecord: MeetingRecord?
    private let processCaptureSessionFactory: () -> AudioCaptureSessionManaging
    private let microphoneCaptureSessionFactory: () -> AudioCaptureSessionManaging
    private let wavWriterFactory: (URL, UInt32, UInt16) throws -> AudioFrameWriting
    private let transcriberFactory: (
        SpeechTranscriptionConfiguration,
        URL,
        Double,
        Int,
        PerformanceEventLogger?,
        TranscriptUpdateSink?,
        SpeechRecognitionEventSink?
    ) async throws -> AudioFrameTranscriber
    private let silenceDetector: AudioSilenceDetector
    private var captureSession: AudioCaptureSessionManaging?
    private var writer: AudioFrameWriting?
    private var transcriber: AudioFrameTranscriber?
    private var microphoneCaptureSession: AudioCaptureSessionManaging?
    private var microphoneWriter: AudioFrameWriting?
    private var microphoneTranscriber: AudioFrameTranscriber?
    private var microphoneTranscriptAttributionSink: MicrophoneSpeakerAttributionSink?
    private var transcriptUpdateSink: RecordingTranscriptUpdateSink?
    private var performanceEventLogger: PerformanceEventLogger?
    private var diagnosticsTracker: CaptureDiagnosticsTracker?
    private var pendingTranscriptionFrames: [AudioFrame] = []
    private var audioDrainTelemetry = RecorderAudioDrainTelemetry()
    private var isStartingTranscriber = false
    private var processingTask: Task<Void, Never>?
    private var microphoneProcessingTask: Task<Void, Never>?
    private let processingLock = NSLock()
    private let eventLock = NSLock()
    private var eventContinuations: [UUID: AsyncStream<MeetingRecorderEvent>.Continuation] = [:]
    private let speakerAudioEvidenceStore = SpeakerAudioEvidenceStore()
    // Keep roughly 30 seconds of common 10 ms Core Audio callbacks while hosted STT connects.
    private let pendingTranscriptionFrameLimit = 3_000

    public private(set) var state: MeetingRecorderState = .idle

    public var events: AsyncStream<MeetingRecorderEvent> {
        AsyncStream { continuation in
            let id = UUID()
            eventLock.lock()
            eventContinuations[id] = continuation
            eventLock.unlock()

            continuation.onTermination = { [weak self] _ in
                self?.removeEventContinuation(id)
            }
        }
    }

    public convenience init(store: MeetingStore = MeetingStore()) {
        self.init(
            store: store,
            processCaptureSessionFactory: { AudioCaptureSession() },
            microphoneCaptureSessionFactory: { MicrophoneCaptureSession() },
            wavWriterFactory: { url, sampleRate, channelCount in
                try WavFileWriter(url: url, sampleRate: sampleRate, channelCount: channelCount)
            },
            transcriberFactory: { configuration, transcriptURL, sampleRate, channelCount, performanceEventLogger, transcriptUpdateSink, speechEventSink in
                try await StreamingSpeechTranscriberFactory.startTranscriber(
                    configuration: configuration,
                    transcriptURL: transcriptURL,
                    sampleRate: sampleRate,
                    channelCount: channelCount,
                    performanceEventLogger: performanceEventLogger,
                    transcriptUpdateSink: transcriptUpdateSink,
                    speechEventSink: speechEventSink ?? transcriptUpdateSink as? SpeechRecognitionEventSink
                )
            }
        )
    }

    convenience init(
        store: MeetingStore,
        captureSessionFactory: @escaping () -> AudioCaptureSessionManaging,
        wavWriterFactory: @escaping (URL, UInt32, UInt16) throws -> AudioFrameWriting,
        transcriberFactory: @escaping (
            SpeechTranscriptionConfiguration,
            URL,
            Double,
            Int,
            PerformanceEventLogger?,
            TranscriptUpdateSink?,
            SpeechRecognitionEventSink?
        ) async throws -> AudioFrameTranscriber,
        silenceDetector: AudioSilenceDetector = AudioSilenceDetector()
    ) {
        self.init(
            store: store,
            processCaptureSessionFactory: captureSessionFactory,
            microphoneCaptureSessionFactory: captureSessionFactory,
            wavWriterFactory: wavWriterFactory,
            transcriberFactory: transcriberFactory,
            silenceDetector: silenceDetector
        )
    }

    init(
        store: MeetingStore,
        processCaptureSessionFactory: @escaping () -> AudioCaptureSessionManaging,
        microphoneCaptureSessionFactory: @escaping () -> AudioCaptureSessionManaging,
        wavWriterFactory: @escaping (URL, UInt32, UInt16) throws -> AudioFrameWriting,
        transcriberFactory: @escaping (
            SpeechTranscriptionConfiguration,
            URL,
            Double,
            Int,
            PerformanceEventLogger?,
            TranscriptUpdateSink?,
            SpeechRecognitionEventSink?
        ) async throws -> AudioFrameTranscriber,
        silenceDetector: AudioSilenceDetector = AudioSilenceDetector()
    ) {
        self.store = store
        self.processCaptureSessionFactory = processCaptureSessionFactory
        self.microphoneCaptureSessionFactory = microphoneCaptureSessionFactory
        self.wavWriterFactory = wavWriterFactory
        self.transcriberFactory = transcriberFactory
        self.silenceDetector = silenceDetector
    }

    public func prepareRecord(
        for target: AudioCaptureTarget,
        startedAt: Date = Date()
    ) throws -> MeetingRecord {
        try prepareRecord(named: target.displayName, source: .process(target), startedAt: startedAt)
    }

    public func prepareRecord(
        named name: String,
        source: AudioCaptureSource,
        startedAt: Date = Date()
    ) throws -> MeetingRecord {
        guard case .idle = state else {
            throw ProbeError.invalidArguments("A meeting recording is already active")
        }

        let stored = try store.createMeeting(
            name: name,
            startedAt: startedAt
        )
        var record = stored.record
        record.captureMode = MeetingCaptureMode(source.kind)
        activeRecord = record
        performanceEventLogger = stored.record.performanceEventsURL.map { PerformanceEventLogger(url: $0) }
        performanceEventLogger?.log(
            "meeting_prepared",
            metadata: [
                "meetingID": record.id.uuidString,
                "captureSourceKind": source.kind.rawValue,
                "sourceDisplayName": source.displayName
            ]
        )
        diagnosticsTracker = CaptureDiagnosticsTracker(source: source)
        state = .prepared(record.id)
        try store.save(record)
        return record
    }

    public func prepareRecord(
        _ record: MeetingRecord,
        for target: AudioCaptureTarget
    ) throws -> MeetingRecord {
        guard case .idle = state else {
            throw ProbeError.invalidArguments("A meeting recording is already active")
        }

        activeRecord = record
        performanceEventLogger = record.performanceEventsURL.map { PerformanceEventLogger(url: $0) }
        performanceEventLogger?.log(
            "meeting_prepared",
            metadata: [
                "meetingID": record.id.uuidString,
                "targetDisplayName": target.displayName
            ]
        )
        diagnosticsTracker = CaptureDiagnosticsTracker(target: target)
        state = .prepared(record.id)
        try store.save(record)
        return record
    }

    public func startRecording(
        source: AudioCaptureSource,
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
        if performanceEventLogger == nil {
            performanceEventLogger = updatedRecord.performanceEventsURL.map { PerformanceEventLogger(url: $0) }
        }
        performanceEventLogger?.log(
            "recording_starting",
            metadata: [
                "meetingID": updatedRecord.id.uuidString,
                "transcriptionProviderID": updatedRecord.transcriptionProviderID,
                "speechLocaleIdentifier": updatedRecord.speechLocaleIdentifier,
                "captureSourceKind": source.kind.rawValue,
                "sourceDisplayName": source.displayName
            ]
        )
        pendingTranscriptionFrames = []
        audioDrainTelemetry.reset()
        isStartingTranscriber = false
        speakerAudioEvidenceStore.reset()
        try store.save(updatedRecord)

        let session: AudioCaptureSessionManaging
        switch source.kind {
        case .process, .processWithMicrophone:
            session = processCaptureSessionFactory()
        case .microphone:
            session = microphoneCaptureSessionFactory()
        }
        do {
            try session.start(source: source)
        } catch {
            diagnosticsTracker?.finish(endedReason: .captureFailed)
            try diagnosticsTracker?.snapshot().writeIfPossible(to: updatedRecord.diagnosticsURL)
            throw error
        }
        diagnosticsTracker?.markRecording(
            sampleRate: session.outputSampleRate,
            channelCount: session.outputChannelCount
        )
        performanceEventLogger?.log(
            "capture_started",
            metadata: [
                "sampleRate": String(session.outputSampleRate),
                "channelCount": String(session.outputChannelCount)
            ]
        )

        do {
            if let audioURL = updatedRecord.audioURL {
                writer = try wavWriterFactory(
                    audioURL,
                    UInt32(session.outputSampleRate.rounded()),
                    UInt16(session.outputChannelCount)
                )
            }

            if updatedRecord.transcriptJSONURL != nil {
                isStartingTranscriber = true
            }
            captureSession = session
            startAudioProcessing(session: session)
        } catch {
            session.stop()
            diagnosticsTracker?.finish(endedReason: .captureFailed)
            try diagnosticsTracker?.snapshot().writeIfPossible(to: updatedRecord.diagnosticsURL)
            throw error
        }

        if let transcriptJSONURL = updatedRecord.transcriptJSONURL {
            do {
                let updateSink = try RecordingTranscriptUpdateSink(
                    transcriptJSONURL: transcriptJSONURL,
                    performanceEventLogger: performanceEventLogger,
                    onResults: { [weak self] results in
                        self?.emit(.transcriptUpdates(results))
                    }
                )
                transcriptUpdateSink = updateSink
                let startedTranscriber = try await transcriberFactory(
                    effectiveConfiguration,
                    transcriptJSONURL,
                    session.outputSampleRate,
                    session.outputChannelCount,
                    performanceEventLogger,
                    updateSink,
                    updateSink
                )
                transcriber = startedTranscriber
                isStartingTranscriber = false
                try flushPendingTranscriptionFrames()
                if source.kind == .processWithMicrophone {
                    await startMicrophonePipeline(
                        source: source,
                        record: updatedRecord,
                        configuration: effectiveConfiguration,
                        updateSink: updateSink,
                        transcriptJSONURL: transcriptJSONURL
                    )
                }
            } catch {
                isStartingTranscriber = false
                pendingTranscriptionFrames = []
                transcriptUpdateSink = nil
                try markTranscriptionFailed("Speech recognition unavailable: \(error)")
                performanceEventLogger?.log(
                    "transcriber_start_failed",
                    metadata: ["error": String(describing: error)]
                )
                transcriber = nil
            }
        }

        state = .recording(record.id)
        performanceEventLogger?.log("recording_started")
    }

    public func startRecording(
        target: AudioCaptureTarget,
        record: MeetingRecord,
        speechProvider: SpeechProvider = .local,
        localeIdentifier: String = "en-US",
        speechConfiguration: SpeechTranscriptionConfiguration? = nil
    ) async throws {
        try await startRecording(
            source: .process(target),
            record: record,
            speechProvider: speechProvider,
            localeIdentifier: localeIdentifier,
            speechConfiguration: speechConfiguration
        )
    }

    public func drainFrames() throws {
        guard let session = captureSession else { return }
        let bufferBacklog = session.frameBuffer.count
        let droppedFrameCount = session.frameBuffer.droppedFrameCount
        let frames = session.frameBuffer.drain()
        try processFrames(
            frames,
            bufferBacklog: bufferBacklog,
            droppedFrameCount: droppedFrameCount
        )
    }

    private func drainMicrophoneFrames() throws {
        guard let session = microphoneCaptureSession else { return }
        let bufferBacklog = session.frameBuffer.count
        let droppedFrameCount = session.frameBuffer.droppedFrameCount
        let frames = session.frameBuffer.drain()
        try processMicrophoneFrames(
            frames,
            bufferBacklog: bufferBacklog,
            droppedFrameCount: droppedFrameCount
        )
    }

    private func processFrames(
        _ frames: [AudioFrame],
        bufferBacklog: Int,
        droppedFrameCount: Int
    ) throws {
        processingLock.lock()
        defer { processingLock.unlock() }

        if let event = audioDrainTelemetry.record(
            frames,
            bufferBacklog: bufferBacklog,
            droppedFrameCount: droppedFrameCount
        ) {
            performanceEventLogger?.log(
                "audio_frames_drained",
                audioTimeSeconds: event.audioTimeSeconds,
                metadata: event.metadata
            )
        }
        diagnosticsTracker?.record(
            frames: frames,
            bufferBacklog: bufferBacklog,
            droppedFrameCount: droppedFrameCount
        )
        emitStatus(bufferBacklog: bufferBacklog, droppedFrameCount: droppedFrameCount)
        speakerAudioEvidenceStore.append(frames)
        for frame in frames {
            try writer?.append(frame)
            if transcriber != nil {
                try appendFrameToTranscriber(frame)
            } else if isStartingTranscriber {
                bufferPendingTranscriptionFrame(frame)
            }
        }
    }

    private func processMicrophoneFrames(
        _ frames: [AudioFrame],
        bufferBacklog: Int,
        droppedFrameCount: Int
    ) throws {
        processingLock.lock()
        defer { processingLock.unlock() }

        performanceEventLogger?.log(
            "microphone_audio_frames_drained",
            metadata: [
                "frameCount": String(frames.count),
                "bufferBacklog": String(bufferBacklog),
                "droppedFrameCount": String(droppedFrameCount)
            ]
        )
        for frame in frames {
            try microphoneWriter?.append(frame)
            guard !silenceDetector.isSilent(frame) else { continue }
            do {
                try microphoneTranscriber?.append(frame)
            } catch {
                performanceEventLogger?.log(
                    "microphone_transcriber_append_failed",
                    metadata: ["error": String(describing: error)]
                )
                microphoneTranscriber?.finish()
                microphoneTranscriber = nil
            }
        }
    }

    private func startMicrophonePipeline(
        source: AudioCaptureSource,
        record: MeetingRecord,
        configuration: SpeechTranscriptionConfiguration,
        updateSink: RecordingTranscriptUpdateSink,
        transcriptJSONURL: URL
    ) async {
        let microphoneSource = AudioCaptureSource.microphone(displayName: source.microphoneDisplayName)
        let session = microphoneCaptureSessionFactory()
        do {
            try session.start(source: microphoneSource)
        } catch {
            performanceEventLogger?.log(
                "microphone_capture_start_failed",
                metadata: ["error": String(describing: error)]
            )
            return
        }

        microphoneCaptureSession = session
        if let microphoneAudioURL = record.microphoneAudioURL {
            do {
                microphoneWriter = try wavWriterFactory(
                    microphoneAudioURL,
                    UInt32(session.outputSampleRate.rounded()),
                    UInt16(session.outputChannelCount)
                )
            } catch {
                performanceEventLogger?.log(
                    "microphone_writer_start_failed",
                    metadata: ["error": String(describing: error)]
                )
            }
        }

        let attributionSink = MicrophoneSpeakerAttributionSink(downstream: updateSink)
        microphoneTranscriptAttributionSink = attributionSink
        startMicrophoneAudioProcessing(session: session)
        do {
            microphoneTranscriber = try await transcriberFactory(
                configuration,
                transcriptJSONURL,
                session.outputSampleRate,
                session.outputChannelCount,
                performanceEventLogger,
                attributionSink,
                attributionSink
            )
        } catch {
            performanceEventLogger?.log(
                "microphone_transcriber_start_failed",
                metadata: ["error": String(describing: error)]
            )
        }
    }

    public func drainTranscriptUpdates() -> [TranscriptSegmentAccumulationResult] {
        transcriptUpdateSink?.drainResults() ?? []
    }

    public func speakerEvidenceClip(
        for segments: [TranscriptSegment],
        to destinationURL: URL,
        minimumDurationSeconds: Double
    ) throws -> SpeakerAudioEvidenceClip? {
        try speakerAudioEvidenceStore.writeClip(
            for: segments,
            to: destinationURL,
            minimumDurationSeconds: minimumDurationSeconds
        )
    }

    public func stopRecording(
        at endedAt: Date = Date(),
        endedReason: CaptureEndedReason = .saved
    ) throws -> MeetingRecord? {
        processingTask?.cancel()
        processingTask = nil
        microphoneProcessingTask?.cancel()
        microphoneProcessingTask = nil
        captureSession?.frameBuffer.finish()
        microphoneCaptureSession?.frameBuffer.finish()
        try drainFrames()
        try drainMicrophoneFrames()
        flushAudioDrainTelemetry()
        try writer?.close()
        try microphoneWriter?.close()
        let activeTranscriber = transcriber
        let activeMicrophoneTranscriber = microphoneTranscriber
        activeTranscriber?.finish()
        activeMicrophoneTranscriber?.finish()
        performanceEventLogger?.log(
            "recording_stopping",
            metadata: ["endedReason": endedReason.rawValue]
        )
        if let failureReason = activeTranscriber?.failureReason {
            try markTranscriptionFailed(failureReason)
        }
        captureSession?.stop()
        microphoneCaptureSession?.stop()
        diagnosticsTracker?.finish(endedReason: endedReason)
        writer = nil
        microphoneWriter = nil
        transcriber = nil
        microphoneTranscriber = nil
        microphoneTranscriptAttributionSink = nil
        transcriptUpdateSink?.close()
        transcriptUpdateSink = nil
        captureSession = nil
        microphoneCaptureSession = nil
        let stopped = try markStopped(at: endedAt, endedReason: endedReason)
        emit(.stopped(stopped))
        return stopped
    }

    private func flushAudioDrainTelemetry() {
        guard let event = audioDrainTelemetry.flush() else { return }
        performanceEventLogger?.log(
            "audio_frames_drained",
            audioTimeSeconds: event.audioTimeSeconds,
            metadata: event.metadata
        )
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
        performanceEventLogger?.log(
            "recording_stopped",
            metadata: [
                "meetingID": record.id.uuidString,
                "endedReason": endedReason.rawValue,
                "transcriptionStatus": record.transcriptionStatus.rawValue
            ]
        )
        performanceEventLogger = nil
        activeRecord = nil
        speakerAudioEvidenceStore.reset()
        state = .idle
        emitStatus(bufferBacklog: 0, droppedFrameCount: 0)
        return record
    }

    public var currentCaptureStatus: CaptureStatus? {
        diagnosticsTracker?.liveStatus
    }

    private func startAudioProcessing(session: AudioCaptureSessionManaging) {
        processingTask?.cancel()
        processingTask = Task { [weak self, weak session] in
            guard let session else { return }
            for await frames in session.frameBuffer.batches {
                if Task.isCancelled { break }
                guard let self else { break }
                let bufferBacklog = session.frameBuffer.count
                let droppedFrameCount = session.frameBuffer.droppedFrameCount
                do {
                    try self.processFrames(
                        frames,
                        bufferBacklog: bufferBacklog,
                        droppedFrameCount: droppedFrameCount
                    )
                } catch {
                    self.emit(.failed(MeetingRecorderFailure(message: String(describing: error))))
                }
            }
        }
    }

    private func startMicrophoneAudioProcessing(session: AudioCaptureSessionManaging) {
        microphoneProcessingTask?.cancel()
        microphoneProcessingTask = Task { [weak self, weak session] in
            guard let session else { return }
            for await frames in session.frameBuffer.batches {
                if Task.isCancelled { break }
                guard let self else { break }
                let bufferBacklog = session.frameBuffer.count
                let droppedFrameCount = session.frameBuffer.droppedFrameCount
                do {
                    try self.processMicrophoneFrames(
                        frames,
                        bufferBacklog: bufferBacklog,
                        droppedFrameCount: droppedFrameCount
                    )
                } catch {
                    self.emit(.failed(MeetingRecorderFailure(message: String(describing: error))))
                }
            }
        }
    }

    private func emitStatus(bufferBacklog: Int, droppedFrameCount: Int) {
        emit(.statusChanged(MeetingRecorderStatusSnapshot(
            state: state,
            captureStatus: diagnosticsTracker?.liveStatus,
            bufferBacklog: bufferBacklog,
            droppedFrameCount: droppedFrameCount
        )))
    }

    private func emit(_ event: MeetingRecorderEvent) {
        let continuations: [AsyncStream<MeetingRecorderEvent>.Continuation]
        eventLock.lock()
        continuations = Array(eventContinuations.values)
        eventLock.unlock()

        for continuation in continuations {
            continuation.yield(event)
        }
    }

    private func removeEventContinuation(_ id: UUID) {
        eventLock.lock()
        eventContinuations.removeValue(forKey: id)
        eventLock.unlock()
    }

    private func persistTranscriptionFailure(_ message: String) throws {
        try markTranscriptionFailed(message)
    }

    private func flushPendingTranscriptionFrames() throws {
        processingLock.lock()
        defer { processingLock.unlock() }

        let frames = pendingTranscriptionFrames
        pendingTranscriptionFrames = []
        diagnosticsTracker?.recordStartupReplay(frames: frames)
        for frame in frames {
            try appendFrameToTranscriber(frame)
        }
    }

    private func appendFrameToTranscriber(_ frame: AudioFrame) throws {
        guard !silenceDetector.isSilent(frame) else { return }
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
            let overflow = pendingTranscriptionFrames.count - pendingTranscriptionFrameLimit
            pendingTranscriptionFrames.removeFirst(overflow)
            diagnosticsTracker?.recordDroppedStartupReplayFrames(overflow)
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

private struct RecorderAudioDrainTelemetry {
    private struct Pending {
        var frameCount: Int = 0
        var batchCount: Int = 0
        var pcmBytes: Int = 0
        var audioDurationSeconds: Double = 0
        var firstFrameTimestampNanos: UInt64?
        var lastFrameTimestampNanos: UInt64?
        var maxBufferBacklog: Int = 0
        var droppedFrameCount: Int = 0
        var audioTimeSeconds: Double = 0
    }

    struct LogEvent {
        let audioTimeSeconds: Double
        let metadata: [String: String]
    }

    private var pending = Pending()
    private let flushAudioDurationSeconds = 1.0

    mutating func reset() {
        pending = Pending()
    }

    mutating func record(
        _ frames: [AudioFrame],
        bufferBacklog: Int,
        droppedFrameCount: Int
    ) -> LogEvent? {
        guard let first = frames.first, let last = frames.last else { return nil }
        if pending.firstFrameTimestampNanos == nil {
            pending.firstFrameTimestampNanos = first.timestampNanos
        }
        pending.frameCount += frames.count
        pending.batchCount += 1
        pending.pcmBytes += frames.reduce(0) { $0 + $1.pcm.count }
        pending.audioDurationSeconds += frames.reduce(0) { $0 + frameDurationSeconds($1) }
        pending.lastFrameTimestampNanos = last.timestampNanos
        pending.maxBufferBacklog = max(pending.maxBufferBacklog, bufferBacklog)
        pending.droppedFrameCount = droppedFrameCount
        pending.audioTimeSeconds = TimeInterval(last.timestampNanos) / 1_000_000_000
        guard pending.audioDurationSeconds >= flushAudioDurationSeconds else {
            return nil
        }
        return flush()
    }

    mutating func flush() -> LogEvent? {
        guard pending.frameCount > 0 else { return nil }
        let event = LogEvent(
            audioTimeSeconds: pending.audioTimeSeconds,
            metadata: [
                "frameCount": String(pending.frameCount),
                "batchCount": String(pending.batchCount),
                "pcmBytes": String(pending.pcmBytes),
                "audioDurationSeconds": Self.metricString(pending.audioDurationSeconds),
                "firstFrameTimestampNanos": String(pending.firstFrameTimestampNanos ?? 0),
                "lastFrameTimestampNanos": String(pending.lastFrameTimestampNanos ?? 0),
                "bufferBacklog": String(pending.maxBufferBacklog),
                "droppedFrameCount": String(pending.droppedFrameCount)
            ]
        )
        reset()
        return event
    }

    private func frameDurationSeconds(_ frame: AudioFrame) -> Double {
        guard frame.sampleRate > 0, frame.channelCount > 0 else { return 0 }
        let bytesPerSample = 2
        let sampleCount = frame.pcm.count / bytesPerSample / frame.channelCount
        return Double(sampleCount) / frame.sampleRate
    }

    private static func metricString(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(value)
    }
}

private final class RecordingTranscriptUpdateSink: TranscriptUpdateSink, SpeechRecognitionEventSink {
    private let store: RecordingTranscriptPersistenceStore
    private let transcriptDirectoryURL: URL
    private var captionStore: MeetingTranscriptStore?
    private let performanceEventLogger: PerformanceEventLogger?
    private let onResults: ([TranscriptSegmentAccumulationResult]) -> Void
    private var realtimeAccumulator = TranscriptSegmentAccumulator()
    private var pendingResults: [TranscriptSegmentAccumulationResult] = []
    private let lock = NSLock()

    init(
        transcriptJSONURL: URL,
        performanceEventLogger: PerformanceEventLogger?,
        onResults: @escaping ([TranscriptSegmentAccumulationResult]) -> Void = { _ in }
    ) throws {
        self.store = try RecordingTranscriptPersistenceStore(transcriptJSONURL: transcriptJSONURL)
        self.transcriptDirectoryURL = transcriptJSONURL.deletingLastPathComponent()
        self.performanceEventLogger = performanceEventLogger
        self.onResults = onResults
    }

    func receive(_ update: TranscriptSegmentUpdate) {
        lock.lock()
        logEmitted(update)
        let results = persist(update)
        lock.unlock()
        publish(results)
    }

    func receiveRealtime(_ update: TranscriptSegmentUpdate) {
        lock.lock()
        logEmitted(update)
        let result = realtimeAccumulator.apply(update)
        let emitted = TranscriptSegmentAccumulationResult(
            document: result.document,
            changedSegmentIDs: result.changedSegmentIDs,
            plainTextReplacement: result.plainTextReplacement,
            source: .realtime
        )
        pendingResults.append(emitted)
        let results = [emitted]
        lock.unlock()
        publish(results)
    }

    func receiveFinal(_ update: TranscriptSegmentUpdate) {
        receive(update)
    }

    func receive(_ event: SpeechRecognitionEvent) {
        lock.lock()
        var results: [TranscriptSegmentAccumulationResult] = []
        do {
            let store = try speechEventStore()
            let document = try store.apply(event)
            let legacyDocument = document.transcriptDocument
            let result = TranscriptSegmentAccumulationResult(
                document: legacyDocument,
                changedSegmentIDs: legacyDocument.segments.map(\.id),
                plainTextReplacement: nil,
                source: event.isFinal ? .final : .realtime
            )
            pendingResults.append(result)
            results = [result]
            logSpeechEvent(event, document: document)
        } catch {
            performanceEventLogger?.log(
                "speech_recognition_event_persist_failed",
                metadata: ["error": String(describing: error)]
            )
        }
        lock.unlock()
        publish(results)
    }

    func drainResults() -> [TranscriptSegmentAccumulationResult] {
        lock.lock()
        defer { lock.unlock() }
        let results = pendingResults
        pendingResults.removeAll()
        return results
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        if let captionStore {
            try? captionStore.flushSnapshot()
        } else {
            try? store.close()
        }
    }

    private func persist(_ update: TranscriptSegmentUpdate) -> [TranscriptSegmentAccumulationResult] {
        do {
            let result = try store.apply(update)
            pendingResults.append(result)
            logPersisted(result)
            return [result]
        } catch {
            return []
        }
    }

    private func publish(_ results: [TranscriptSegmentAccumulationResult]) {
        guard !results.isEmpty else { return }
        onResults(results)
    }

    private func logPersisted(_ result: TranscriptSegmentAccumulationResult) {
        if let text = result.plainTextReplacement {
            performanceEventLogger?.log(
                "transcript_segment_persisted",
                textLength: text.count,
                metadata: ["update": "replaceWithPlainText"]
            )
        } else {
            for segment in result.document.segments where result.changedSegmentIDs.contains(segment.id) {
                performanceEventLogger?.logSegment(
                    "transcript_segment_persisted",
                    segment: segment
                )
            }
        }
    }

    private func logEmitted(_ update: TranscriptSegmentUpdate) {
        switch update {
        case .upsert(let segment):
            performanceEventLogger?.logSegment("transcript_segment_emitted", segment: segment)
        case .replaceAll(let segments):
            for segment in segments {
                performanceEventLogger?.logSegment("transcript_segment_emitted", segment: segment)
            }
        case .replaceWithPlainText(let text):
            performanceEventLogger?.log(
                "transcript_segment_emitted",
                textLength: text.count,
                metadata: ["update": "replaceWithPlainText"]
            )
        case .translationPatch(let segmentID, let text, let targetLocale, let isFinal):
            performanceEventLogger?.log(
                "transcript_segment_emitted",
                segmentID: segmentID,
                isFinal: isFinal,
                textLength: text.count,
                metadata: [
                    "update": "translationPatch",
                    "targetLocale": targetLocale
                ]
            )
        }
    }

    private func logSpeechEvent(_ event: SpeechRecognitionEvent, document: CaptionDocument) {
        guard let payload = event.payload else { return }
        performanceEventLogger?.log(
            "speech_recognition_event_persisted",
            segmentID: payload.providerUtteranceID,
            isFinal: event.isFinal,
            textLength: payload.text.count,
            metadata: [
                "providerID": payload.providerID,
                "turnCount": String(document.turns.count),
                "speakerID": payload.speaker?.identifier ?? ""
            ]
        )
    }

    private func speechEventStore() throws -> MeetingTranscriptStore {
        if let captionStore {
            return captionStore
        }
        let store = try MeetingTranscriptStore(directoryURL: transcriptDirectoryURL)
        captionStore = store
        return store
    }
}

private extension CaptureDiagnostics {
    func writeIfPossible(to url: URL?) throws {
        guard let url else { return }
        try write(to: url)
    }
}
