import Foundation

public struct MeetingSessionState: Equatable {
    public let meetingID: UUID
    public var transcript: TranscriptState
    public var summary: SummaryState

    public init(meetingID: UUID, transcript: TranscriptState? = nil, summary: SummaryState = .missing) {
        self.meetingID = meetingID
        self.transcript = transcript ?? TranscriptState(meetingID: meetingID)
        self.summary = summary
    }
}

public enum TranscriptStateSource: Equatable {
    case empty
    case activeRecording
    case hydratedFromPersistence
}

public struct TranscriptState: Equatable {
    public let meetingID: UUID
    public var captionDocument: CaptionDocument
    public var source: TranscriptStateSource

    public var consumptionView: TranscriptConsumptionView {
        TranscriptConsumptionView.project(meetingID: meetingID, document: captionDocument)
    }

    public var visibleTurns: [LiveCaptionTurn] {
        captionDocument.turns.compactMap { turn in
            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return LiveCaptionTurn(
                id: turn.id,
                sourceSegmentID: turn.id,
                sourceSegmentIDs: Self.sourceIDs(for: turn),
                speaker: turn.speaker,
                originalText: text,
                sourceLocale: captionDocument.provider?.locale ?? "en-US",
                isFinal: turn.state == .final,
                createdAt: turn.createdAt,
                chunkState: turn.state == .final ? .frozen : .draft,
                displayState: turn.state == .final ? .sealed : .draft,
                translationState: turn.state == .final ? .none : .draft
            )
        }
    }

    public init(
        meetingID: UUID,
        captionDocument: CaptionDocument = CaptionDocument(),
        source: TranscriptStateSource = .empty
    ) {
        self.meetingID = meetingID
        self.captionDocument = captionDocument
        self.source = source
    }

    private static func sourceIDs(for turn: CaptionTurn) -> [String] {
        let values = turn.sections.flatMap(\.utteranceIDs) + turn.source.utteranceIDs + turn.source.resultIDs + [turn.id]
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

public enum SummaryStateStatus: Equatable {
    case missing
    case loaded
    case generating
    case generated
    case failed(String)
}

public enum SummaryStateSource: Equatable {
    case none
    case loadedFromPersistence
    case generatedInSession
}

public struct SummaryState: Equatable {
    public var summary: MeetingSummary?
    public var status: SummaryStateStatus
    public var source: SummaryStateSource

    public init(
        summary: MeetingSummary? = nil,
        status: SummaryStateStatus = .missing,
        source: SummaryStateSource = .none
    ) {
        self.summary = summary
        self.status = status
        self.source = source
    }

    public static var missing: SummaryState {
        SummaryState(summary: nil, status: .missing, source: .none)
    }

    public static var generating: SummaryState {
        SummaryState(summary: nil, status: .generating, source: .none)
    }

    public static func loaded(_ summary: MeetingSummary) -> SummaryState {
        SummaryState(summary: summary, status: .loaded, source: .loadedFromPersistence)
    }

    public static func generated(_ summary: MeetingSummary) -> SummaryState {
        SummaryState(summary: summary, status: .generated, source: .generatedInSession)
    }

    public static func failed(_ message: String) -> SummaryState {
        SummaryState(summary: nil, status: .failed(message), source: .none)
    }
}
