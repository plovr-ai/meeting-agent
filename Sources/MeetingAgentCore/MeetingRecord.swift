import Foundation

public enum TranscriptionStatus: String, Codable, Equatable {
    case notStarted
    case transcribing
    case transcribed
    case failed
    case retryRequested
}

public struct MeetingAttendee: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var role: String?

    public init(id: UUID = UUID(), name: String, role: String? = nil) {
        self.id = id
        self.name = name
        self.role = role
    }
}

public struct MeetingAgendaTopic: Codable, Identifiable, Equatable {
    public var id: UUID
    public var title: String

    public init(id: UUID = UUID(), title: String) {
        self.id = id
        self.title = title
    }
}

public struct MeetingAgendaUpdate: Equatable {
    public var name: String
    public var attendees: [MeetingAttendee]
    public var agendaTopics: [MeetingAgendaTopic]
    public var scheduledStartAt: Date?
    public var scheduledEndAt: Date?
    public var meetingGoal: MeetingGoal?
    public var meetingGoals: [MeetingGoal]

    public init(
        name: String,
        attendees: [MeetingAttendee],
        agendaTopics: [MeetingAgendaTopic],
        scheduledStartAt: Date?,
        scheduledEndAt: Date?,
        meetingGoal: MeetingGoal?,
        meetingGoals: [MeetingGoal] = []
    ) {
        self.name = name
        self.attendees = attendees
        self.agendaTopics = agendaTopics
        self.scheduledStartAt = scheduledStartAt
        self.scheduledEndAt = scheduledEndAt
        if !meetingGoals.isEmpty {
            self.meetingGoals = meetingGoals
        } else if let meetingGoal {
            self.meetingGoals = [meetingGoal]
        } else {
            self.meetingGoals = []
        }
        self.meetingGoal = meetingGoal ?? self.meetingGoals.first
    }
}

