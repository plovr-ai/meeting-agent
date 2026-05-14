import Foundation

public struct TranscriptConsumptionView: Equatable, Sendable {
    public let meetingID: UUID
    public let language: String?
    public let provider: CaptionProviderInfo?
    public let finalTurns: [TranscriptConsumptionTurn]
    public let quality: TranscriptConsumptionQuality

    public init(
        meetingID: UUID,
        language: String? = nil,
        provider: CaptionProviderInfo? = nil,
        finalTurns: [TranscriptConsumptionTurn] = [],
        quality: TranscriptConsumptionQuality = TranscriptConsumptionQuality()
    ) {
        self.meetingID = meetingID
        self.language = language
        self.provider = provider
        self.finalTurns = finalTurns
        self.quality = quality
    }

    public static func project(meetingID: UUID, document: CaptionDocument) -> TranscriptConsumptionView {
        let finalSourceTurns = document.turns.filter { $0.state == .final }
        let finalTurns = finalSourceTurns.compactMap(TranscriptConsumptionTurn.init(turn:))
        let draftTurnCount = document.turns.filter { $0.state == .draft }.count
        let unknownSpeakerTurnCount = finalTurns.filter { turn in
            guard let speakerID = turn.speakerID, !speakerID.isEmpty else { return true }
            return turn.speakerLabel == nil || turn.speakerLabel == speakerID
        }.count
        let emptyFinalTurnCount = finalSourceTurns.count - finalTurns.count

        return TranscriptConsumptionView(
            meetingID: meetingID,
            language: document.provider?.locale,
            provider: document.provider,
            finalTurns: finalTurns,
            quality: TranscriptConsumptionQuality(
                finalTurnCount: finalTurns.count,
                draftTurnCount: draftTurnCount,
                unknownSpeakerTurnCount: unknownSpeakerTurnCount,
                emptyFinalTurnCount: emptyFinalTurnCount
            )
        )
    }
}

public struct TranscriptConsumptionTurn: Equatable, Sendable {
    public let turnID: String
    public let speakerID: String?
    public let speakerLabel: String?
    public let sections: [TranscriptConsumptionSection]
    public let text: String
    public let startTimeSeconds: Double?
    public let endTimeSeconds: Double?
    public let sourceIDs: [String]

    public init(
        turnID: String,
        speakerID: String? = nil,
        speakerLabel: String? = nil,
        sections: [TranscriptConsumptionSection],
        startTimeSeconds: Double? = nil,
        endTimeSeconds: Double? = nil,
        sourceIDs: [String] = []
    ) {
        self.turnID = turnID
        self.speakerID = speakerID.nilIfBlankForTranscriptConsumption
        self.speakerLabel = speakerLabel.nilIfBlankForTranscriptConsumption
        self.sections = sections
        self.text = sections.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        self.startTimeSeconds = startTimeSeconds
        self.endTimeSeconds = endTimeSeconds
        self.sourceIDs = Self.uniqueIDs(sourceIDs)
    }

    init?(turn: CaptionTurn) {
        let sections = turn.sections.compactMap(TranscriptConsumptionSection.init(section:))
        let text = sections.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        self.turnID = turn.id
        self.speakerID = turn.speakerID
        self.speakerLabel = turn.speakerLabel ?? turn.speakerID
        self.sections = sections
        self.text = text
        self.startTimeSeconds = turn.startTimeSeconds
        self.endTimeSeconds = turn.endTimeSeconds
        self.sourceIDs = Self.sourceIDs(for: turn, sections: sections)
    }

    private static func sourceIDs(for turn: CaptionTurn, sections: [TranscriptConsumptionSection]) -> [String] {
        let utteranceIDs = uniqueIDs(sections.flatMap(\.sourceIDs) + turn.source.utteranceIDs)
        if !utteranceIDs.isEmpty {
            return utteranceIDs
        }
        let resultIDs = uniqueIDs(turn.source.resultIDs)
        if !resultIDs.isEmpty {
            return resultIDs
        }
        return uniqueIDs([turn.id])
    }

    private static func uniqueIDs(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var unique: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            unique.append(trimmed)
        }
        return unique
    }
}

public struct TranscriptConsumptionSection: Equatable, Sendable {
    public let id: String
    public let text: String
    public let startTimeSeconds: Double?
    public let endTimeSeconds: Double?
    public let sourceIDs: [String]

    public init(
        id: String,
        text: String,
        startTimeSeconds: Double? = nil,
        endTimeSeconds: Double? = nil,
        sourceIDs: [String] = []
    ) {
        self.id = id
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.startTimeSeconds = startTimeSeconds
        self.endTimeSeconds = endTimeSeconds
        self.sourceIDs = Self.uniqueIDs(sourceIDs)
    }

    init?(section: CaptionSection) {
        let text = section.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        self.id = section.id
        self.text = text
        self.startTimeSeconds = section.startTimeSeconds
        self.endTimeSeconds = section.endTimeSeconds
        self.sourceIDs = Self.uniqueIDs(section.utteranceIDs)
    }

    private static func uniqueIDs(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var unique: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            unique.append(trimmed)
        }
        return unique
    }
}

public struct TranscriptConsumptionQuality: Equatable, Sendable {
    public let finalTurnCount: Int
    public let draftTurnCount: Int
    public let unknownSpeakerTurnCount: Int
    public let emptyFinalTurnCount: Int

    public init(
        finalTurnCount: Int = 0,
        draftTurnCount: Int = 0,
        unknownSpeakerTurnCount: Int = 0,
        emptyFinalTurnCount: Int = 0
    ) {
        self.finalTurnCount = finalTurnCount
        self.draftTurnCount = draftTurnCount
        self.unknownSpeakerTurnCount = unknownSpeakerTurnCount
        self.emptyFinalTurnCount = emptyFinalTurnCount
    }
}

private extension Optional where Wrapped == String {
    var nilIfBlankForTranscriptConsumption: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
