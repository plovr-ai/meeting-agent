import XCTest
@testable import MeetingAgentCore

final class TranslationRuntimeTests: XCTestCase {
    func testHydrateReturnsStableResultsFromPersistenceRecords() {
        let meetingID = UUID(uuidString: "00000000-0000-0000-0000-000000000111")!
        let lane = TranslationLaneID(speaker: .default, sourceLocale: "en-US", targetLocale: "zh-CN")
        let record = TranslationResultPersistenceRecord(
            meetingID: meetingID,
            resultID: "stable-1",
            sourceID: "block-1",
            laneID: lane,
            sourceSegmentIDs: ["segment-1"],
            sourceTextHash: "hash",
            sourceText: "We approve the rollout.",
            translatedText: "我们批准上线。",
            displayState: .stableFinal,
            boundaryReason: .providerHardBoundary,
            providerID: "test",
            createdAt: Date(timeIntervalSince1970: 1),
            finalizedAt: Date(timeIntervalSince1970: 2)
        )

        var runtime = TranslationRuntime()
        let hydrated = runtime.hydrate(records: [record])

        XCTAssertEqual(hydrated.map(\.id), ["stable-1"])
        XCTAssertEqual(hydrated.first?.displayState, .stableFinal)
        XCTAssertEqual(hydrated.first?.sourceSegmentIDs, ["segment-1"])
    }

    func testApplyWithoutStartedContextReturnsIdleSnapshot() async {
        var runtime = TranslationRuntime()

        let snapshot = await runtime.apply(
            document: TranscriptDocument(segments: [
                TranscriptSegment(id: "segment-1", text: "We approve the rollout today", language: "en-US", isFinal: false)
            ]),
            generation: 1,
            now: Date(timeIntervalSince1970: 1)
        )

        XCTAssertTrue(snapshot.visibleResults.isEmpty)
        XCTAssertTrue(snapshot.droppedResults.isEmpty)
        XCTAssertEqual(snapshot.state, .idle)
    }
}
