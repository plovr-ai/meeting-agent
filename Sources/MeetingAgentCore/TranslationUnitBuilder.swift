import Foundation

public struct TranslationUnitBuilderOutput: Equatable {
    public var liveUnits: [LiveTranslationUnit]
    public var stableBlocks: [StableTranslationBlock]
}

public struct TranslationUnitBuilderConfiguration: Equatable {
    public var minimumLiveWords: Int
    public var unstableTailWords: Int
    public var minimumStableBlockCharacters: Int

    public init(minimumLiveWords: Int = 6, unstableTailWords: Int = 1, minimumStableBlockCharacters: Int = 24) {
        self.minimumLiveWords = minimumLiveWords
        self.unstableTailWords = unstableTailWords
        self.minimumStableBlockCharacters = minimumStableBlockCharacters
    }
}

public struct TranslationUnitBuilder {
    private let sourceLocale: String
    private let targetLocale: String
    private let configuration: TranslationUnitBuilderConfiguration
    private var emittedStableBlockIDs = Set<String>()
    private var revisionsBySegmentID: [String: Int] = [:]

    public init(
        sourceLocale: String,
        targetLocale: String,
        configuration: TranslationUnitBuilderConfiguration = TranslationUnitBuilderConfiguration()
    ) {
        self.sourceLocale = sourceLocale
        self.targetLocale = targetLocale
        self.configuration = configuration
    }

    public mutating func apply(segments: [TranscriptSegment], now: Date = Date()) -> TranslationUnitBuilderOutput {
        var liveUnits: [LiveTranslationUnit] = []
        var stableBlocks: [StableTranslationBlock] = []

        for segment in segments {
            let laneID = TranslationLaneID(
                speaker: segment.speaker,
                sourceLocale: segment.language ?? sourceLocale,
                targetLocale: targetLocale
            )
            if let liveUnit = liveUnit(for: segment, laneID: laneID, now: now) {
                liveUnits.append(liveUnit)
            }
            if let stableBlock = stableBlock(for: segment, laneID: laneID) {
                stableBlocks.append(stableBlock)
            }
        }

        return TranslationUnitBuilderOutput(liveUnits: liveUnits, stableBlocks: stableBlocks)
    }

    private mutating func liveUnit(for segment: TranscriptSegment, laneID: TranslationLaneID, now: Date) -> LiveTranslationUnit? {
        let words = segment.text.split { $0.isWhitespace || $0.isNewline }.map(String.init)
        guard words.count >= configuration.minimumLiveWords else { return nil }
        let stableCount = max(1, words.count - configuration.unstableTailWords)
        let stablePrefix = words.prefix(stableCount).joined(separator: " ")
        let unstableTail = words.dropFirst(stableCount).joined(separator: " ")
        revisionsBySegmentID[segment.id, default: 0] += 1
        return LiveTranslationUnit(
            id: "\(segment.id)-live-\(revisionsBySegmentID[segment.id, default: 0])",
            laneID: laneID,
            stablePrefixText: stablePrefix,
            unstableTailText: unstableTail,
            sourceSegmentIDs: [segment.id],
            revision: revisionsBySegmentID[segment.id, default: 0],
            createdAt: segment.createdAt,
            deadline: now.addingTimeInterval(4),
            riskFlags: riskFlags(in: segment.text)
        )
    }

    private mutating func stableBlock(for segment: TranscriptSegment, laneID: TranslationLaneID) -> StableTranslationBlock? {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard segment.isFinal, text.count >= configuration.minimumStableBlockCharacters else { return nil }
        let reason: StableTranslationBoundaryReason?
        if segment.speechFinal {
            reason = .providerHardBoundary
        } else if hasTerminalPunctuation(text) {
            reason = .terminalPunctuation
        } else {
            reason = nil
        }
        guard let reason else { return nil }
        let blockID = "\(segment.id)-stable-\(StableTranslationBlock.stableHash(text))"
        guard emittedStableBlockIDs.insert(blockID).inserted else { return nil }
        return StableTranslationBlock(
            id: blockID,
            laneID: laneID,
            sourceText: text,
            sourceSegmentIDs: [segment.id],
            boundaryReason: reason,
            createdAt: segment.createdAt
        )
    }

    private func hasTerminalPunctuation(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return [".", "?", "!", "。", "？", "！"].contains(String(last))
    }

    private func riskFlags(in text: String) -> Set<TranslationRiskFlag> {
        let lowercased = text.lowercased()
        var flags: Set<TranslationRiskFlag> = []
        if lowercased.rangeOfCharacter(from: .decimalDigits) != nil {
            flags.insert(.number)
        }
        if lowercased.contains("cannot")
            || lowercased.contains("can't")
            || lowercased.contains(" not ")
            || lowercased.hasPrefix("not ") {
            flags.insert(.negation)
        }
        if lowercased.contains("will")
            || lowercased.contains("must")
            || lowercased.contains("approved")
            || lowercased.contains("blocked") {
            flags.insert(.commitment)
        }
        return flags
    }
}
