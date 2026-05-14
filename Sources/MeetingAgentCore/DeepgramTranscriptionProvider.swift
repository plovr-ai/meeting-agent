import Foundation

public enum DeepgramTranscriptionConfiguration: Equatable {
    case available(apiKey: String, model: String, language: String)
    case unavailable(String)

    public var apiKey: String {
        if case .available(let apiKey, _, _) = self { return apiKey }
        return ""
    }

    public var model: String {
        if case .available(_, let model, _) = self { return model }
        return ""
    }

    public var language: String {
        if case .available(_, _, let language) = self { return language }
        return ""
    }

    public init(apiKey: String?, model: String?, language: String? = "multi") {
        guard let apiKey = SpeechTranscriptionConfiguration.normalized(apiKey) else {
            self = .unavailable("Deepgram API key is not configured")
            return
        }
        guard let model = SpeechTranscriptionConfiguration.normalized(model) else {
            self = .unavailable("Deepgram model is not configured")
            return
        }
        self = .available(
            apiKey: apiKey,
            model: model,
            language: SpeechTranscriptionConfiguration.normalized(language, fallback: deepgramLanguage) ?? deepgramLanguage
        )
    }

    public static func app(
        _ configuration: SpeechTranscriptionConfiguration,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Self {
        DeepgramTranscriptionConfiguration(
            apiKey: configuration.deepgramAPIKey ?? environment["MEETING_AGENT_DEEPGRAM_API_KEY"],
            model: configuration.deepgramModelID,
            language: configuration.localeIdentifier
        )
    }
}

public enum DeepgramRawResponseTransport: String, Equatable {
    case http
    case webSocket
}

private let deepgramLanguage = "multi"

public struct DeepgramRawResponseContext: Equatable {
    public let providerID: String
    public let transport: DeepgramRawResponseTransport

    public init(providerID: String, transport: DeepgramRawResponseTransport) {
        self.providerID = providerID
        self.transport = transport
    }
}

public protocol DeepgramRawResponseLogger {
    func logRawResponse(_ data: Data, context: DeepgramRawResponseContext)
}

public final class DeepgramEnvironmentRawResponseLogger: DeepgramRawResponseLogger {
    private let isEnabled: Bool
    private let errorOutput: FileHandle

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        errorOutput: FileHandle = .standardError
    ) {
        self.isEnabled = environment["MEETING_AGENT_DEEPGRAM_RAW_RESPONSE_LOG"] == "1"
        self.errorOutput = errorOutput
    }

    public func logRawResponse(_ data: Data, context: DeepgramRawResponseContext) {
        guard isEnabled else { return }
        let text = String(data: data, encoding: .utf8) ?? data.base64EncodedString()
        let message = """
        [MeetingAgent] Deepgram raw \(context.transport.rawValue) response (\(data.count) bytes, provider: \(context.providerID)):
        \(text)

        """
        if let output = message.data(using: .utf8) {
            try? errorOutput.write(contentsOf: output)
        }
    }
}

public protocol DeepgramTranscriptionClient {
    func transcribe(
        configuration: DeepgramTranscriptionConfiguration,
        wavURL: URL
    ) async throws -> Data
}

public protocol DeepgramStreamingTranscriptionClient {
    func connect(
        configuration: DeepgramTranscriptionConfiguration,
        sampleRate: Double,
        channelCount: Int,
        performanceEventLogger: PerformanceEventLogger?
    ) async throws -> DeepgramStreamingTranscriptionSession
}

public protocol DeepgramStreamingTranscriptionSession: AnyObject {
    var segments: AsyncStream<TranscriptSegment> { get }
    var speechEvents: AsyncStream<SpeechRecognitionEvent> { get }
    func send(_ frame: AudioFrame) async throws
    func close() async
}

public extension DeepgramStreamingTranscriptionSession {
    var speechEvents: AsyncStream<SpeechRecognitionEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}

public final class URLSessionDeepgramTranscriptionClient: DeepgramTranscriptionClient {
    private let endpointURL: URL
    private let session: URLSession

    public init(
        endpointURL: URL = URL(string: "https://api.deepgram.com/v1/listen")!,
        session: URLSession = .shared
    ) {
        self.endpointURL = endpointURL
        self.session = session
    }