public struct MeetingRecord: Codable, Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var startedAt: Date
    public var endedAt: Date?
    public var audioURL: URL?
    public var transcriptURL: URL?
    public var transcriptJSONURL: URL?
    public var meetingProgressJSONURL: URL?
    public var summaryURL: URL?
    public var summaryJSONURL: URL?
    public var summaryMarkdownURL: URL?
    public var diagnosticsURL: URL?
    public var performanceEventsURL: URL?
    public var transcriptionStatus: TranscriptionStatus
    public var transcriptionFailureReason: String?
    public var speechProvider: SpeechProvider
    public var transcriptionProviderID: String
    public var speechLocaleIdentifier: String
    public var meetingGoal: MeetingGoal?
    public var meetingGoals: [MeetingGoal]
    public var attendees: [MeetingAttendee]
    public var agendaTopics: [MeetingAgendaTopic]
    public var scheduledStartAt: Date?
    public var scheduledEndAt: Date?

    public init(
        id: UUID,
        name: String,
        startedAt: Date,
        endedAt: Date?,
        audioURL: URL?,
        transcriptURL: URL?,
        transcriptJSONURL: URL? = nil,
        meetingProgressJSONURL: URL? = nil,
        summaryURL: URL? = nil,
        summaryJSONURL: URL? = nil,
        summaryMarkdownURL: URL? = nil,
        diagnosticsURL: URL? = nil,
        performanceEventsURL: URL? = nil,
        transcriptionStatus: TranscriptionStatus = .notStarted,
        transcriptionFailureReason: String? = nil,
        speechProvider: SpeechProvider = .whisper,
        transcriptionProviderID: String? = nil,
        speechLocaleIdentifier: String = "en-US",
        meetingGoal: MeetingGoal? = nil,
        meetingGoals: [MeetingGoal]? = nil,
        attendees: [MeetingAttendee] = [],
        agendaTopics: [MeetingAgendaTopic] = [],
        scheduledStartAt: Date? = nil,
        scheduledEndAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.audioURL = audioURL
        self.transcriptURL = transcriptURL
        self.transcriptJSONURL = transcriptJSONURL
        self.meetingProgressJSONURL = meetingProgressJSONURL
        self.summaryURL = summaryURL
        self.summaryJSONURL = summaryJSONURL
        self.summaryMarkdownURL = summaryMarkdownURL ?? summaryURL
        self.diagnosticsURL = diagnosticsURL
        self.performanceEventsURL = performanceEventsURL
        self.transcriptionStatus = transcriptionStatus
        self.transcriptionFailureReason = transcriptionFailureReason
        self.speechProvider = speechProvider
        self.transcriptionProviderID = SpeechTranscriptionConfiguration.normalized(
            transcriptionProviderID,
            fallback: speechProvider.rawValue
        ) ?? speechProvider.rawValue
        self.speechLocaleIdentifier = SpeechTranscriptionConfiguration.normalized(speechLocaleIdentifier, fallback: "en-US") ?? "en-US"
        if let meetingGoals {
            self.meetingGoals = meetingGoals
        } else if let meetingGoal {
            self.meetingGoals = [meetingGoal]
        } else {
            self.meetingGoals = []
        }
        self.meetingGoal = meetingGoal ?? self.meetingGoals.first
        self.attendees = attendees
        self.agendaTopics = agendaTopics
        self.scheduledStartAt = scheduledStartAt
        self.scheduledEndAt = scheduledEndAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case startedAt
        case endedAt
        case audioURL
        case transcriptURL
        case transcriptJSONURL
        case meetingProgressJSONURL
        case summaryURL
        case summaryJSONURL
        case summaryMarkdownURL
        case diagnosticsURL
        case performanceEventsURL
        case transcriptionStatus
        case transcriptionFailureReason
        case speechProvider
        case transcriptionProviderID
        case speechLocaleIdentifier
        case meetingGoal
        case meetingGoals
        case attendees
        case agendaTopics
        case scheduledStartAt
        case scheduledEndAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        audioURL = try container.decodeIfPresent(URL.self, forKey: .audioURL)
        transcriptURL = try container.decodeIfPresent(URL.self, forKey: .transcriptURL)
        transcriptJSONURL = try container.decodeIfPresent(URL.self, forKey: .transcriptJSONURL)
        meetingProgressJSONURL = try container.decodeIfPresent(URL.self, forKey: .meetingProgressJSONURL)
        summaryURL = try container.decodeIfPresent(URL.self, forKey: .summaryURL)
        summaryJSONURL = try container.decodeIfPresent(URL.self, forKey: .summaryJSONURL)
        summaryMarkdownURL = try container.decodeIfPresent(URL.self, forKey: .summaryMarkdownURL) ?? summaryURL
        diagnosticsURL = try container.decodeIfPresent(URL.self, forKey: .diagnosticsURL)
        performanceEventsURL = try container.decodeIfPresent(URL.self, forKey: .performanceEventsURL)
        transcriptionStatus = try container.decodeIfPresent(TranscriptionStatus.self, forKey: .transcriptionStatus) ?? .notStarted
        transcriptionFailureReason = try container.decodeIfPresent(String.self, forKey: .transcriptionFailureReason)
        speechProvider = try container.decodeIfPresent(SpeechProvider.self, forKey: .speechProvider) ?? .whisper
        transcriptionProviderID = try container.decodeIfPresent(String.self, forKey: .transcriptionProviderID)
            ?? speechProvider.rawValue
        speechLocaleIdentifier = try container.decodeIfPresent(String.self, forKey: .speechLocaleIdentifier) ?? "en-US"
        let decodedMeetingGoal = try container.decodeIfPresent(MeetingGoal.self, forKey: .meetingGoal)
        if let decodedMeetingGoals = try container.decodeIfPresent([MeetingGoal].self, forKey: .meetingGoals) {
            meetingGoals = decodedMeetingGoals
        } else if let decodedMeetingGoal {
            meetingGoals = [decodedMeetingGoal]
        } else {
            meetingGoals = []
        }
        meetingGoal = decodedMeetingGoal ?? meetingGoals.first
        attendees = try container.decodeIfPresent([MeetingAttendee].self, forKey: .attendees) ?? []
        agendaTopics = try container.decodeIfPresent([MeetingAgendaTopic].self, forKey: .agendaTopics) ?? []
        scheduledStartAt = try container.decodeIfPresent(Date.self, forKey: .scheduledStartAt)
        scheduledEndAt = try container.decodeIfPresent(Date.self, forKey: .scheduledEndAt)
    }
}

public extension JSONEncoder {
    static var meetingAgent: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

public extension JSONDecoder {
    static var meetingAgent: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
