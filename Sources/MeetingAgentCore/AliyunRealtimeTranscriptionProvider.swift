import Foundation

enum AliyunRealtimeTranscriptionProviderError: Error, CustomStringConvertible, Equatable {
    case missingAPIKey
    case invalidURL
    case transportClosed

    var description: String {
        switch self {
        case .missingAPIKey:
            return "DashScope API key is not configured"
        case .invalidURL:
            return "Invalid Aliyun realtime transcription URL"
        case .transportClosed:
            return "Aliyun realtime transcription transport is closed"
        }
    }
}

enum AliyunRealtimeTranscriptionEvent: Equatable {
    case started(taskID: String)
    case result(
        taskID: String,
        text: String,
        beginTimeMilliseconds: Int?,
        endTimeMilliseconds: Int?,
        sentenceEnd: Bool
    )
    case finished(taskID: String)
    case failed(taskID: String, message: String)
}

enum AliyunRealtimeTranscriptionEventDecoder {
    static func decode(_ data: Data) throws -> AliyunRealtimeTranscriptionEvent? {
        let envelope = try JSONDecoder().decode(EventEnvelope.self, from: data)
        let taskID = envelope.header.taskID ?? ""
        switch envelope.header.event {
        case "task-started":
            return .started(taskID: taskID)
        case "result-generated":
            guard let sentence = envelope.payload?.output?.sentence else { return nil }
            let text = sentence.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, sentence.heartbeat != true else { return nil }
            return .result(
                taskID: taskID,
                text: text,
                beginTimeMilliseconds: sentence.beginTime,
                endTimeMilliseconds: sentence.endTime,
                sentenceEnd: sentence.sentenceEnd
            )
        case "task-finished":
            return .finished(taskID: taskID)
        case "task-failed":
            return .failed(
                taskID: taskID,
                message: envelope.header.errorMessage ?? "Aliyun realtime transcription failed"
            )
        default:
            return nil
        }
    }

    private struct EventEnvelope: Decodable {
        let header: Header
        let payload: Payload?
    }

    private struct Header: Decodable {
        let event: String
        let taskID: String?
        let errorMessage: String?

        enum CodingKeys: String, CodingKey {
            case event
            case taskID = "task_id"
            case errorMessage = "error_message"
        }
    }

    private struct Payload: Decodable {
        let output: Output?
    }

    private struct Output: Decodable {
        let sentence: Sentence?
    }

    private struct Sentence: Decodable {
        let text: String
        let beginTime: Int?
        let endTime: Int?
        let sentenceEnd: Bool
        let heartbeat: Bool?

        enum CodingKeys: String, CodingKey {
            case text
            case beginTime = "begin_time"
            case endTime = "end_time"
            case sentenceEnd = "sentence_end"
            case heartbeat
        }
    }
}

protocol AliyunRealtimeWebSocketTransport: AnyObject {
    var incomingMessages: AsyncStream<Data> { get }
    func connect() async throws
    func sendText(_ text: String) async throws
    func sendBinary(_ data: Data) async throws
    func close() async
}

public struct AliyunRealtimeTranscriptionProvider {
    private let apiKey: String?
    private let model: String
    private let transportFactory: (URL, String) -> AliyunRealtimeWebSocketTransport
    private let taskIDFactory: () -> String

    init(
        apiKey: String?,
        model: String = SpeechTranscriptionConfiguration.defaultAliyunRealtimeTranscriptionModelID,
        transportFactory: @escaping (URL, String) -> AliyunRealtimeWebSocketTransport,
        taskIDFactory: @escaping () -> String = { UUID().uuidString }
    ) {
        self.apiKey = SpeechTranscriptionConfiguration.normalized(apiKey)
        self.model = SpeechTranscriptionConfiguration.normalized(
            model,
            fallback: SpeechTranscriptionConfiguration.defaultAliyunRealtimeTranscriptionModelID
        ) ?? SpeechTranscriptionConfiguration.defaultAliyunRealtimeTranscriptionModelID
        self.transportFactory = transportFactory
        self.taskIDFactory = taskIDFactory
    }

    public init(
        apiKey: String?,
        model: String = SpeechTranscriptionConfiguration.defaultAliyunRealtimeTranscriptionModelID
    ) {
        self.init(
            apiKey: apiKey,
            model: model,
            transportFactory: { url, apiKey in
                URLSessionAliyunRealtimeWebSocketTransport(url: url, apiKey: apiKey)
            }
        )
    }

