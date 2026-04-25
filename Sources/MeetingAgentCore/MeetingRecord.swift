import Foundation

public enum TranscriptionStatus: String, Codable, Equatable {
    case notStarted
    case transcribing
    case transcribed
    case failed
    case retryRequested
}

public struct MeetingRecord: Codable, Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var startedAt: Date
    public var endedAt: Date?
    public var audioURL: URL?
    public var transcriptURL: URL?
    public var transcriptJSONURL: URL?
    public var summaryURL: URL?
    public var diagnosticsURL: URL?
    public var transcriptionStatus: TranscriptionStatus
    public var transcriptionFailureReason: String?
    public var speechProvider: SpeechProvider
    public var speechLocaleIdentifier: String

    public init(
        id: UUID,
        name: String,
        startedAt: Date,
        endedAt: Date?,
        audioURL: URL?,
        transcriptURL: URL?,
        transcriptJSONURL: URL? = nil,
        summaryURL: URL? = nil,
        diagnosticsURL: URL? = nil,
        transcriptionStatus: TranscriptionStatus = .notStarted,
        transcriptionFailureReason: String? = nil,
        speechProvider: SpeechProvider = .whisper,
        speechLocaleIdentifier: String = "en-US"
    ) {
        self.id = id
        self.name = name
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.audioURL = audioURL
        self.transcriptURL = transcriptURL
        self.transcriptJSONURL = transcriptJSONURL
        self.summaryURL = summaryURL
        self.diagnosticsURL = diagnosticsURL
        self.transcriptionStatus = transcriptionStatus
        self.transcriptionFailureReason = transcriptionFailureReason
        self.speechProvider = speechProvider
        self.speechLocaleIdentifier = SpeechTranscriptionConfiguration.normalized(speechLocaleIdentifier, fallback: "en-US") ?? "en-US"
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case startedAt
        case endedAt
        case audioURL
        case transcriptURL
        case transcriptJSONURL
        case summaryURL
        case diagnosticsURL
        case transcriptionStatus
        case transcriptionFailureReason
        case speechProvider
        case speechLocaleIdentifier
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        audioURL = try container.decodeIfPresent(URL.self, forKey: .audioURL)
        transcriptURL = try container.decodeIfPresent(URL.self, forKey: .transcriptURL)
        transcriptJSONURL = try container.decodeIfPresent(URL.self, forKey: .transcriptJSONURL)
        summaryURL = try container.decodeIfPresent(URL.self, forKey: .summaryURL)
        diagnosticsURL = try container.decodeIfPresent(URL.self, forKey: .diagnosticsURL)
        transcriptionStatus = try container.decodeIfPresent(TranscriptionStatus.self, forKey: .transcriptionStatus) ?? .notStarted
        transcriptionFailureReason = try container.decodeIfPresent(String.self, forKey: .transcriptionFailureReason)
        speechProvider = try container.decodeIfPresent(SpeechProvider.self, forKey: .speechProvider) ?? .whisper
        speechLocaleIdentifier = try container.decodeIfPresent(String.self, forKey: .speechLocaleIdentifier) ?? "en-US"
    }
}

public extension JSONEncoder {
    static var meetingAgent: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

public extension JSONDecoder {
    static var meetingAgent: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
