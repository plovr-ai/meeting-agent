import Foundation

public enum CaptionTurnState: String, Codable, Equatable, Sendable {
    case draft
    case final
}

public enum TranscriptQualitySource: String, Codable, Equatable, Sendable {
    case liveOnly
    case postProcessed
    case fallbackLive
    case refinementFailed
}

public struct TranscriptQualityMetrics: Codable, Equatable, Sendable {
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

    public static func calculate(for turns: [CaptionTurn]) -> TranscriptQualityMetrics {
        var finalTurnCount = 0
        var draftTurnCount = 0
        var unknownSpeakerTurnCount = 0
        var emptyFinalTurnCount = 0

        for turn in turns {
            switch turn.state {
            case .draft:
                draftTurnCount += 1
            case .final:
                let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    emptyFinalTurnCount += 1
                    continue
                }
                finalTurnCount += 1
                if isUnknownSpeaker(turn) {
                    unknownSpeakerTurnCount += 1
                }
            }
        }

        return TranscriptQualityMetrics(
            finalTurnCount: finalTurnCount,
            draftTurnCount: draftTurnCount,
            unknownSpeakerTurnCount: unknownSpeakerTurnCount,
            emptyFinalTurnCount: emptyFinalTurnCount
        )
    }

    private static func isUnknownSpeaker(_ turn: CaptionTurn) -> Bool {
        guard let speakerID = turn.speakerID, !speakerID.isEmpty else {
            return true
        }
        return turn.speakerLabel == nil || turn.speakerLabel == speakerID
    }
}

public struct TranscriptQualityMetadata: Codable, Equatable, Sendable {
    public let source: TranscriptQualitySource
    public let fallbackReason: String?
    public let metrics: TranscriptQualityMetrics
    public let updatedAt: Date

    public init(
        source: TranscriptQualitySource,
        fallbackReason: String? = nil,
        metrics: TranscriptQualityMetrics = TranscriptQualityMetrics(),
        updatedAt: Date = Date()
    ) {
        self.source = source
        self.fallbackReason = fallbackReason.nilIfBlank
        self.metrics = metrics
        self.updatedAt = updatedAt
    }
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
    public var language: String?
    public var translatedText: String?
    public var translationTargetLocale: String?
    public var translationIsFinal: Bool?
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
            language: language,
            sourceProvider: source.providerID.isEmpty ? "unknown" : source.providerID,
            isFinal: state == .final,
            speechFinal: state == .final,
            createdAt: createdAt,
            timingSource: startTimeSeconds == nil && endTimeSeconds == nil ? .unavailable : .precise,
            translatedText: translatedText,
            translationTargetLocale: translationTargetLocale,
            translationIsFinal: translationIsFinal
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
        language: String? = nil,
        translatedText: String? = nil,
        translationTargetLocale: String? = nil,
        translationIsFinal: Bool? = nil,
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
        self.language = language.nilIfBlank
        self.translatedText = translatedText.nilIfBlank
        self.translationTargetLocale = translationTargetLocale.nilIfBlank
        self.translationIsFinal = translationIsFinal
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct CaptionDocument: Codable, Equatable, Sendable {
    public let version: Int
    public var speakers: [CaptionSpeaker]
    public var turns: [CaptionTurn]
    public var provider: CaptionProviderInfo?
    public var qualityMetadata: TranscriptQualityMetadata?
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
        qualityMetadata: TranscriptQualityMetadata? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        finalizedAt: Date? = nil
    ) {
        self.version = version
        self.speakers = speakers
        self.turns = turns
        self.provider = provider
        self.qualityMetadata = qualityMetadata
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.finalizedAt = finalizedAt
    }

    public func updatingQuality(
        source: TranscriptQualitySource,
        fallbackReason: String? = nil,
        updatedAt: Date = Date()
    ) -> CaptionDocument {
        var document = self
        document.qualityMetadata = TranscriptQualityMetadata(
            source: source,
            fallbackReason: fallbackReason,
            metrics: TranscriptQualityMetrics.calculate(for: turns),
            updatedAt: updatedAt
        )
        document.updatedAt = updatedAt
        return document
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
