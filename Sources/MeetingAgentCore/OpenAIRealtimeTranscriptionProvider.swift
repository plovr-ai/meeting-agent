import Foundation

enum OpenAIRealtimeTranscriptionProviderError: Error, CustomStringConvertible, Equatable {
    case missingAPIKey
    case invalidEvent
    case transportClosed

    var description: String {
        switch self {
        case .missingAPIKey:
            return "OpenAI API key is not configured"
        case .invalidEvent:
            return "OpenAI Realtime transcription event could not be decoded"
        case .transportClosed:
            return "OpenAI Realtime transcription transport is closed"
        }
    }
}

enum OpenAIRealtimeTranscriptionEvent: Equatable {
    case connected
    case delta(itemID: String, text: String)
    case completed(itemID: String, transcript: String)
    case failed(String)
}

enum OpenAIRealtimeTranscriptionEventDecoder {
    static func decode(_ data: Data) throws -> OpenAIRealtimeTranscriptionEvent? {
        let envelope = try JSONDecoder().decode(EventEnvelope.self, from: data)
        switch envelope.type {
        case "session.created":
            return .connected
        case "conversation.item.input_audio_transcription.delta":
            return .delta(itemID: envelope.itemID ?? "", text: envelope.delta ?? "")
        case "conversation.item.input_audio_transcription.completed":
            return .completed(itemID: envelope.itemID ?? "", transcript: envelope.transcript ?? "")
        case "error":
            return .failed(envelope.error?.message ?? "OpenAI Realtime transcription error")
        default:
            return nil
        }
    }

    private struct EventEnvelope: Decodable {
        let type: String
        let itemID: String?
        let delta: String?
        let transcript: String?
        let error: ErrorEnvelope?

        enum CodingKeys: String, CodingKey {
            case type
            case itemID = "item_id"
            case delta
            case transcript
            case error
        }
    }

    private struct ErrorEnvelope: Decodable {
        let message: String
    }
}

protocol RealtimeTranscriptionWebSocketTransport: AnyObject {
    var incomingMessages: AsyncStream<Data> { get }
    func connect() async throws
    func send(_ data: Data) async throws
    func close() async
}

public struct OpenAIRealtimeTranscriptionProvider {
    private let apiKey: String?
    private let model: String
    private let transportFactory: (URL, String) -> RealtimeTranscriptionWebSocketTransport

    init(
        apiKey: String?,
        model: String = "gpt-4o-transcribe",
        transportFactory: @escaping (URL, String) -> RealtimeTranscriptionWebSocketTransport
    ) {
        self.apiKey = SpeechTranscriptionConfiguration.normalized(apiKey)
        self.model = model
        self.transportFactory = transportFactory
    }

    public init(apiKey: String?, model: String = "gpt-4o-transcribe") {
        self.init(
            apiKey: apiKey,
            model: model,
            transportFactory: { url, apiKey in
                URLSessionRealtimeTranscriptionWebSocketTransport(url: url, apiKey: apiKey)
            }
        )
    }

    public func start(context: SpeechTranscriptionStreamContext) async throws -> AudioFrameTranscriber {
        guard let apiKey else {
            throw OpenAIRealtimeTranscriptionProviderError.missingAPIKey
        }
        guard let url = URL(string: "wss://api.openai.com/v1/realtime?model=gpt-realtime") else {
            throw ProbeError.invalidArguments("Invalid OpenAI Realtime transcription URL")
        }
        let transport = transportFactory(url, apiKey)
        try await transport.connect()
        try await transport.send(try sessionUpdate(localeIdentifier: context.localeIdentifier))
        let writer = try TranscriptFileWriter(url: context.transcriptURL)
        return OpenAIRealtimeTranscriptionTranscriber(
            transport: transport,
            writer: writer,
            transcriptUpdateSink: context.transcriptUpdateSink,
            localeIdentifier: context.localeIdentifier
        )
    }

