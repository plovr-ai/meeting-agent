import Foundation

public struct TranslationRecentBlock: Codable, Equatable {
    public var sourceText: String
    public var translatedText: String
    public var laneID: TranslationLaneID
    public var createdAt: Date
}

public struct TranslationContext: Codable, Equatable {
    public var recentBlocks: [TranslationRecentBlock]
    public var meetingGoalContext: String
    public var keyTerms: [MeetingKeyTerm]
    public var promptSummary: String
    public var contextHash: String
}

public struct TranslationContextStore: Equatable {
    private var maxRecentBlocks: Int
    private var meetingGoalContext: String = ""
    private var keyTerms: [MeetingKeyTerm] = []
    private var recentBlocksByLane: [TranslationLaneID: [TranslationRecentBlock]] = [:]
    private var now: () -> Date

    public init(maxRecentBlocks: Int = 2, now: @escaping () -> Date = Date.init) {
        self.maxRecentBlocks = max(1, maxRecentBlocks)
        self.now = now
    }

    public static func == (lhs: TranslationContextStore, rhs: TranslationContextStore) -> Bool {
        lhs.maxRecentBlocks == rhs.maxRecentBlocks
            && lhs.meetingGoalContext == rhs.meetingGoalContext
            && lhs.keyTerms == rhs.keyTerms
            && lhs.recentBlocksByLane == rhs.recentBlocksByLane
    }

    public mutating func updateMeetingGoal(_ value: String) {
        meetingGoalContext = value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public mutating func updateKeyTerms(_ terms: [MeetingKeyTerm]) {
        keyTerms = terms
    }

    public mutating func recordStableTranslation(sourceText: String, translatedText: String, laneID: TranslationLaneID) {
        let block = TranslationRecentBlock(
            sourceText: sourceText.trimmingCharacters(in: .whitespacesAndNewlines),
            translatedText: translatedText.trimmingCharacters(in: .whitespacesAndNewlines),
            laneID: laneID,
            createdAt: now()
        )
        var blocks = recentBlocksByLane[laneID, default: []]
        blocks.append(block)
        if blocks.count > maxRecentBlocks {
            blocks.removeFirst(blocks.count - maxRecentBlocks)
        }
        recentBlocksByLane[laneID] = blocks
    }

    public func context(for laneID: TranslationLaneID) -> TranslationContext {
        let recentBlocks = recentBlocksByLane[laneID, default: []]
        let summary = recentBlocks.map {
            "Source: \($0.sourceText)\nTranslation: \($0.translatedText)"
        }.joined(separator: "\n\n")
        let hashInput = [
            meetingGoalContext,
            keyTerms.map { "\($0.value)=\($0.translationHint ?? "")" }.joined(separator: "|"),
            summary
        ].joined(separator: "\u{1F}")
        return TranslationContext(
            recentBlocks: recentBlocks,
            meetingGoalContext: meetingGoalContext,
            keyTerms: keyTerms,
            promptSummary: summary,
            contextHash: StableTranslationBlock.stableHash(hashInput)
        )
    }
}
