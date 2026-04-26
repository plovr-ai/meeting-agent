import Foundation

public enum RealtimeTranslationStatus: Equatable {
    case idle
    case connecting
    case connected
    case degraded(String)
    case failed(String)
}

public struct RealtimeTranslationConfiguration: Equatable {
    public var apiKey: String?
    public var model: String
    public var targetLocale: String
    public var voice: String

    public init(
        apiKey: String? = ProcessInfo.processInfo.environment["MEETING_AGENT_OPENAI_API_KEY"],
        model: String = ProcessInfo.processInfo.environment["MEETING_AGENT_REALTIME_MODEL"] ?? "gpt-realtime",
        targetLocale: String = ProcessInfo.processInfo.environment["MEETING_AGENT_REALTIME_TARGET_LOCALE"] ?? "zh-CN",
        voice: String = ProcessInfo.processInfo.environment["MEETING_AGENT_REALTIME_VOICE"] ?? "marin"
    ) {
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "gpt-realtime" : model
        self.targetLocale = targetLocale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "zh-CN" : targetLocale
        self.voice = voice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "marin" : voice
    }

    public var validationError: String? {
        if apiKey?.isEmpty ?? true {
            return "MEETING_AGENT_OPENAI_API_KEY is not configured"
        }
        return nil
    }
}

public enum RealtimeTranslationEvent: Equatable {
    case connected
    case targetAudioDelta(Data)
    case targetTextDelta(String)
    case targetTextFinal(String)
    case rateLimitsUpdated
    case failed(String)
    case stopped
}

public struct LiveTranslationTurn: Identifiable, Equatable {
    public var id: String
    public var targetLocale: String
    public var text: String
    public var isFinal: Bool
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        targetLocale: String,
        text: String,
        isFinal: Bool,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.targetLocale = targetLocale
        self.text = text
        self.isFinal = isFinal
        self.createdAt = createdAt
    }
}

public struct LiveTranslationStore: Equatable {
    public private(set) var turns: [LiveTranslationTurn] = []
    public var targetLocale: String

    public init(targetLocale: String = "zh-CN") {
        self.targetLocale = targetLocale
    }

    public mutating func appendDelta(_ delta: String) {
        guard !delta.isEmpty else { return }
        if let index = turns.indices.last, turns[index].isFinal == false {
            turns[index].text += delta
        } else {
            turns.append(LiveTranslationTurn(
                targetLocale: targetLocale,
                text: delta,
                isFinal: false
            ))
        }
    }

    public mutating func finalize(_ text: String) {
        let finalText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalText.isEmpty else { return }
        if let index = turns.indices.last, turns[index].isFinal == false {
            turns[index].text = finalText
            turns[index].isFinal = true
        } else {
            turns.append(LiveTranslationTurn(
                targetLocale: targetLocale,
                text: finalText,
                isFinal: true
            ))
        }
    }

    public mutating func reset(targetLocale: String) {
        self.targetLocale = targetLocale
        turns.removeAll()
    }
}

public protocol RealtimeSpeechTranslationProvider {
    var descriptor: ProviderDescriptor { get }
    func start(configuration: RealtimeTranslationConfiguration) async throws -> RealtimeTranslationSession
}

public protocol RealtimeTranslationSession: AnyObject {
    var events: AsyncStream<RealtimeTranslationEvent> { get }
    func append(_ frames: [AudioFrame]) async throws
    func stop() async
}

public protocol AudioPlaybackSink: AnyObject {
    func play(_ pcmData: Data, sampleRate: Double, channelCount: Int) async throws
    func stop() async
}