    public func start(context: SpeechTranscriptionStreamContext) async throws -> AudioFrameTranscriber {
        guard let apiKey else {
            throw AliyunRealtimeTranscriptionProviderError.missingAPIKey
        }
        guard let url = URL(string: "wss://dashscope.aliyuncs.com/api-ws/v1/inference") else {
            throw AliyunRealtimeTranscriptionProviderError.invalidURL
        }
        let transport = transportFactory(url, apiKey)
        try await transport.connect()
        let taskID = taskIDFactory()
        try await transport.sendText(try runTaskCommand(
            taskID: taskID,
            context: context
        ))
        let fallbackSink = context.transcriptUpdateSink
            ?? CaptionDocumentTranscriptUpdateSink(transcriptURL: context.transcriptURL)
        return AliyunRealtimeTranscriber(
            taskID: taskID,
            transport: transport,
            transcriptUpdateSink: fallbackSink,
            localeIdentifier: context.localeIdentifier
        )
    }

    private func runTaskCommand(
        taskID: String,
        context: SpeechTranscriptionStreamContext
    ) throws -> String {
        let command = RunTaskCommand(
            header: CommandHeader(action: "run-task", taskID: taskID, streaming: "duplex"),
            payload: RunTaskPayload(
                taskGroup: "audio",
                task: "asr",
                function: "recognition",
                model: model,
                parameters: RunTaskParameters(
                    format: "pcm",
                    sampleRate: Int(context.sampleRate.rounded()),
                    disfluencyRemovalEnabled: false,
                    languageHints: Self.languageHints(for: context.localeIdentifier),
                    semanticPunctuationEnabled: true,
                    punctuationPredictionEnabled: true,
                    inverseTextNormalizationEnabled: true
                ),
                input: EmptyPayload()
            )
        )
        return String(decoding: try JSONEncoder().encode(command), as: UTF8.self)
    }

    private static func languageHints(for localeIdentifier: String) -> [String]? {
        let normalized = localeIdentifier.lowercased()
        if normalized.hasPrefix("zh") { return ["zh"] }
        if normalized.hasPrefix("en") { return ["en"] }
        if normalized.hasPrefix("ja") { return ["ja"] }
        if normalized.hasPrefix("ko") { return ["ko"] }
        if normalized.hasPrefix("de") { return ["de"] }
        if normalized.hasPrefix("fr") { return ["fr"] }
        if normalized.hasPrefix("ru") { return ["ru"] }
        return nil
    }
}

final class AliyunRealtimeTranscriber: AudioFrameTranscriber {
    private let taskID: String
    private let transport: AliyunRealtimeWebSocketTransport
    private let transcriptUpdateSink: TranscriptUpdateSink?
    private let localeIdentifier: String
    private let stateLock = NSLock()
    private var pendingFrames: [Data] = []
    private var isTaskStarted = false
    private var segmentIndex = 0
    private var receiveTask: Task<Void, Never>?
    private(set) var failureReason: String?

    init(
        taskID: String,
        transport: AliyunRealtimeWebSocketTransport,
        transcriptUpdateSink: TranscriptUpdateSink? = nil,
        localeIdentifier: String
    ) {
        self.taskID = taskID
        self.transport = transport
        self.transcriptUpdateSink = transcriptUpdateSink
        self.localeIdentifier = localeIdentifier
        self.receiveTask = Task { [weak self, transport] in
            for await data in transport.incomingMessages {
                self?.handleIncoming(data)
            }
        }
    }

    func append(_ frame: AudioFrame) throws {
        let pcm = frame.pcm
        stateLock.lock()
        let shouldSend = isTaskStarted
        if !shouldSend {
            pendingFrames.append(pcm)
        }
        stateLock.unlock()

        guard shouldSend else { return }
        Task { [weak self] in
            await self?.sendBinary(pcm)
        }
    }

    func finish() {
        Task { [taskID, transport] in
            let command = FinishTaskCommand(
                header: CommandHeader(action: "finish-task", taskID: taskID, streaming: "duplex"),
                payload: FinishTaskPayload(input: EmptyPayload())
            )
            if let data = try? JSONEncoder().encode(command) {
                try? await transport.sendText(String(decoding: data, as: UTF8.self))
            }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await transport.close()
        }
    }

