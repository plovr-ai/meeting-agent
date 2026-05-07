import Foundation

public struct TranslationUnitBuilderOutput: Equatable {
    public var liveUnits: [LiveTranslationUnit]
    public var stableBlocks: [StableTranslationBlock]
}

public struct TranslationUnitBuilderConfiguration: Equatable {
    public var minimumLiveWords: Int
    public var unstableTailWords: Int
    public var minimumStableBlockCharacters: Int
    public var maximumStableBlockCharacters: Int
    public var maximumStableBlockDuration: TimeInterval
    public var pauseBoundaryInterval: TimeInterval

    public init(
        minimumLiveWords: Int = 6,
        unstableTailWords: Int = 1,
        minimumStableBlockCharacters: Int = 24,
        maximumStableBlockCharacters: Int = 220,
        maximumStableBlockDuration: TimeInterval = 12,
        pauseBoundaryInterval: TimeInterval = 1.2
    ) {
        self.minimumLiveWords = max(1, minimumLiveWords)
        self.unstableTailWords = max(0, unstableTailWords)
        self.minimumStableBlockCharacters = max(1, minimumStableBlockCharacters)
        self.maximumStableBlockCharacters = max(self.minimumStableBlockCharacters, maximumStableBlockCharacters)
        self.maximumStableBlockDuration = max(1, maximumStableBlockDuration)
        self.pauseBoundaryInterval = max(0.2, pauseBoundaryInterval)
    }
}

public struct TranslationUnitBuilder {
    private let sourceLocale: String
    private let targetLocale: String
    private let configuration: TranslationUnitBuilderConfiguration
    private var emittedStableBlockIDs = Set<String>()
    private var revisionsBySegmentID: [String: Int] = [:]
    private var processedFinalSegmentTextsByID: [String: String] = [:]
    private var chunkersByLaneID: [TranslationLaneID: LiveCaptionChunker] = [:]

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

        for segment in segments.sorted(by: { $0.createdAt < $1.createdAt }) {
            let segmentSourceLocale: String
            if let language = segment.language {
                segmentSourceLocale = language
            } else {
                segmentSourceLocale = sourceLocale
            }
            let laneID = TranslationLaneID(
                speaker: segment.speaker,
                sourceLocale: segmentSourceLocale,
                targetLocale: targetLocale
            )
            var sealedStableBlock = false

            if segment.isFinal {
                let alreadyProcessedFinalText = processedFinalSegmentTextsByID[segment.id] == segment.text
                let blocks = appendFinalSegment(segment, laneID: laneID, now: now)
                stableBlocks.append(contentsOf: blocks)
                sealedStableBlock = alreadyProcessedFinalText || !blocks.isEmpty
            }

            if !sealedStableBlock,
               let liveUnit = liveUnit(for: segment, laneID: laneID, now: now) {
                liveUnits.append(liveUnit)
            }
        }

