import Foundation

public struct TranscriptSpeaker: Codable, Equatable, Hashable {
    public static let `default` = TranscriptSpeaker(identifier: nil)

    public let identifier: String?
    public let label: String?

    public init(identifier: String?, label: String? = nil) {
        let trimmed = identifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.identifier = trimmed.flatMap { $0.isEmpty ? nil : $0 }
        let trimmedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.label = trimmedLabel.flatMap { $0.isEmpty ? nil : $0 }
    }
}

public enum TranscriptTimingSource: String, Codable, Equatable {
    case precise
    case approximate
    case unavailable
}

public struct TranscriptSegment: Codable, Equatable, Identifiable {
    public let id: String
    public let speakerID: String?
    public let speakerLabel: String?
    public let startTimeSeconds: Double?
    public let endTimeSeconds: Double?
    public let text: String
    public let language: String?
    public let sourceProvider: String
    public let isFinal: Bool
    public let speechFinal: Bool
    public let confidence: Double?
    public let createdAt: Date
    public let timingSource: TranscriptTimingSource
    public let translatedText: String?
    public let translationTargetLocale: String?
    public let translationIsFinal: Bool?

    public var speaker: TranscriptSpeaker {
        TranscriptSpeaker(identifier: speakerID, label: speakerLabel)
    }

    public init(
        id: String = UUID().uuidString,
        speaker: TranscriptSpeaker = .default,
        startTimeSeconds: Double? = nil,
        endTimeSeconds: Double? = nil,
        text: String,
        language: String? = nil,
        sourceProvider: String = "unknown",
        isFinal: Bool = true,
        speechFinal: Bool = false,
        confidence: Double? = nil,
        createdAt: Date = Date(),
        timingSource: TranscriptTimingSource = .unavailable,
        translatedText: String? = nil,
        translationTargetLocale: String? = nil,
        translationIsFinal: Bool? = nil
    ) {
        self.id = id
        self.speakerID = speaker.identifier
        self.speakerLabel = speaker.label
        self.startTimeSeconds = startTimeSeconds
        self.endTimeSeconds = endTimeSeconds
        self.text = text
        self.language = language
        self.sourceProvider = sourceProvider
        self.isFinal = isFinal
        self.speechFinal = speechFinal
        self.confidence = confidence
        self.createdAt = createdAt
        self.timingSource = timingSource
        self.translatedText = translatedText
        self.translationTargetLocale = translationTargetLocale
        self.translationIsFinal = translationIsFinal
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case speakerID
        case speakerLabel
        case startTimeSeconds
        case endTimeSeconds
        case text
        case language
        case sourceProvider
        case isFinal
        case speechFinal
        case confidence
        case createdAt
        case timingSource
        case translatedText
        case translationTargetLocale
        case translationIsFinal
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        speakerID = try container.decodeIfPresent(String.self, forKey: .speakerID)
        speakerLabel = try container.decodeIfPresent(String.self, forKey: .speakerLabel)
        startTimeSeconds = try container.decodeIfPresent(Double.self, forKey: .startTimeSeconds)
        endTimeSeconds = try container.decodeIfPresent(Double.self, forKey: .endTimeSeconds)
        text = try container.decode(String.self, forKey: .text)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        sourceProvider = try container.decodeIfPresent(String.self, forKey: .sourceProvider) ?? "unknown"
        isFinal = try container.decodeIfPresent(Bool.self, forKey: .isFinal) ?? true
        speechFinal = try container.decodeIfPresent(Bool.self, forKey: .speechFinal) ?? false
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        timingSource = try container.decodeIfPresent(TranscriptTimingSource.self, forKey: .timingSource) ?? .unavailable
        translatedText = try container.decodeIfPresent(String.self, forKey: .translatedText)
        translationTargetLocale = try container.decodeIfPresent(String.self, forKey: .translationTargetLocale)
        translationIsFinal = try container.decodeIfPresent(Bool.self, forKey: .translationIsFinal)
    }
}

