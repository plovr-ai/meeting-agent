import Foundation

public enum MeetingRecorderState: Equatable {
    case idle
    case prepared(UUID)
    case recording(UUID)
}

public final class MeetingRecorder {
    private let store: MeetingStore
    private var activeRecord: MeetingRecord?
    private let processCaptureSessionFactory: () -> AudioCaptureSessionManaging
    private let microphoneCaptureSessionFactory: () -> AudioCaptureSessionManaging
    private let wavWriterFactory: (URL, UInt32, UInt16) throws -> AudioFrameWriting
    private let transcriberFactory: (SpeechTranscriptionConfiguration, URL, Double, Int, PerformanceEventLogger?, TranscriptUpdateSink?) async throws -> AudioFrameTranscriber
    private let silenceDetector: AudioSilenceDetector
    private var captureSession: AudioCaptureSessionManaging?
    private var writer: AudioFrameWriting?
    private var transcriber: AudioFrameTranscriber?
    private var transcriptUpdateSink: RecordingTranscriptUpdateSink?
    private var performanceEventLogger: PerformanceEventLogger?
    private var diagnosticsTracker: CaptureDiagnosticsTracker?
    private var pendingTranscriptionFrames: [AudioFrame] = []
    private var isStartingTranscriber = false
    private let speakerAudioEvidenceStore = SpeakerAudioEvidenceStore()
    // Keep roughly 30 seconds of common 10 ms Core Audio callbacks while hosted STT connects.
    private let pendingTranscriptionFrameLimit = 3_000

    public private(set) var state: MeetingRecorderState = .idle

    public convenience init(store: MeetingStore = MeetingStore()) {
        self.init(
            store: store,
            processCaptureSessionFactory: { AudioCaptureSession() },
            microphoneCaptureSessionFactory: { MicrophoneCaptureSession() },
            wavWriterFactory: { url, sampleRate, channelCount in
                try WavFileWriter(url: url, sampleRate: sampleRate, channelCount: channelCount)
            },
            transcriberFactory: { configuration, transcriptURL, sampleRate, channelCount, performanceEventLogger, transcriptUpdateSink in
                try await StreamingSpeechTranscriberFactory.startTranscriber(
                    configuration: configuration,
                    transcriptURL: transcriptURL,
                    sampleRate: sampleRate,
                    channelCount: channelCount,
                    performanceEventLogger: performanceEventLogger,
                    transcriptUpdateSink: transcriptUpdateSink,
                    speechEventSink: transcriptUpdateSink as? SpeechRecognitionEventSink
                )
            }
        )
    }