    private func sessionUpdate(localeIdentifier: String) throws -> Data {
        let language = localeIdentifier.split(separator: "-").first.map(String.init) ?? localeIdentifier
        let event = SessionUpdateEvent(session: Session(
            audio: Audio(input: AudioInput(
                format: AudioFormat(type: "audio/pcm", rate: 24_000),
                transcription: Transcription(model: model, language: language),
                turnDetection: TurnDetection(type: "server_vad")
            ))
        ))
        return try JSONEncoder().encode(event)
    }

    private struct SessionUpdateEvent: Encodable {
        var type = "session.update"
        var session: Session
    }

    private struct Session: Encodable {
        var type = "transcription"
        var audio: Audio
    }

    private struct Audio: Encodable {
        var input: AudioInput
    }

    private struct AudioInput: Encodable {
        var format: AudioFormat
        var transcription: Transcription
        var turnDetection: TurnDetection

        enum CodingKeys: String, CodingKey {
            case format
            case transcription
            case turnDetection = "turn_detection"
        }
    }

    private struct AudioFormat: Encodable {
        var type: String
        var rate: Int
    }

    private struct Transcription: Encodable {
        var model: String
        var language: String
    }

    private struct TurnDetection: Encodable {
        var type: String
    }
}

final class OpenAIRealtimeTranscriptionTranscriber: AudioFrameTranscriber {
    private let transport: RealtimeTranscriptionWebSocketTransport
    private let writer: TranscriptFileWriter
    private let transcriptUpdateSink: TranscriptUpdateSink?
    private let localeIdentifier: String
    private var receiveTask: Task<Void, Never>?
    private(set) var failureReason: String?

    init(
        transport: RealtimeTranscriptionWebSocketTransport,
        writer: TranscriptFileWriter,
        transcriptUpdateSink: TranscriptUpdateSink? = nil,
        localeIdentifier: String
    ) {
        self.transport = transport
        self.writer = writer
        self.transcriptUpdateSink = transcriptUpdateSink
        self.localeIdentifier = localeIdentifier
        self.receiveTask = Task { [transport, writer, transcriptUpdateSink, localeIdentifier] in
            var segmentIndex = 0
            for await data in transport.incomingMessages {
                do {
                    guard let event = try OpenAIRealtimeTranscriptionEventDecoder.decode(data) else { continue }
                    switch event {
                    case .completed(let itemID, let transcript):
                        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { continue }
                        let segment = TranscriptSegment(
                            id: itemID.isEmpty ? "openai-realtime-\(segmentIndex)" : itemID,
                            text: text,
                            language: localeIdentifier,
                            sourceProvider: "openai-realtime-transcribe",
                            isFinal: true,
                            timingSource: .unavailable
                        )
                        transcriptUpdateSink?.receive(.upsert(segment))
                        try writer.append(segment)
                        segmentIndex += 1
                    case .failed(let message):
                        transcriptUpdateSink?.receive(.replaceWithPlainText("OpenAI Realtime transcription failed: \(message)"))
                        try writer.replace(with: "OpenAI Realtime transcription failed: \(message)")
                    case .connected, .delta:
                        break
                    }
                } catch {
                    try? writer.replace(with: "OpenAI Realtime transcription failed: \(error)")
                }
            }
        }
    }

    func append(_ frame: AudioFrame) throws {
        Task { [transport] in
            do {
                try await transport.send(try Self.appendAudio(frame.pcm))
            } catch {
                self.failureReason = "OpenAI Realtime transcription failed: \(error)"
            }
        }
    }

    func finish() {
        receiveTask?.cancel()
        Task { [transport, writer] in
            await transport.close()
            try? writer.close()
        }
    }

    private static func appendAudio(_ pcm16: Data) throws -> Data {
        try JSONEncoder().encode(AppendAudioEvent(audio: pcm16.base64EncodedString()))
    }

    private struct AppendAudioEvent: Encodable {
        var type = "input_audio_buffer.append"
        var audio: String
    }
}

final class URLSessionRealtimeTranscriptionWebSocketTransport: RealtimeTranscriptionWebSocketTransport {
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
        task = URLSession.shared.webSocketTask(with: request)
        task?.resume()
        receiveNext()
    }

    func send(_ data: Data) async throws {
        guard let task else { throw OpenAIRealtimeTranscriptionProviderError.transportClosed }
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
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