        return TranslationUnitBuilderOutput(liveUnits: liveUnits, stableBlocks: stableBlocks)
    }

    public mutating func flushOpenBlocks(now: Date = Date()) -> [StableTranslationBlock] {
        var blocks: [StableTranslationBlock] = []
        let lanes = chunkersByLaneID.keys.sorted {
            if $0.speakerID == $1.speakerID {
                if $0.sourceLocale == $1.sourceLocale {
                    return $0.targetLocale < $1.targetLocale
                }
                return $0.sourceLocale < $1.sourceLocale
            }
            return $0.speakerID < $1.speakerID
        }
        for laneID in lanes {
            guard var chunker = chunkersByLaneID[laneID] else { continue }
            let updates = chunker.flushOpenChunk(reason: LiveCaptionFreezeReason.manualStop)
            chunkersByLaneID[laneID] = chunker
            blocks.append(contentsOf: updates.compactMap { stableBlock(from: $0.turn, now: now) })
        }
        return blocks
    }

    private mutating func liveUnit(for segment: TranscriptSegment, laneID: TranslationLaneID, now: Date) -> LiveTranslationUnit? {
        let words = segment.text.split { $0.isWhitespace || $0.isNewline }.map(String.init)
        guard words.count >= configuration.minimumLiveWords else { return nil }
        let stableCount = max(1, words.count - configuration.unstableTailWords)
        let stablePrefix = words.prefix(stableCount).joined(separator: " ")
        let unstableTail = words.dropFirst(stableCount).joined(separator: " ")
        let revision = (revisionsBySegmentID[segment.id] ?? 0) + 1
        revisionsBySegmentID[segment.id] = revision
        return LiveTranslationUnit(
            id: "\(segment.id)-live-\(revision)",
            laneID: laneID,
            stablePrefixText: stablePrefix,
            unstableTailText: unstableTail,
            sourceSegmentIDs: [segment.id],
            revision: revision,
            createdAt: segment.createdAt,
            deadline: now.addingTimeInterval(4),
            riskFlags: riskFlags(in: segment.text)
        )
    }

    private mutating func appendFinalSegment(
        _ segment: TranscriptSegment,
        laneID: TranslationLaneID,
        now: Date
    ) -> [StableTranslationBlock] {
        guard processedFinalSegmentTextsByID[segment.id] != segment.text else { return [] }
        processedFinalSegmentTextsByID[segment.id] = segment.text
        var chunker = chunkersByLaneID[laneID] ?? makeChunker()
        let updates = chunker.append(segment)
        chunkersByLaneID[laneID] = chunker
        return updates.compactMap { stableBlock(from: $0.turn, now: now) }
    }

    private func makeChunker() -> LiveCaptionChunker {
        LiveCaptionChunker(
            sourceLocale: sourceLocale,
            targetLocale: targetLocale,
            policy: LiveCaptionChunkingPolicy(
                maxCharacters: configuration.maximumStableBlockCharacters,
                maxDurationSeconds: configuration.maximumStableBlockDuration,
                minPunctuationCharacters: configuration.minimumStableBlockCharacters,
                readableCharacterLimit: configuration.maximumStableBlockCharacters,
                shortFragmentCharacters: 24,
                maxMergeGapSeconds: configuration.pauseBoundaryInterval,
                minSentenceBoundaryCharacters: configuration.minimumStableBlockCharacters
            )
        )
    }

    private mutating func stableBlock(from turn: LiveCaptionTurn, now: Date) -> StableTranslationBlock? {
        guard turn.displayState == .sealed,
              let reason = stableBoundaryReason(from: turn.boundaryReason)
        else {
            return nil
        }
        let text = turn.originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard text.count >= configuration.minimumStableBlockCharacters || reason == .manualStop else { return nil }
        guard !fillerLike(text) else { return nil }
        let blockID = [
            "stable",
            turn.speaker.identifier ?? "default",
            StableTranslationBlock.stableHash(text),
            turn.sourceSegmentIDs.joined(separator: ",")
        ].joined(separator: "-")
        guard emittedStableBlockIDs.insert(blockID).inserted else { return nil }
        return StableTranslationBlock(
            id: blockID,
            laneID: TranslationLaneID(
                speaker: turn.speaker,
                sourceLocale: turn.sourceLocale,
                targetLocale: turn.targetLocale
            ),
            sourceText: text,
            sourceSegmentIDs: turn.sourceSegmentIDs,
            boundaryReason: reason,
            createdAt: turn.createdAt
        )
    }

    private func stableBoundaryReason(from reason: LiveCaptionFreezeReason?) -> StableTranslationBoundaryReason? {
        switch reason {
        case .speechFinal:
            return .providerHardBoundary
        case .speakerChanged:
            return .speakerChanged
        case .maxLength:
            return .maxLength
        case .maxDuration:
            return .maxDuration
        case .punctuation:
            return .terminalPunctuation
        case .manualStop:
            return .manualStop
        case nil:
            return nil
        }
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

    private func fillerLike(_ text: String) -> Bool {
        let normalized = text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
        return ["", "um", "uh", "er", "ah", "hmm", "yeah", "ok", "okay"].contains(normalized)
    }
}