    convenience init(
        store: MeetingStore,
        captureSessionFactory: @escaping () -> AudioCaptureSessionManaging,
        wavWriterFactory: @escaping (URL, UInt32, UInt16) throws -> AudioFrameWriting,
        transcriberFactory: @escaping (SpeechTranscriptionConfiguration, URL, Double, Int, PerformanceEventLogger?, TranscriptUpdateSink?) async throws -> AudioFrameTranscriber,
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
        transcriberFactory: @escaping (SpeechTranscriptionConfiguration, URL, Double, Int, PerformanceEventLogger?, TranscriptUpdateSink?) async throws -> AudioFrameTranscriber,
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
        activeRecord = stored.record
        performanceEventLogger = stored.record.performanceEventsURL.map { PerformanceEventLogger(url: $0) }
        performanceEventLogger?.log(
            "meeting_prepared",
            metadata: [
                "meetingID": stored.record.id.uuidString,
                "captureSourceKind": source.kind.rawValue,
                "sourceDisplayName": source.displayName
            ]
        )
        diagnosticsTracker = CaptureDiagnosticsTracker(source: source)
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
        isStartingTranscriber = false
        speakerAudioEvidenceStore.reset()
        try store.save(updatedRecord)

        let session: AudioCaptureSessionManaging
        switch source.kind {
        case .process:
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

            if updatedRecord.transcriptURL != nil {
                isStartingTranscriber = true
            }
            captureSession = session
        } catch {
            session.stop()
            diagnosticsTracker?.finish(endedReason: .captureFailed)
            try diagnosticsTracker?.snapshot().writeIfPossible(to: updatedRecord.diagnosticsURL)
            throw error
        }

        if let transcriptURL = updatedRecord.transcriptURL {
            do {
                let updateSink = try RecordingTranscriptUpdateSink(
                    transcriptURL: transcriptURL,
                    performanceEventLogger: performanceEventLogger
                )
                transcriptUpdateSink = updateSink
                let startedTranscriber = try await transcriberFactory(
                    effectiveConfiguration,
                    transcriptURL,
                    session.outputSampleRate,
                    session.outputChannelCount,
                    performanceEventLogger,
                    updateSink
                )
                transcriber = startedTranscriber
                isStartingTranscriber = false
                try flushPendingTranscriptionFrames()
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
        if let first = frames.first, let last = frames.last {
            performanceEventLogger?.log(
                "audio_frames_drained",
                audioTimeSeconds: TimeInterval(last.timestampNanos) / 1_000_000_000,
                metadata: [
                    "frameCount": String(frames.count),
                    "firstFrameTimestampNanos": String(first.timestampNanos),
                    "lastFrameTimestampNanos": String(last.timestampNanos),
                    "bufferBacklog": String(bufferBacklog),
                    "droppedFrameCount": String(droppedFrameCount)
                ]
            )
        }
        diagnosticsTracker?.record(
            frames: frames,
            bufferBacklog: bufferBacklog,
            droppedFrameCount: droppedFrameCount
        )
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
        try writer?.close()
        let activeTranscriber = transcriber
        activeTranscriber?.finish()
        performanceEventLogger?.log(
            "recording_stopping",
            metadata: ["endedReason": endedReason.rawValue]
        )
        if let failureReason = activeTranscriber?.failureReason {
            try markTranscriptionFailed(failureReason)
        }
        captureSession?.stop()
        diagnosticsTracker?.finish(endedReason: endedReason)
        writer = nil
        transcriber = nil
        transcriptUpdateSink?.close()
        transcriptUpdateSink = nil
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
        return record
    }

    public var currentCaptureStatus: CaptureStatus? {
        diagnosticsTracker?.liveStatus
    }

    private func persistTranscriptionFailure(_ message: String) throws {
        try markTranscriptionFailed(message)
    }

    private func flushPendingTranscriptionFrames() throws {
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

private final class RecordingTranscriptUpdateSink: TranscriptUpdateSink, SpeechRecognitionEventSink {
    private let store: RecordingTranscriptPersistenceStore
    private let transcriptDirectoryURL: URL
    private var captionStore: MeetingTranscriptStore?
    private let performanceEventLogger: PerformanceEventLogger?
    private var realtimeAccumulator = TranscriptSegmentAccumulator()
    private var pendingResults: [TranscriptSegmentAccumulationResult] = []
    private let lock = NSLock()

    init(transcriptURL: URL, performanceEventLogger: PerformanceEventLogger?) throws {
        self.store = try RecordingTranscriptPersistenceStore(transcriptURL: transcriptURL)
        self.transcriptDirectoryURL = transcriptURL.deletingLastPathComponent()
        self.performanceEventLogger = performanceEventLogger
    }

    func receive(_ update: TranscriptSegmentUpdate) {
        lock.lock()
        defer { lock.unlock() }
        logEmitted(update)
        persist(update)
    }

    func receiveRealtime(_ update: TranscriptSegmentUpdate) {
        lock.lock()
        defer { lock.unlock() }
        logEmitted(update)
        let result = realtimeAccumulator.apply(update)
        pendingResults.append(TranscriptSegmentAccumulationResult(
            document: result.document,
            changedSegmentIDs: result.changedSegmentIDs,
            plainTextReplacement: result.plainTextReplacement,
            source: .realtime
        ))
    }

    func receiveFinal(_ update: TranscriptSegmentUpdate) {
        receive(update)
    }

    func receive(_ event: SpeechRecognitionEvent) {
        lock.lock()
        defer { lock.unlock() }
        do {
            let store = try speechEventStore()
            let document = try store.apply(event)
            let legacyDocument = document.transcriptDocument
            pendingResults.append(TranscriptSegmentAccumulationResult(
                document: legacyDocument,
                changedSegmentIDs: legacyDocument.segments.map(\.id),
                plainTextReplacement: nil,
                source: event.isFinal ? .final : .realtime
            ))
            logSpeechEvent(event, document: document)
        } catch {
            performanceEventLogger?.log(
                "speech_recognition_event_persist_failed",
                metadata: ["error": String(describing: error)]
            )
        }
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

    private func persist(_ update: TranscriptSegmentUpdate) {
        do {
            let result = try store.apply(update)
            pendingResults.append(result)
            logPersisted(result)
        } catch {
            return
        }
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
