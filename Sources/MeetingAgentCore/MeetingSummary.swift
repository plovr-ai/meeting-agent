import Foundation

public enum MeetingSummaryStatus: String, Codable, Equatable {
    case succeeded
    case failed
}

public struct MeetingActionItem: Codable, Equatable {
    public let description: String
    public let owner: String?
    public let dueDate: String?
    public let sourceSegmentIDs: [String]
    public let confidence: Double

    public init(
        description: String,
        owner: String?,
        dueDate: String?,
        sourceSegmentIDs: [String],
        confidence: Double
    ) {
        self.description = description
        self.owner = owner
        self.dueDate = dueDate
        self.sourceSegmentIDs = sourceSegmentIDs
        self.confidence = confidence
    }
}

public struct MeetingDecision: Codable, Equatable {
    public let description: String
    public let participants: [String]
    public let sourceSegmentIDs: [String]
    public let confidence: Double

    public init(
        description: String,
        participants: [String],
        sourceSegmentIDs: [String],
        confidence: Double
    ) {
        self.description = description
        self.participants = participants
        self.sourceSegmentIDs = sourceSegmentIDs
        self.confidence = confidence
    }
}

public struct MeetingSummary: Codable, Equatable {
    public let overview: String
    public let keyTopics: [String]
    public let decisions: [MeetingDecision]
    public let actionItems: [MeetingActionItem]
    public let openQuestions: [String]
    public let risks: [String]
    public let followUps: [String]
    public let language: String?
    public let sourceSegmentIDs: [String]
    public let generatedAt: Date
    public let provider: String
    public let status: MeetingSummaryStatus
    public let failureReason: String?

    public init(
        overview: String,
        keyTopics: [String],
        decisions: [MeetingDecision],
        actionItems: [MeetingActionItem],
        openQuestions: [String],
        risks: [String],
        followUps: [String],
        language: String?,
        sourceSegmentIDs: [String],
        generatedAt: Date,
        provider: String,
        status: MeetingSummaryStatus,
        failureReason: String?
    ) {
        self.overview = overview
        self.keyTopics = keyTopics
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.risks = risks
        self.followUps = followUps
        self.language = language
        self.sourceSegmentIDs = sourceSegmentIDs
        self.generatedAt = generatedAt
        self.provider = provider
        self.status = status
        self.failureReason = failureReason
    }
}