public struct TranscriptDocument: Codable, Equatable {
    public let version: Int
    public var segments: [TranscriptSegment]

    public init(version: Int = 1, segments: [TranscriptSegment] = []) {
        self.version = version
        self.segments = segments
    }
}

public struct TranscriptFormatter {
    public static func render(_ segments: [TranscriptSegment]) -> String {
        let transcriptTurns = turns(from: segments)
        var mapper = SpeakerLabelMapper(speakers: transcriptTurns.map(\.speaker))
        return transcriptTurns.map { turn in
            let label = mapper.label(for: turn.speaker)
            return [label + ":", turn.renderedText].joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }

    private static func turns(from segments: [TranscriptSegment]) -> [TranscriptTurn] {
        var turns: [TranscriptTurn] = []
        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let lastIndex = turns.indices.last, turns[lastIndex].speaker == segment.speaker {
                turns[lastIndex].texts.append(text)
            } else {
                turns.append(TranscriptTurn(speaker: segment.speaker, texts: [text]))
            }
        }
        return turns
    }
}

private struct TranscriptTurn {
    let speaker: TranscriptSpeaker
    var texts: [String]

    var renderedText: String {
        texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

struct SpeakerLabelMapper {
    private var labelsBySpeaker: [TranscriptSpeaker: String] = [:]
    private var labelsByIdentifier: [String: String] = [:]
    private var defaultLabelsBySpeaker: [TranscriptSpeaker: String] = [:]
    private var defaultLabelsByIdentifier: [String: String] = [:]
    private var usedLabels = Set<String>()
    private var nextIndex = 0

    init(speakers: [TranscriptSpeaker] = []) {
        for speaker in speakers {
            reserveDefaultLabel(for: speaker)
        }
    }

    mutating func label(for speaker: TranscriptSpeaker) -> String {
        if let label = speaker.label {
            remember(label: label, for: speaker)
            return label
        }
        if let identifier = speaker.identifier,
           let defaultLabel = defaultLabelsByIdentifier[identifier] {
            remember(label: defaultLabel, for: speaker)
            return defaultLabel
        }
        if let defaultLabel = defaultLabelsBySpeaker[speaker] {
            remember(label: defaultLabel, for: speaker)
            return defaultLabel
        }
        if let identifier = speaker.identifier,
           let existing = labelsByIdentifier[identifier] {
            remember(label: existing, for: speaker)
            return existing
        }
        if let existing = labelsBySpeaker[speaker] {
            return existing
        }
        let label = nextUnusedLabel()
        remember(label: label, for: speaker)
        return label
    }

    private mutating func reserveDefaultLabel(for speaker: TranscriptSpeaker) {
        if let identifier = speaker.identifier {
            guard defaultLabelsByIdentifier[identifier] == nil else { return }
            let label = nextSequentialLabel()
            defaultLabelsByIdentifier[identifier] = label
            defaultLabelsBySpeaker[speaker] = label
            return
        }
        guard defaultLabelsBySpeaker[speaker] == nil else { return }
        defaultLabelsBySpeaker[speaker] = nextSequentialLabel()
    }

    private mutating func remember(label: String, for speaker: TranscriptSpeaker) {
        labelsBySpeaker[speaker] = label
        if let identifier = speaker.identifier {
            labelsByIdentifier[identifier] = label
        }
        usedLabels.insert(label)
    }

    private mutating func nextUnusedLabel() -> String {
        while true {
            let label = "User \(Self.letter(for: nextIndex))"
            nextIndex += 1
            if !usedLabels.contains(label) {
                return label
            }
        }
    }

    private mutating func nextSequentialLabel() -> String {
        let label = "User \(Self.letter(for: nextIndex))"
        nextIndex += 1
        return label
    }

    private static func letter(for index: Int) -> String {
        let scalar = UnicodeScalar(UInt8(ascii: "A") + UInt8(index % 26))
        let suffix = index < 26 ? "" : " \(index / 26 + 1)"
        return "\(Character(scalar))\(suffix)"
    }
}
