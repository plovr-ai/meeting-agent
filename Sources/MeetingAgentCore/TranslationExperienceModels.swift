import Foundation

public enum TranslationRiskFlag: String, Codable, Equatable, Hashable, CaseIterable {
    case number
    case dateOrTime
    case negation
    case commitment
    case namedEntity
    case speakerChanged
    case localeChanged
}

public enum StableTranslationBoundaryReason: String, Codable, Equatable {
    case providerHardBoundary
    case speakerChanged
    case terminalPunctuation
    case pause
    case maxDuration
    case maxLength
    case manualStop
}

public enum TranslationDisplayState: String, Codable, Equatable {
    case none
    case pending
    case liveFresh
    case liveLagging
    case liveCarried
    case stableFinal
    case failedRecoverable
    case disabledBudget

    public var priority: Int {
        switch self {
        case .stableFinal: return 70
        case .liveFresh: return 60
        case .liveLagging: return 50
        case .liveCarried: return 40
        case .pending: return 30
        case .failedRecoverable: return 20
        case .disabledBudget: return 10
        case .none: return 0
        }
    }
}

public struct TranslationLaneID: Codable, Equatable, Hashable {
    public var speakerID: String
    public var sourceLocale: String
    public var targetLocale: String

    public init(speaker: TranscriptSpeaker, sourceLocale: String, targetLocale: String) {
        let trimmedSpeakerID = speaker.identifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.speakerID = (trimmedSpeakerID?.isEmpty == false ? trimmedSpeakerID : nil) ?? "default"
        self.sourceLocale = Self.normalizedLocale(sourceLocale)
        self.targetLocale = Self.normalizedLocale(targetLocale)
    }

    static func normalizedLocale(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
    }
}

public struct LiveTranslationUnit: Codable, Equatable, Identifiable {
    public var id: String
    public var laneID: TranslationLaneID
    public var stablePrefixText: String
    public var unstableTailText: String
    public var sourceSegmentIDs: [String]
    public var contextBefore: String
    public var revision: Int
    public var createdAt: Date
    public var deadline: Date
    public var riskFlags: Set<TranslationRiskFlag>

    public var isEmpty: Bool {
        stablePrefixText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public init(
        id: String,
        laneID: TranslationLaneID,
        stablePrefixText: String,
        unstableTailText: String = "",
        sourceSegmentIDs: [String],
        contextBefore: String = "",
        revision: Int,
        createdAt: Date,
        deadline: Date,
        riskFlags: Set<TranslationRiskFlag> = []
    ) {
        self.id = id
        self.laneID = laneID
        self.stablePrefixText = stablePrefixText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.unstableTailText = unstableTailText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sourceSegmentIDs = sourceSegmentIDs
        self.contextBefore = contextBefore.trimmingCharacters(in: .whitespacesAndNewlines)
        self.revision = revision
        self.createdAt = createdAt
        self.deadline = deadline
        self.riskFlags = riskFlags
    }
}

public struct StableTranslationBlock: Codable, Equatable, Identifiable {
    public var id: String
    public var laneID: TranslationLaneID
    public var sourceText: String
    public var sourceSegmentIDs: [String]
    public var previousBlockSummary: String
    public var meetingGoalContext: String
    public var keyTerms: [MeetingKeyTerm]
    public var boundaryReason: StableTranslationBoundaryReason
    public var createdAt: Date
    public var sourceTextHash: String
    public var contextHash: String

    public init(
        id: String,
        laneID: TranslationLaneID,
        sourceText: String,
        sourceSegmentIDs: [String],
        previousBlockSummary: String = "",
        meetingGoalContext: String = "",
        keyTerms: [MeetingKeyTerm] = [],
        boundaryReason: StableTranslationBoundaryReason,
        createdAt: Date
    ) {
        self.id = id
        self.laneID = laneID
        self.sourceText = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sourceSegmentIDs = sourceSegmentIDs
        self.previousBlockSummary = previousBlockSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        self.meetingGoalContext = meetingGoalContext.trimmingCharacters(in: .whitespacesAndNewlines)
        self.keyTerms = keyTerms
        self.boundaryReason = boundaryReason
        self.createdAt = createdAt
        self.sourceTextHash = Self.stableHash(self.sourceText)
        self.contextHash = Self.stableHash([
            self.previousBlockSummary,
            self.meetingGoalContext,
            keyTerms.map { "\($0.value)=\($0.translationHint ?? "")" }.joined(separator: "|")
        ].joined(separator: "\u{1F}"))
    }

    static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

public struct TranslationResult: Codable, Equatable, Identifiable {
    public var id: String
    public var sourceID: String
    public var laneID: TranslationLaneID
    public var sourceText: String
    public var translatedText: String
    public var displayState: TranslationDisplayState
    public var createdAt: Date
    public var sourceCreatedAt: Date
    public var riskFlags: Set<TranslationRiskFlag>

    public init(
        id: String,
        sourceID: String,
        laneID: TranslationLaneID,
        sourceText: String,
        translatedText: String,
        displayState: TranslationDisplayState,
        createdAt: Date,
        sourceCreatedAt: Date,
        riskFlags: Set<TranslationRiskFlag> = []
    ) {
        self.id = id
        self.sourceID = sourceID
        self.laneID = laneID
        self.sourceText = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.translatedText = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayState = displayState
        self.createdAt = createdAt
        self.sourceCreatedAt = sourceCreatedAt
        self.riskFlags = riskFlags
    }
}