    public func transcribe(
        configuration: DeepgramTranscriptionConfiguration,
        wavURL: URL
    ) async throws -> Data {
        guard case .available(let apiKey, let model, let language) = configuration else {
            throw DeepgramTranscriptionError.unavailable("Deepgram configuration is unavailable")
        }
        var components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "diarize", value: "true"),
            URLQueryItem(name: "utterances", value: "true")
        ]
        guard let requestURL = components?.url else {
            throw DeepgramTranscriptionError.invalidRequest
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Data(contentsOf: wavURL)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DeepgramTranscriptionError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw DeepgramTranscriptionError.httpStatus(httpResponse.statusCode, String(data: data, encoding: .utf8))
        }
        return data
    }
}

public final class URLSessionDeepgramStreamingTranscriptionClient: DeepgramStreamingTranscriptionClient {
    private let webSocketFactory: (URLRequest) -> DeepgramWebSocketTask
    private let rawResponseLogger: DeepgramRawResponseLogger

    public convenience init() {
        self.init(
            rawResponseLogger: DeepgramEnvironmentRawResponseLogger(),
            webSocketFactory: { request in
                URLSession.shared.webSocketTask(with: request)
            }
        )
    }

    init(
        rawResponseLogger: DeepgramRawResponseLogger = DeepgramEnvironmentRawResponseLogger(),
        webSocketFactory: @escaping (URLRequest) -> DeepgramWebSocketTask
    ) {
        self.rawResponseLogger = rawResponseLogger
        self.webSocketFactory = webSocketFactory
    }

    public func connect(
        configuration: DeepgramTranscriptionConfiguration,
        sampleRate: Double,
        channelCount: Int,
        performanceEventLogger: PerformanceEventLogger? = nil
    ) async throws -> DeepgramStreamingTranscriptionSession {
        guard case .available(let apiKey, let model, let language) = configuration else {
            throw DeepgramTranscriptionError.unavailable("Deepgram configuration is unavailable")
        }
        guard var components = URLComponents(string: "wss://api.deepgram.com/v1/listen") else {
            throw DeepgramTranscriptionError.invalidRequest
        }
        components.queryItems = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: String(Int(sampleRate.rounded()))),
            URLQueryItem(name: "channels", value: String(max(1, channelCount))),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "diarize", value: "true"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "endpointing", value: "500")
        ]
        guard let url = components.url else {
            throw DeepgramTranscriptionError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        let task = webSocketFactory(request)
        let session = URLSessionDeepgramStreamingSession(
            task: task,
            rawResponseLogger: rawResponseLogger,
            performanceEventLogger: performanceEventLogger
        )
        task.resume()
        performanceEventLogger?.log(
            "deepgram_ws_connected",
            metadata: [
                "providerID": "deepgram-transcribe",
                "model": model,
                "language": language,
                "sampleRate": Self.metricString(sampleRate.rounded()),
                "channelCount": String(max(1, channelCount)),
                "encoding": "linear16",
                "interimResults": "true",
                "endpointingMilliseconds": "500",
                "smartFormat": "true",
                "punctuate": "true",
                "diarize": "true"
            ]
        )
        return session
    }

    private static func metricString(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(value)
    }
}

protocol DeepgramWebSocketTask: AnyObject {
    func resume()
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive(completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void)
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

extension URLSessionWebSocketTask: DeepgramWebSocketTask {}

final class URLSessionDeepgramStreamingSession: DeepgramStreamingTranscriptionSession {
    private let task: DeepgramWebSocketTask
    private let rawResponseLogger: DeepgramRawResponseLogger
    private let performanceEventLogger: PerformanceEventLogger?
    private var continuation: AsyncStream<TranscriptSegment>.Continuation?
    private var eventContinuation: AsyncStream<SpeechRecognitionEvent>.Continuation?
    private var didStartReceiving = false

    init(
        task: DeepgramWebSocketTask,
        rawResponseLogger: DeepgramRawResponseLogger = DeepgramEnvironmentRawResponseLogger(),
        performanceEventLogger: PerformanceEventLogger? = nil
    ) {
        self.task = task
        self.rawResponseLogger = rawResponseLogger
        self.performanceEventLogger = performanceEventLogger
    }

