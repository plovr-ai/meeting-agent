import XCTest
@testable import MeetingAgentCore

final class TranscriptReplayTests: XCTestCase {
    func testReplaysFinalSegmentsInOrder() async {
        let replay = TranscriptFixtureReplay(segments: [
            TranscriptSegment(id: "one", text: "first", isFinal: true),
            TranscriptSegment(id: "partial", text: "partial", isFinal: false),
            TranscriptSegment(id: "two", text: "second", isFinal: true)
        ])
        var received: [String] = []

        await replay.run { segment in
            received.append(segment.id)
        }

        XCTAssertEqual(received, ["one", "two"])
    }

    func testCanSimulateFailureAfterSegment() async {
        let replay = TranscriptFixtureReplay(
            segments: [
                TranscriptSegment(id: "one", text: "first", isFinal: true),
                TranscriptSegment(id: "two", text: "second", isFinal: true)
            ],
            failureAfterSegmentID: "one"
        )
        var received: [String] = []

        await replay.run { segment in
            received.append(segment.id)
        }

        XCTAssertEqual(received, ["one"])
        XCTAssertEqual(replay.failureHealth, .failed("Replay stopped after one"))
    }
}
