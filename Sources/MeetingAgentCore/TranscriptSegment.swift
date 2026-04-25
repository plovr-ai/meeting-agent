import Foundation

public struct TranscriptSpeaker: Equatable, Hashable {
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
    public let confidence: Double?
    public let createdAt: Date
    public let timingSource: TranscriptTimingSource

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
        confidence: Double? = nil,
        createdAt: Date = Date(),
        timingSource: TranscriptTimingSource = .unavailable
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
        self.confidence = confidence
        self.createdAt = createdAt
        self.timingSource = timingSource
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
        var mapper = SpeakerLabelMapper()
        return turns(from: segments).map { turn in
            let label = mapper.label(for: turn.speaker)
            return ([label + ":"] + turn.texts).joined(separator: "\n")
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
}

struct SpeakerLabelMapper {
    private var labelsBySpeaker: [TranscriptSpeaker: String] = [:]
    private var nextIndex = 0

    mutating func label(for speaker: TranscriptSpeaker) -> String {
        if let label = speaker.label {
            return label
        }
        if let existing = labelsBySpeaker[speaker] {
            return existing
        }
        let label = "User \(Self.letter(for: nextIndex))"
        labelsBySpeaker[speaker] = label
        nextIndex += 1
        return label
    }

    private static func letter(for index: Int) -> String {
        let scalar = UnicodeScalar(UInt8(ascii: "A") + UInt8(index % 26))
        let suffix = index < 26 ? "" : " \(index / 26 + 1)"
        return "\(Character(scalar))\(suffix)"
    }
}