    var segments: AsyncStream<TranscriptSegment> {
        AsyncStream { continuation in
            self.continuation = continuation
            self.startReceivingIfNeeded()
        }
    }

    var speechEvents: AsyncStream<SpeechRecognitionEvent> {
        AsyncStream { continuation in
            self.eventContinuation = continuation
            self.startReceivingIfNeeded()
        }
    }

    func send(_ frame: AudioFrame) async throws {
        try await task.send(.data(frame.pcm))
    }

    func close() async {
        let finalize = #"{"type":"Finalize"}"#
        try? await task.send(.string(finalize))
        task.cancel(with: .normalClosure, reason: nil)
        continuation?.finish()
        eventContinuation?.finish()
    }

    private func startReceivingIfNeeded() {
        guard !didStartReceiving else { return }
        didStartReceiving = true
        receiveNext()
    }

    private func receiveNext() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.data(let data)):
                self.yieldSegments(from: data)
                self.receiveNext()
            case .success(.string(let text)):
                self.yieldSegments(from: Data(text.utf8))
                self.receiveNext()
            case .failure:
                self.continuation?.finish()
                self.eventContinuation?.finish()
            @unknown default:
                self.continuation?.finish()
                self.eventContinuation?.finish()
            }
        }
    }

    private func yieldSegments(from data: Data) {
        rawResponseLogger.logRawResponse(
            data,
            context: DeepgramRawResponseContext(providerID: "deepgram-transcribe", transport: .webSocket)
        )
        performanceEventLogger?.logDeepgramRawResponse(
            data,
            context: DeepgramRawResponseContext(providerID: "deepgram-transcribe", transport: .webSocket)
        )
        for segment in DeepgramStreamingResponseMapper.segments(
            from: data,
            providerID: "deepgram-transcribe"
        ) {
            continuation?.yield(segment)
        }
        for event in DeepgramSpeechEventAdapter.events(
            from: data,
            providerID: "deepgram-transcribe"
        ) {
            eventContinuation?.yield(event)
        }
    }
}

public enum DeepgramStreamingResponseMapper {
    public static func segments(
        from data: Data,
        providerID: String
    ) -> [TranscriptSegment] {
        guard let response = try? JSONDecoder.meetingAgent.decode(DeepgramStreamingResponse.self, from: data),
              let isFinal = response.isFinal,
              let alternative = response.channel?.alternatives.first
        else {
            return []
        }
        let words = alternative.words ?? []
        let runs = speakerRuns(from: words)
        if runs.isEmpty {
            let text = alternative.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            return [
                TranscriptSegment(
                    id: activeSegmentID(providerID: providerID, words: words),
                    text: text,
                    language: response.metadata?.detectedLanguage,
                    sourceProvider: providerID,
                    isFinal: isFinal,
                    speechFinal: response.speechFinal == true,
                    confidence: alternative.confidence
                )
            ]
        }
        let mapped = runs.compactMap { run -> TranscriptSegment? in
            let text = run.words
                .map { $0.displayText }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let firstWord = run.words.first
            let lastWord = run.words.last
            return TranscriptSegment(
                id: activeSegmentID(providerID: providerID, words: run.words),
                speaker: speaker(for: run.speaker),
                startTimeSeconds: firstWord?.start,
                endTimeSeconds: lastWord?.end,
                text: text,
                language: response.metadata?.detectedLanguage,
                sourceProvider: providerID,
                isFinal: isFinal,
                confidence: alternative.confidence,
                timingSource: firstWord?.start == nil && lastWord?.end == nil ? .unavailable : .precise
            )
        }
        guard response.speechFinal == true, !mapped.isEmpty else {
            return mapped
        }
        return mapped.enumerated().map { index, segment in
            TranscriptSegment(
                id: segment.id,
                speaker: segment.speaker,
                startTimeSeconds: segment.startTimeSeconds,
                endTimeSeconds: segment.endTimeSeconds,
                text: segment.text,
                language: segment.language,
                sourceProvider: segment.sourceProvider,
                isFinal: segment.isFinal,
                speechFinal: index == mapped.count - 1,
                confidence: segment.confidence,
                createdAt: segment.createdAt,
                timingSource: segment.timingSource
            )
        }
    }

