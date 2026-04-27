import Foundation

enum OpenAIRealtimeProviderError: Error, CustomStringConvertible, Equatable {
    case missingAPIKey
    case invalidEvent
    case invalidBase64Audio
    case transportClosed

    var description: String {
        switch self {
        case .missingAPIKey:
            return "MEETING_AGENT_OPENAI_API_KEY is not configured"
        case .invalidEvent:
            return "OpenAI Realtime event could not be decoded"
        case .invalidBase64Audio:
            return "OpenAI Realtime audio delta was not valid base64"
        case .transportClosed:
            return "OpenAI Realtime WebSocket transport is closed"
        }
    }
}

enum OpenAIRealtimeEventDecoder {
    static func decode(_ data: Data) throws -> RealtimeTranslationEvent? {
        let envelope = try JSONDecoder().decode(EventEnvelope.self, from: data)
        switch envelope.type {
        case "session.created", "session.updated":
            return .connected
        case "response.output_audio.delta":
            guard let delta = envelope.delta,
                  let audioData = Data(base64Encoded: delta)
            else { throw OpenAIRealtimeProviderError.invalidBase64Audio }
            return .targetAudioDelta(audioData)
        case "response.output_audio_transcript.delta":
            return .targetTextDelta(envelope.delta ?? "")
        case "response.output_audio_transcript.done":
            return .targetTextFinal(envelope.transcript ?? "")
        case "rate_limits.updated":
            return .rateLimitsUpdated
        case "error":
            return .failed(envelope.error?.message ?? "OpenAI Realtime error")
        case "response.done", "response.output_audio.done":
            return nil
        default:
            return nil
        }
    }

    private struct EventEnvelope: Decodable {
        var type: String
        var delta: String?
        var transcript: String?
        var error: ErrorEnvelope?
    }

    private struct ErrorEnvelope: Decodable {
        var message: String
    }
}

enum OpenAIRealtimeMessageFactory {
    static func sessionUpdate(configuration: RealtimeTranslationConfiguration) throws -> Data {
        let instructions = """
        You are a real-time meeting interpreter.
        Translate all incoming speech into \(configuration.targetLocale).
        Output only the translation.
        Preserve meaning, tone, intent, names, numbers, dates, and business context.
        Do not answer the speaker or add commentary.
        """
        let event = SessionUpdateEvent(
            session: Session(
                model: configuration.model,
                instructions: instructions,
                audio: Audio(
                    input: AudioInputConfig(turnDetection: TurnDetection(type: "server_vad")),
                    output: AudioOutputConfig(
                        voice: configuration.voice,
                        format: AudioFormat(type: "audio/pcm", rate: 24_000)
                    )
                )
            )
        )
        return try JSONEncoder().encode(event)
    }

    static func appendAudio(_ pcm16: Data) throws -> Data {
        try JSONEncoder().encode(AppendAudioEvent(audio: pcm16.base64EncodedString()))
    }

    private struct SessionUpdateEvent: Encodable {
        var type = "session.update"
        var session: Session
    }

    private struct Session: Encodable {
        var type = "realtime"
        var model: String
        var instructions: String
        var audio: Audio
    }

    private struct Audio: Encodable {
        var input: AudioInputConfig
        var output: AudioOutputConfig
    }

    private struct AudioInputConfig: Encodable {
        enum CodingKeys: String, CodingKey {
            case turnDetection = "turn_detection"
        }

        var turnDetection: TurnDetection
    }

    private struct TurnDetection: Encodable {
        var type: String
    }

    private struct AudioOutputConfig: Encodable {
        var voice: String
        var format: AudioFormat
    }

    private struct AudioFormat: Encodable {
        var type: String
        var rate: Int
    }

    private struct AppendAudioEvent: Encodable {
        var type = "input_audio_buffer.append"
        var audio: String
    }
}

protocol RealtimeWebSocketTransport: AnyObject {
    var incomingMessages: AsyncStream<Data> { get }
    func connect() async throws
    func send(_ data: Data) async throws
    func close() async
}

