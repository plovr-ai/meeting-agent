import Foundation

public enum DeepgramTranscriptionConfiguration: Equatable {
    case available(apiKey: String, model: String)
    case unavailable(String)

    public var apiKey: String {
        if case .available(let apiKey, _) = self { return apiKey }
        return ""
    }

    public var model: String {
        if case .available(_, let model) = self { return model }
        return ""
    }

    public init(apiKey: String?, model: String?) {
        guard let apiKey = SpeechTranscriptionConfiguration.normalized(apiKey) else {
            self = .unavailable("Deepgram API key is not configured")
            return
        }
        guard let model = SpeechTranscriptionConfiguration.normalized(model) else {
            self = .unavailable("Deepgram model is not configured")
            return
        }
        self = .available(apiKey: apiKey, model: model)
    }

    public static func app(
        _ configuration: SpeechTranscriptionConfiguration,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Self {
        DeepgramTranscriptionConfiguration(
            apiKey: configuration.deepgramAPIKey ?? environment["MEETING_AGENT_DEEPGRAM_API_KEY"],
            model: configuration.deepgramModelID
        )
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
        channelCount: Int
    ) async throws -> DeepgramStreamingTranscriptionSession
}

public protocol DeepgramStreamingTranscriptionSession: AnyObject {
    var segments: AsyncStream<TranscriptSegment> { get }
    func send(_ frame: AudioFrame) async throws
    func close() async
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
        guard case .available(let apiKey, let model) = configuration else {
            throw DeepgramTranscriptionError.unavailable("Deepgram configuration is unavailable")
        }
        var components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "model", value: model),
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

    public convenience init() {
        self.init(webSocketFactory: { request in
            URLSession.shared.webSocketTask(with: request)
        })
    }

    init(webSocketFactory: @escaping (URLRequest) -> DeepgramWebSocketTask) {
        self.webSocketFactory = webSocketFactory
    }
    public func connect(
        configuration: DeepgramTranscriptionConfiguration,
        sampleRate: Double,
        channelCount: Int
    ) async throws -> DeepgramStreamingTranscriptionSession {
        guard case .available(let apiKey, let model) = configuration else {
            throw DeepgramTranscriptionError.unavailable("Deepgram configuration is unavailable")
        }
        guard var components = URLComponents(string: "wss://api.deepgram.com/v1/listen") else {
            throw DeepgramTranscriptionError.invalidRequest
        }
        components.queryItems = [
            URLQueryItem(name: "model", value: model),
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
        let session = URLSessionDeepgramStreamingSession(task: task)
        task.resume()
        return session
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
    private var continuation: AsyncStream<TranscriptSegment>.Continuation?

    init(task: DeepgramWebSocketTask) {
        self.task = task
    }

    var segments: AsyncStream<TranscriptSegment> {
        AsyncStream { continuation in
            self.continuation = continuation
            self.receiveNext()
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
            @unknown default:
                self.continuation?.finish()
            }
        }
    }

    private func yieldSegments(from data: Data) {
        for segment in DeepgramStreamingResponseMapper.segments(
            from: data,
            providerID: "deepgram-transcribe"
        ) {
            continuation?.yield(segment)
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
            channelCount: context.channelCount
        )
        let writer = try TranscriptFileWriter(url: context.transcriptURL)
        return DeepgramStreamingTranscriber(session: session, writer: writer)
    }
}

final class DeepgramStreamingTranscriber: AudioFrameTranscriber {
    private let session: DeepgramStreamingTranscriptionSession
    private let writer: TranscriptFileWriter
    private var receiveTask: Task<Void, Never>?
    private var sendFailure: String?
    private var fallbackSegmentIndex = 0

    var failureReason: String? {
        sendFailure
    }

    init(session: DeepgramStreamingTranscriptionSession, writer: TranscriptFileWriter) {
        self.session = session
        self.writer = writer
        self.receiveTask = Task { [weak self, session] in
            for await segment in session.segments {
                try? self?.write(segment)
            }
        }
    }

    func append(_ frame: AudioFrame) throws {
        Task { [session] in
            do {
                try await session.send(frame)
            } catch {
                self.sendFailure = "Deepgram streaming transcription failed: \(error)"
            }
        }
    }

    func finish() {
        receiveTask?.cancel()
        Task { [session, writer] in
            await session.close()
            try? writer.close()
        }
    }

    private func write(_ segment: TranscriptSegment) throws {
        let segment = stableFallbackSegment(segment)
        try writer.upsert(segment)
        if segment.isFinal, segment.id.hasSuffix("-stream-active-\(fallbackSegmentIndex)") {
            fallbackSegmentIndex += 1
        }
    }

    private func stableFallbackSegment(_ segment: TranscriptSegment) -> TranscriptSegment {
        let fallbackID = "\(segment.sourceProvider)-stream-active"
        guard segment.id == fallbackID else { return segment }
        return TranscriptSegment(
            id: "\(fallbackID)-\(fallbackSegmentIndex)",
            speaker: segment.speaker,
            startTimeSeconds: segment.startTimeSeconds,
            endTimeSeconds: segment.endTimeSeconds,
            text: segment.text,
            language: segment.language,
            sourceProvider: segment.sourceProvider,
            isFinal: segment.isFinal,
            confidence: segment.confidence,
            createdAt: segment.createdAt,
            timingSource: segment.timingSource
        )
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

    public init(
        configuration: DeepgramTranscriptionConfiguration,
        client: DeepgramTranscriptionClient = URLSessionDeepgramTranscriptionClient()
    ) {
        self.configuration = configuration
        self.client = client
    }

    public init(
        appConfiguration: SpeechTranscriptionConfiguration = .default,
        client: DeepgramTranscriptionClient = URLSessionDeepgramTranscriptionClient()
    ) {
        self.configuration = .app(appConfiguration)
        self.client = client
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
    let isFinal: Bool?
    let speechFinal: Bool?
    let metadata: Metadata?
    let channel: Channel?

    enum CodingKeys: String, CodingKey {
        case isFinal = "is_final"
        case speechFinal = "speech_final"
        case metadata
        case channel
    }

    struct Metadata: Decodable {
        let detectedLanguage: String?

        enum CodingKeys: String, CodingKey {
            case detectedLanguage = "detected_language"
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
