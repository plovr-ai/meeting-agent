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
    private var processedFinalSegmentIDs = Set<String>()
    private var laneStates: [TranslationLaneID: TranslationLaneState] = [:]

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
                appendFinalSegment(segment, laneID: laneID)
                if let reason = boundaryReason(for: segment, laneID: laneID, now: now),
                   let block = sealBlock(for: laneID, reason: reason, now: now) {
                    stableBlocks.append(block)
                    sealedStableBlock = true
                }
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
        let lanes = laneStates.keys.sorted {
            if $0.speakerID == $1.speakerID {
                if $0.sourceLocale == $1.sourceLocale {
                    return $0.targetLocale < $1.targetLocale
                }
                return $0.sourceLocale < $1.sourceLocale
            }
            return $0.speakerID < $1.speakerID
        }
        for laneID in lanes {
            guard let block = sealBlock(for: laneID, reason: .manualStop, now: now) else { continue }
            blocks.append(block)
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

    private mutating func appendFinalSegment(_ segment: TranscriptSegment, laneID: TranslationLaneID) {
        guard processedFinalSegmentIDs.insert(segment.id).inserted else { return }
        var state = laneStates[laneID, default: TranslationLaneState()]
        state.segmentIDs.append(segment.id)
        state.segmentTexts.append(segment.text)
        state.firstCreatedAt = state.firstCreatedAt ?? segment.createdAt
        state.lastCreatedAt = segment.createdAt
        state.lastSeenSegmentID = segment.id
        laneStates[laneID] = state
    }

    private func boundaryReason(
        for segment: TranscriptSegment,
        laneID: TranslationLaneID,
        now: Date
    ) -> StableTranslationBoundaryReason? {
        guard let state = laneStates[laneID], !state.isEmpty else { return nil }
        if segment.speechFinal {
            return .providerHardBoundary
        }
        if hasTerminalPunctuation(state.sourceText),
           state.sourceText.count >= configuration.minimumStableBlockCharacters {
            return .terminalPunctuation
        }
        if state.sourceText.count >= configuration.maximumStableBlockCharacters {
            return .maxLength
        }
        if let firstCreatedAt = state.firstCreatedAt,
           now.timeIntervalSince(firstCreatedAt) >= configuration.maximumStableBlockDuration {
            return .maxDuration
        }
        return nil
    }

    private mutating func sealBlock(
        for laneID: TranslationLaneID,
        reason: StableTranslationBoundaryReason,
        now: Date
    ) -> StableTranslationBlock? {
        guard let state = laneStates[laneID] else { return nil }
        let text = state.sourceText
        guard !text.isEmpty else {
            laneStates[laneID] = TranslationLaneState()
            return nil
        }
        guard text.count >= configuration.minimumStableBlockCharacters || reason == .manualStop else { return nil }
        guard !fillerLike(text) else {
            laneStates[laneID] = TranslationLaneState()
            return nil
        }
        let blockID = [
            "stable",
            laneID.speakerID,
            StableTranslationBlock.stableHash(text),
            state.segmentIDs.joined(separator: ",")
        ].joined(separator: "-")
        guard emittedStableBlockIDs.insert(blockID).inserted else {
            laneStates[laneID] = TranslationLaneState()
            return nil
        }
        laneStates[laneID] = TranslationLaneState()
        let createdAt: Date
        if let firstCreatedAt = state.firstCreatedAt {
            createdAt = firstCreatedAt
        } else {
            createdAt = now
        }
        return StableTranslationBlock(
            id: blockID,
            laneID: laneID,
            sourceText: text,
            sourceSegmentIDs: state.segmentIDs,
            boundaryReason: reason,
            createdAt: createdAt
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

    private func fillerLike(_ text: String) -> Bool {
        let normalized = text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
        return ["", "um", "uh", "er", "ah", "hmm", "yeah", "ok", "okay"].contains(normalized)
    }
}

private struct TranslationLaneState: Equatable {
    var segmentIDs: [String] = []
    var segmentTexts: [String] = []
    var firstCreatedAt: Date?
    var lastCreatedAt: Date?
    var lastSeenSegmentID: String?

    var sourceText: String {
        segmentTexts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    var isEmpty: Bool {
        sourceText.isEmpty
    }
}
