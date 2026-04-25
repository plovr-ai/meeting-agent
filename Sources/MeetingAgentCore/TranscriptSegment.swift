import Foundation

public struct TranscriptSpeaker: Equatable, Hashable {
    public static let `default` = TranscriptSpeaker(identifier: nil)

    public let identifier: String?

    public init(identifier: String?) {
        let trimmed = identifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.identifier = trimmed.flatMap { $0.isEmpty ? nil : $0 }
    }
}

public struct TranscriptSegment: Equatable {
    public let speaker: TranscriptSpeaker
    public let text: String

    public init(speaker: TranscriptSpeaker = .default, text: String) {
        self.speaker = speaker
        self.text = text
    }
}

public struct TranscriptFormatter {
    public static func render(_ segments: [TranscriptSegment]) -> String {
        var mapper = SpeakerLabelMapper()
        return segments.compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return "\(mapper.label(for: segment.speaker)): \(text)"
        }
        .joined(separator: "\n")
    }
}

struct SpeakerLabelMapper {
    private var labelsBySpeaker: [TranscriptSpeaker: String] = [:]
    private var nextIndex = 0

    mutating func label(for speaker: TranscriptSpeaker) -> String {
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