    private static func activeSegmentID(providerID: String, words: [DeepgramStreamingResponse.Word]) -> String {
        guard let firstWord = words.first,
              let start = firstWord.start
        else {
            return "\(providerID)-stream-active"
        }
        return "\(providerID)-stream-\(start)"
    }

    private static func speakerRuns(from words: [DeepgramStreamingResponse.Word]) -> [SpeakerRun] {
        var runs: [SpeakerRun] = []
        for word in words where !word.displayText.isEmpty {
            if let lastIndex = runs.indices.last, runs[lastIndex].speaker == word.speaker {
                runs[lastIndex].words.append(word)
            } else {
                runs.append(SpeakerRun(speaker: word.speaker, words: [word]))
            }
        }
        return runs
    }

    private static func speaker(for deepgramSpeaker: Int?) -> TranscriptSpeaker {
        guard let deepgramSpeaker else { return .default }
        return TranscriptSpeaker(identifier: "deepgram-speaker-\(deepgramSpeaker)")
    }

    private struct SpeakerRun {
        let speaker: Int?
        var words: [DeepgramStreamingResponse.Word]
    }
}

public struct DeepgramStreamingSpeechTranscriptionProvider {
    private let configuration: DeepgramTranscriptionConfiguration
    private let client: DeepgramStreamingTranscriptionClient

    public init(
        configuration: DeepgramTranscriptionConfiguration,
        client: DeepgramStreamingTranscriptionClient = URLSessionDeepgramStreamingTranscriptionClient()
    ) {
        self.configuration = configuration
        self.client = client
    }

    public init(
        appConfiguration: SpeechTranscriptionConfiguration,
        client: DeepgramStreamingTranscriptionClient = URLSessionDeepgramStreamingTranscriptionClient()
    ) {
        self.configuration = .app(appConfiguration)
        self.client = client
    }

    public func start(context: SpeechTranscriptionStreamContext) async throws -> AudioFrameTranscriber {
        guard case .available = configuration else {
            throw DeepgramTranscriptionError.unavailable("Deepgram configuration is unavailable")
        }
        let session = try await client.connect(
            configuration: configuration,
            sampleRate: context.sampleRate,
            channelCount: context.channelCount,
            performanceEventLogger: context.performanceEventLogger
        )
        let writer = context.speechEventSink == nil ? try TranscriptFileWriter(url: context.transcriptURL) : nil
        return DeepgramStreamingTranscriber(
            session: session,
            writer: writer,
            transcriptUpdateSink: context.transcriptUpdateSink,
            speechEventSink: context.speechEventSink,
            performanceEventLogger: context.performanceEventLogger
        )
    }
}

final class DeepgramStreamingTranscriber: AudioFrameTranscriber {
    private let session: DeepgramStreamingTranscriptionSession
    private let writer: TranscriptFileWriter?
    private let transcriptUpdateSink: TranscriptUpdateSink?
    private let speechEventSink: SpeechRecognitionEventSink?
    private let performanceEventLogger: PerformanceEventLogger?
    private let sendQueue: DeepgramFrameSendQueue
    private let failureLock = NSLock()
    private var receiveTask: Task<Void, Never>?
    private var eventReceiveTask: Task<Void, Never>?
    private var sendFailure: String?
    private var fallbackSegmentIndex = 0
    private var reconciler = DeepgramTranscriptReconciler()

    var failureReason: String? {
        failureLock.lock()
        defer { failureLock.unlock() }
        return sendFailure
    }

