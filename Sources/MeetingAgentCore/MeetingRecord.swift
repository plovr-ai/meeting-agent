import Foundation

public struct MeetingRecord: Codable, Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var startedAt: Date
    public var endedAt: Date?
    public var audioURL: URL?
    public var transcriptURL: URL?

    public init(
        id: UUID,
        name: String,
        startedAt: Date,
        endedAt: Date?,
        audioURL: URL?,
        transcriptURL: URL?
    ) {
        self.id = id
        self.name = name
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.audioURL = audioURL
        self.transcriptURL = transcriptURL
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