final class URLSessionRealtimeWebSocketTransport: NSObject, RealtimeWebSocketTransport, URLSessionWebSocketDelegate {
    private let url: URL
    private let apiKey: String
    private var task: URLSessionWebSocketTask?
    private var continuation: AsyncStream<Data>.Continuation?

    init(url: URL, apiKey: String) {
        self.url = url
        self.apiKey = apiKey
    }

    var incomingMessages: AsyncStream<Data> {
        AsyncStream { continuation in
            self.continuation = continuation
            self.receiveNext()
        }
    }

    func connect() async throws {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
    }

    func send(_ data: Data) async throws {
        guard let task else { throw OpenAIRealtimeProviderError.transportClosed }
        let text = String(decoding: data, as: UTF8.self)
        try await task.send(.string(text))
    }

    func close() async {
        task?.cancel(with: .goingAway, reason: nil)
        continuation?.finish()
        task = nil
    }

    private func receiveNext() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.data(let data)):
                self.continuation?.yield(data)
                self.receiveNext()
            case .success(.string(let text)):
                self.continuation?.yield(Data(text.utf8))
                self.receiveNext()
            case .failure:
                self.continuation?.finish()
            @unknown default:
                self.continuation?.finish()
            }
        }
    }
}

public final class OpenAIRealtimeSpeechTranslationProvider: RealtimeSpeechTranslationProvider {
    public let descriptor = ProviderDescriptor(
        id: "openai-gpt-realtime",
        displayName: "OpenAI GPT Realtime",
        capability: .speechTranslation,
        executionMode: .hosted,
        supportedSourceLocales: ["*"],
        supportedTargetLocales: ["*"],
        requiresNetwork: true,
        requiresAPIKey: true
    )

    private let transportFactory: (URL, String) -> RealtimeWebSocketTransport

    init(transportFactory: @escaping (URL, String) -> RealtimeWebSocketTransport) {
        self.transportFactory = transportFactory
    }

    public convenience init() {
        self.init { url, apiKey in
            URLSessionRealtimeWebSocketTransport(url: url, apiKey: apiKey)
        }
    }

    public func start(configuration: RealtimeTranslationConfiguration) async throws -> RealtimeTranslationSession {
        if let error = configuration.validationError {
            throw ProbeError.invalidArguments(error)
        }
        guard let apiKey = configuration.apiKey else {
            throw OpenAIRealtimeProviderError.missingAPIKey
        }
        guard let url = URL(string: "wss://api.openai.com/v1/realtime?model=\(configuration.model)") else {
            throw ProbeError.invalidArguments("Invalid OpenAI Realtime URL")
        }
        let transport = transportFactory(url, apiKey)
        try await transport.connect()
        try await transport.send(try OpenAIRealtimeMessageFactory.sessionUpdate(configuration: configuration))
        return OpenAIRealtimeTranslationSession(transport: transport)
    }
}

final class OpenAIRealtimeTranslationSession: RealtimeTranslationSession {
    private let transport: RealtimeWebSocketTransport
    private let continuation: AsyncStream<RealtimeTranslationEvent>.Continuation
    let events: AsyncStream<RealtimeTranslationEvent>
    private var receiveTask: Task<Void, Never>?

    init(transport: RealtimeWebSocketTransport) {
        self.transport = transport
        var streamContinuation: AsyncStream<RealtimeTranslationEvent>.Continuation!
        self.events = AsyncStream { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation
        self.receiveTask = Task { [transport, continuation] in
            for await data in transport.incomingMessages {
                do {
                    if let event = try OpenAIRealtimeEventDecoder.decode(data) {
                        continuation.yield(event)
                    }
                } catch {
                    continuation.yield(.failed(String(describing: error)))
                }
            }
            continuation.yield(.stopped)
            continuation.finish()
        }
    }

    func append(_ frames: [AudioFrame]) async throws {
        guard !frames.isEmpty else { return }
        for frame in frames {
            try await transport.send(try OpenAIRealtimeMessageFactory.appendAudio(frame.pcm))
        }
    }

    func stop() async {
        receiveTask?.cancel()
        await transport.close()
        continuation.yield(.stopped)
        continuation.finish()
    }
}