    init(
        session: DeepgramStreamingTranscriptionSession,
        writer: TranscriptFileWriter?,
        transcriptUpdateSink: TranscriptUpdateSink? = nil,
        speechEventSink: SpeechRecognitionEventSink? = nil,
        performanceEventLogger: PerformanceEventLogger? = nil
    ) {
        self.session = session
        self.writer = writer
        self.transcriptUpdateSink = transcriptUpdateSink
        self.speechEventSink = speechEventSink
        self.performanceEventLogger = performanceEventLogger
        self.sendQueue = DeepgramFrameSendQueue(
            session: session,
            performanceEventLogger: performanceEventLogger
        )
        self.sendQueue.onFailure = { [weak self] error in
            self?.recordSendFailure(error)
        }
        self.receiveTask = Task { [weak self, session] in
            for await segment in session.segments {
                self?.performanceEventLogger?.logSegment(
                    "stt_segment_received",
                    segment: segment,
                    metadata: ["sourceProvider": segment.sourceProvider]
                )
                guard self?.speechEventSink == nil else { continue }
                try? self?.write(segment)
            }
            if self?.speechEventSink == nil {
                try? self?.writer?.close()
            }
        }
        self.eventReceiveTask = Task { [weak self, session] in
            for await event in session.speechEvents {
                self?.speechEventSink?.receive(event)
            }
        }
    }

    func append(_ frame: AudioFrame) throws {
        sendQueue.append(frame)
    }

    func finish() {
        Task { [sendQueue, session] in
            await sendQueue.finish()
            await session.close()
        }
    }

    private func write(_ segment: TranscriptSegment) throws {
        let segment = stableFallbackSegment(segment)
        guard let writer else { return }
        let output = reconciler.apply(segment)

        for result in output.realtimeUpdates {
            let realtimeSegments = TranscriptFileWriter.assignSpeakerLabels(to: result.document.segments)
            for realtimeSegment in realtimeSegments where result.changedSegmentIDs.contains(realtimeSegment.id) {
                transcriptUpdateSink?.receiveRealtime(.upsert(realtimeSegment))
                performanceEventLogger?.logSegment("transcript_segment_written", segment: realtimeSegment)
            }
        }

        guard !output.finalUpdates.isEmpty else { return }
        let finalSegments = TranscriptFileWriter.assignSpeakerLabels(to: output.finalDocument.segments)
        try writer.replace(with: finalSegments)
        for result in output.finalUpdates {
            for finalSegment in finalSegments where result.changedSegmentIDs.contains(finalSegment.id) {
                transcriptUpdateSink?.receiveFinal(.upsert(finalSegment))
                performanceEventLogger?.logSegment("transcript_segment_written", segment: finalSegment)
                advanceFallbackSegmentIndexIfNeeded(for: finalSegment)
            }
        }
    }

    private func stableFallbackSegment(_ segment: TranscriptSegment) -> TranscriptSegment {
        let fallbackID = "\(segment.sourceProvider)-stream-active"
        guard segment.id == fallbackID else { return segment }
        let stableID = "\(fallbackID)-\(fallbackSegmentIndex)"
        return TranscriptSegment(
            id: stableID,
            speaker: segment.speaker,
            startTimeSeconds: segment.startTimeSeconds,
            endTimeSeconds: segment.endTimeSeconds,
            text: segment.text,
            language: segment.language,
            sourceProvider: segment.sourceProvider,
            isFinal: segment.isFinal,
            speechFinal: segment.speechFinal,
            confidence: segment.confidence,
            createdAt: segment.createdAt,
            timingSource: segment.timingSource
        )
    }

    private func advanceFallbackSegmentIndexIfNeeded(for segment: TranscriptSegment) {
        let fallbackID = "\(segment.sourceProvider)-stream-active-\(fallbackSegmentIndex)"
        guard segment.id == fallbackID else { return }
        fallbackSegmentIndex += 1
    }

    private func recordSendFailure(_ error: Error) {
        failureLock.lock()
        sendFailure = "Deepgram streaming transcription failed: \(error)"
        failureLock.unlock()
    }
}

private final class DeepgramFrameSendQueue {
    private let session: DeepgramStreamingTranscriptionSession
    private let performanceEventLogger: PerformanceEventLogger?
    private let lock = NSLock()
    private var frames: [AudioFrame] = []
    private var isSending = false
    private var isFinishing = false
    private var sentAudioSeconds: Double = 0
    var onFailure: ((Error) -> Void)?

    init(
        session: DeepgramStreamingTranscriptionSession,
        performanceEventLogger: PerformanceEventLogger? = nil
    ) {
        self.session = session
        self.performanceEventLogger = performanceEventLogger
    }