    private func handleIncoming(_ data: Data) {
        do {
            guard let event = try AliyunRealtimeTranscriptionEventDecoder.decode(data) else { return }
            switch event {
            case .started:
                markStartedAndFlush()
            case .result(_, let text, let beginTime, let endTime, let sentenceEnd):
                publishSegment(
                    text: text,
                    beginTimeMilliseconds: beginTime,
                    endTimeMilliseconds: endTime,
                    sentenceEnd: sentenceEnd
                )
            case .finished:
                Task { [transport] in await transport.close() }
            case .failed(_, let message):
                recordFailure("Aliyun realtime transcription failed: \(message)")
                transcriptUpdateSink?.receive(.replaceWithPlainText("Aliyun realtime transcription failed: \(message)"))
            }
        } catch {
            recordFailure("Aliyun realtime transcription failed: \(error)")
        }
    }

    private func markStartedAndFlush() {
        stateLock.lock()
        isTaskStarted = true
        let frames = pendingFrames
        pendingFrames.removeAll()
        stateLock.unlock()

        for frame in frames {
            Task { [weak self] in
                await self?.sendBinary(frame)
            }
        }
    }

    private func sendBinary(_ data: Data) async {
        do {
            try await transport.sendBinary(data)
        } catch {
            recordFailure("Aliyun realtime transcription failed: \(error)")
        }
    }

    private func publishSegment(
        text: String,
        beginTimeMilliseconds: Int?,
        endTimeMilliseconds: Int?,
        sentenceEnd: Bool
    ) {
        let index = segmentIndex
        if sentenceEnd {
            segmentIndex += 1
        }
        let segment = TranscriptSegment(
            id: sentenceEnd
                ? "\(SpeechTranscriptionConfiguration.defaultAliyunRealtimeTranscriptionProviderID)-stream-\(index)"
                : "\(SpeechTranscriptionConfiguration.defaultAliyunRealtimeTranscriptionProviderID)-stream-active",
            startTimeSeconds: beginTimeMilliseconds.map { Double($0) / 1000 },
            endTimeSeconds: endTimeMilliseconds.map { Double($0) / 1000 },
            text: text,
            language: localeIdentifier,
            sourceProvider: SpeechTranscriptionConfiguration.defaultAliyunRealtimeTranscriptionProviderID,
            isFinal: sentenceEnd,
            speechFinal: sentenceEnd,
            timingSource: beginTimeMilliseconds == nil && endTimeMilliseconds == nil ? .unavailable : .precise
        )
        if sentenceEnd {
            transcriptUpdateSink?.receiveFinal(.upsert(segment))
        } else {
            transcriptUpdateSink?.receiveRealtime(.upsert(segment))
        }
    }

    private func recordFailure(_ message: String) {
        stateLock.lock()
        failureReason = message
        stateLock.unlock()
    }
}

final class URLSessionAliyunRealtimeWebSocketTransport: AliyunRealtimeWebSocketTransport {
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
    }

    func sendText(_ text: String) async throws {
        guard let task else { throw AliyunRealtimeTranscriptionProviderError.transportClosed }
        try await task.send(.string(text))
    }

    func sendBinary(_ data: Data) async throws {
        guard let task else { throw AliyunRealtimeTranscriptionProviderError.transportClosed }
        try await task.send(.data(data))
    }

    func close() async {
        task?.cancel(with: .normalClosure, reason: nil)
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

private struct CommandHeader: Encodable {
    var action: String
    var taskID: String
    var streaming: String

    enum CodingKeys: String, CodingKey {
        case action
        case taskID = "task_id"
        case streaming
    }
}

private struct EmptyPayload: Encodable {}

private struct RunTaskCommand: Encodable {
    var header: CommandHeader
    var payload: RunTaskPayload
}

private struct RunTaskPayload: Encodable {
    var taskGroup: String
    var task: String
    var function: String
    var model: String
    var parameters: RunTaskParameters
    var input: EmptyPayload

    enum CodingKeys: String, CodingKey {
        case taskGroup = "task_group"
        case task
        case function
        case model
        case parameters
        case input
    }
}

private struct RunTaskParameters: Encodable {
    var format: String
    var sampleRate: Int
    var disfluencyRemovalEnabled: Bool
    var languageHints: [String]?
    var semanticPunctuationEnabled: Bool
    var punctuationPredictionEnabled: Bool
    var inverseTextNormalizationEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case format
        case sampleRate = "sample_rate"
        case disfluencyRemovalEnabled = "disfluency_removal_enabled"
        case languageHints = "language_hints"
        case semanticPunctuationEnabled = "semantic_punctuation_enabled"
        case punctuationPredictionEnabled = "punctuation_prediction_enabled"
        case inverseTextNormalizationEnabled = "inverse_text_normalization_enabled"
    }
}

private struct FinishTaskCommand: Encodable {
    var header: CommandHeader
    var payload: FinishTaskPayload
}

private struct FinishTaskPayload: Encodable {
    var input: EmptyPayload
}
