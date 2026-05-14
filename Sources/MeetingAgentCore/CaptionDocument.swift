import Foundation

public enum CaptionTurnState: String, Codable, Equatable, Sendable {
    case draft
    case final
}

public struct CaptionProviderInfo: Codable, Equatable, Sendable {
    public let id: String
    public let model: String?
    public let locale: String?

    public init(id: String, model: String? = nil, locale: String? = nil) {
        self.id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model.nilIfBlank
        self.locale = locale.nilIfBlank
    }
}

public struct CaptionSpeaker: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String?
    public let providerSpeakerID: String?

    public init(id: String, label: String? = nil, providerSpeakerID: String? = nil) {
        self.id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        self.label = label.nilIfBlank
        self.providerSpeakerID = providerSpeakerID.nilIfBlank
    }
}

public struct CaptionSection: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var text: String
    public var utteranceIDs: [String]
    public let startTimeSeconds: Double?
    public var endTimeSeconds: Double?

    public init(
        id: String = UUID().uuidString,
        text: String,
        utteranceIDs: [String] = [],
        startTimeSeconds: Double? = nil,
        endTimeSeconds: Double? = nil
    ) {
        self.id = id
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.utteranceIDs = Self.uniqueSorted(utteranceIDs)
        self.startTimeSeconds = startTimeSeconds
        self.endTimeSeconds = endTimeSeconds
    }

    private static func uniqueSorted(_ values: [String]) -> [String] {
        Array(Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
    }
}

public struct CaptionTurnSource: Codable, Equatable, Sendable {
    public let providerID: String
    public let streamID: String?
    public let resultIDs: [String]
    public let utteranceIDs: [String]

    public init(
        providerID: String,
        streamID: String? = nil,
        resultIDs: [String] = [],
        utteranceIDs: [String] = []
    ) {
        self.providerID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.streamID = streamID.nilIfBlank
        self.resultIDs = Self.uniqueSorted(resultIDs)
        self.utteranceIDs = Self.uniqueSorted(utteranceIDs)
    }

    private static func uniqueSorted(_ values: [String]) -> [String] {
        Array(Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
    }
}

public struct CaptionTurn: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let speakerID: String?
    public let speakerLabel: String?
    public let startTimeSeconds: Double?
    public var endTimeSeconds: Double?
    public var sections: [CaptionSection]
    public var state: CaptionTurnState
    public var source: CaptionTurnSource
    public let createdAt: Date
    public var updatedAt: Date

    public var text: String {
        sections
            .map(\.text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    public var speaker: TranscriptSpeaker {
        TranscriptSpeaker(identifier: speakerID, label: speakerLabel)
    }

    public var transcriptSegment: TranscriptSegment {
        TranscriptSegment(
            id: id,
            speaker: speaker,
            startTimeSeconds: startTimeSeconds,
            endTimeSeconds: endTimeSeconds,
            text: text,
            sourceProvider: source.providerID.isEmpty ? "unknown" : source.providerID,
            isFinal: state == .final,
            speechFinal: state == .final,
            createdAt: createdAt,
            timingSource: startTimeSeconds == nil && endTimeSeconds == nil ? .unavailable : .precise
        )
    }

    public init(
        id: String = UUID().uuidString,
        speakerID: String? = nil,
        speakerLabel: String? = nil,
        startTimeSeconds: Double? = nil,
        endTimeSeconds: Double? = nil,
        sections: [CaptionSection],
        state: CaptionTurnState,
        source: CaptionTurnSource,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.speakerID = speakerID.nilIfBlank
        self.speakerLabel = speakerLabel.nilIfBlank
        self.startTimeSeconds = startTimeSeconds
        self.endTimeSeconds = endTimeSeconds
        self.sections = sections
        self.state = state
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct CaptionDocument: Codable, Equatable, Sendable {
    public let version: Int
    public var speakers: [CaptionSpeaker]
    public var turns: [CaptionTurn]
    public var provider: CaptionProviderInfo?
    public let createdAt: Date
    public var updatedAt: Date
    public var finalizedAt: Date?

    public var transcriptDocument: TranscriptDocument {
        TranscriptDocument(version: version, segments: turns.map(\.transcriptSegment))
    }

    public init(
        version: Int = 2,
        speakers: [CaptionSpeaker] = [],
        turns: [CaptionTurn] = [],
        provider: CaptionProviderInfo? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        finalizedAt: Date? = nil
    ) {
        self.version = version
        self.speakers = speakers
        self.turns = turns
        self.provider = provider
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.finalizedAt = finalizedAt
    }
}

private extension Optional where Wrapped == String {
    var nilIfBlank: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
