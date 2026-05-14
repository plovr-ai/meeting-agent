import XCTest
@testable import MeetingAgentCore

final class MeetingSessionStateTests: XCTestCase {
    func testTranscriptStateProjectsConsumptionViewFromCaptionDocument() {
        let meetingID = UUID()
        let document = CaptionDocument(
            turns: [
                CaptionTurn(
                    id: "turn-1",
                    speakerID: "speaker-1",
                    speakerLabel: "Allan",
                    sections: [CaptionSection(id: "section-1", text: "Final text", utteranceIDs: ["utt-1"])],
                    state: .final,
                    source: CaptionTurnSource(providerID: "deepgram", utteranceIDs: ["utt-1"])
                )
            ],
            provider: CaptionProviderInfo(id: "deepgram", locale: "en-US")
        )

        let state = TranscriptState(meetingID: meetingID, captionDocument: document, source: .hydratedFromPersistence)

        XCTAssertEqual(state.consumptionView.finalTurns.map(\.text), ["Final text"])
        XCTAssertEqual(state.visibleTurns.map(\.originalText), ["Final text"])
        XCTAssertEqual(state.source, .hydratedFromPersistence)
    }

    func testSummaryStateTracksLoadedSummary() {
        let summary = MeetingSummary(
            overview: "Loaded summary",
            keyTopics: [],
            decisions: [],
            actionItems: [],
            openQuestions: [],
            risks: [],
            followUps: [],
            language: "en-US",
            sourceSegmentIDs: ["turn-1"],
            generatedAt: Date(timeIntervalSince1970: 1),
            provider: "test",
            status: .succeeded,
            failureReason: nil
        )

        let state = SummaryState.loaded(summary)

        XCTAssertEqual(state.summary, summary)
        XCTAssertEqual(state.status, .loaded)
        XCTAssertEqual(state.source, .loadedFromPersistence)
    }
}