    func append(_ frame: AudioFrame) {
        var shouldStartSending = false
        lock.lock()
        if !isFinishing {
            frames.append(frame)
            if !isSending {
                isSending = true
                shouldStartSending = true
            }
        }
        lock.unlock()

        if shouldStartSending {
            Task { await drain() }
        }
    }

    func finish() async {
        markFinishing()

        while true {
            if isDrained { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func markFinishing() {
        lock.lock()
        isFinishing = true
        lock.unlock()
    }

    private var isDrained: Bool {
        lock.lock()
        defer { lock.unlock() }
        return frames.isEmpty && !isSending
    }

    private func drain() async {
        while let frame = nextFrame() {
            do {
                try await session.send(frame)
                logFrameSent(frame)
            } catch {
                onFailure?(error)
                clearAfterFailure()
                return
            }
        }
    }

    private func nextFrame() -> AudioFrame? {
        lock.lock()
        defer { lock.unlock() }
        guard !frames.isEmpty else {
            isSending = false
            return nil
        }
        return frames.removeFirst()
    }

    private func clearAfterFailure() {
        lock.lock()
        frames.removeAll()
        isSending = false
        isFinishing = true
        lock.unlock()
    }

    private func logFrameSent(_ frame: AudioFrame) {
        let durationSeconds = frameDurationSeconds(frame)
        lock.lock()
        sentAudioSeconds += durationSeconds
        let audioTimeSeconds = sentAudioSeconds
        let queuedFrameCount = frames.count
        lock.unlock()
        performanceEventLogger?.log(
            "deepgram_audio_frame_sent",
            audioTimeSeconds: audioTimeSeconds,
            metadata: [
                "pcmBytes": String(frame.pcm.count),
                "sampleRate": Self.metricString(frame.sampleRate),
                "channelCount": String(frame.channelCount),
                "timestampNanos": String(frame.timestampNanos),
                "frameDurationSeconds": String(durationSeconds),
                "queuedFrameCount": String(queuedFrameCount)
            ]
        )
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

public struct DeepgramAudioTranscriptionProvider: AudioTranscriptionProvider {
    public let descriptor = ProviderDescriptor(
        id: "deepgram-transcribe",
        displayName: "Deepgram Transcribe",
        capability: .audioTranscription,
        executionMode: .hosted,
        supportedSourceLocales: ["*"],
        supportedTargetLocales: [],
        requiresNetwork: true,
        requiresAPIKey: true
    )

    private let configuration: DeepgramTranscriptionConfiguration
    private let client: DeepgramTranscriptionClient
    private let rawResponseLogger: DeepgramRawResponseLogger

    public init(
        configuration: DeepgramTranscriptionConfiguration,
        client: DeepgramTranscriptionClient = URLSessionDeepgramTranscriptionClient(),
        rawResponseLogger: DeepgramRawResponseLogger = DeepgramEnvironmentRawResponseLogger()
    ) {
        self.configuration = configuration
        self.client = client
        self.rawResponseLogger = rawResponseLogger
    }

    public init(
        appConfiguration: SpeechTranscriptionConfiguration = .default,
        client: DeepgramTranscriptionClient = URLSessionDeepgramTranscriptionClient(),
        rawResponseLogger: DeepgramRawResponseLogger = DeepgramEnvironmentRawResponseLogger()
    ) {
        self.configuration = .app(appConfiguration)
        self.client = client
        self.rawResponseLogger = rawResponseLogger
    }

    public func transcribe(audio: AudioInput, options: TranscriptionOptions) async throws -> TranscriptDocument {
        guard let wavURL = audio.wavURL else {
            throw DeepgramTranscriptionError.unavailable("Deepgram transcription requires a WAV file URL")
        }
        guard case .available = configuration else {
            throw DeepgramTranscriptionError.unavailable("Deepgram configuration is unavailable")
        }
        let data = try await client.transcribe(
            configuration: configuration,
            wavURL: wavURL
        )
        rawResponseLogger.logRawResponse(
            data,
            context: DeepgramRawResponseContext(providerID: descriptor.id, transport: .http)
        )
        let response = try JSONDecoder.meetingAgent.decode(DeepgramResponse.self, from: data)
        return TranscriptDocument(segments: Self.segments(from: response, providerID: descriptor.id))
    }

    private static func segments(
        from response: DeepgramResponse,
        providerID: String
    ) -> [TranscriptSegment] {
        let utteranceSegments = response.results?.utterances?.compactMap { utterance -> TranscriptSegment? in
            let text = utterance.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let speaker = Self.speaker(for: utterance.speaker)
            return TranscriptSegment(
                id: SpeechTranscriptionConfiguration.normalized(utterance.id) ?? UUID().uuidString,
                speaker: speaker,
                startTimeSeconds: utterance.start,
                endTimeSeconds: utterance.end,
                text: text,
                language: response.metadata?.detectedLanguage,
                sourceProvider: providerID,
                confidence: utterance.confidence,
                timingSource: utterance.start == nil && utterance.end == nil ? .unavailable : .precise
            )
        } ?? []
        if !utteranceSegments.isEmpty {
            return utteranceSegments
        }

        let alternatives = response.results?.channels?.flatMap(\.alternatives) ?? []
        return alternatives.compactMap { alternative in
            let text = alternative.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TranscriptSegment(
                text: text,
                language: response.metadata?.detectedLanguage,
                sourceProvider: providerID,
                confidence: alternative.confidence
            )
        }
    }

    private static func speaker(for deepgramSpeaker: Int?) -> TranscriptSpeaker {
        guard let deepgramSpeaker else { return .default }
        return TranscriptSpeaker(identifier: "deepgram-speaker-\(deepgramSpeaker)")
    }
}

public enum DeepgramTranscriptionError: Error, CustomStringConvertible {
    case unavailable(String)
    case invalidRequest
    case invalidResponse
    case httpStatus(Int, String?)

    public var description: String {
        switch self {
        case .unavailable(let reason):
            return reason
        case .invalidRequest:
            return "invalid Deepgram request"
        case .invalidResponse:
            return "invalid HTTP response"
        case .httpStatus(let statusCode, let body):
            let detail = body?.trimmingCharacters(in: .whitespacesAndNewlines)
            return "HTTP \(statusCode)\(detail.map { ": \($0)" } ?? "")"
        }
    }
}

private struct DeepgramResponse: Decodable {
    let metadata: Metadata?
    let results: Results?

    struct Metadata: Decodable {
        let detectedLanguage: String?

        enum CodingKeys: String, CodingKey {
            case detectedLanguage = "detected_language"
        }
    }

    struct Results: Decodable {
        let channels: [Channel]?
        let utterances: [Utterance]?
    }

    struct Channel: Decodable {
        let alternatives: [Alternative]
    }

    struct Alternative: Decodable {
        let transcript: String
        let confidence: Double?
    }

    struct Utterance: Decodable {
        let id: String?
        let start: Double?
        let end: Double?
        let confidence: Double?
        let transcript: String
        let speaker: Int?
    }
}

public struct DeepgramStreamingResponse: Decodable {
    let type: String?
    let start: Double?
    let duration: Double?
    let isFinal: Bool?
    let speechFinal: Bool?
    let metadata: Metadata?
    let channel: Channel?

    enum CodingKeys: String, CodingKey {
        case type
        case start
        case duration
        case isFinal = "is_final"
        case speechFinal = "speech_final"
        case metadata
        case channel
    }

    struct Metadata: Decodable {
        let detectedLanguage: String?
        let requestID: String?

        enum CodingKeys: String, CodingKey {
            case detectedLanguage = "detected_language"
            case requestID = "request_id"
        }
    }

    struct Channel: Decodable {
        let alternatives: [Alternative]
    }

    struct Alternative: Decodable {
        let transcript: String
        let confidence: Double?
        let words: [Word]?
    }

    struct Word: Decodable {
        let word: String?
        let punctuatedWord: String?
        let start: Double?
        let end: Double?
        let speaker: Int?

        enum CodingKeys: String, CodingKey {
            case word
            case punctuatedWord = "punctuated_word"
            case start
            case end
            case speaker
        }

        var displayText: String {
            (punctuatedWord ?? word ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
