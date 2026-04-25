import XCTest
@testable import MeetingAgentCore

final class TranscriptSegmentTests: XCTestCase {
    func testDefaultSpeakerRendersAsUserA() {
        let output = TranscriptFormatter.render([
            TranscriptSegment(text: "hello")
        ])

        XCTAssertEqual(output, "User A: hello")
    }

    func testSpeakerIdentifiersMapToStableLabels() {
        let output = TranscriptFormatter.render([
            TranscriptSegment(speaker: TranscriptSpeaker(identifier: "speaker-2"), text: "second speaks first"),
            TranscriptSegment(speaker: TranscriptSpeaker(identifier: "speaker-1"), text: "first speaks second"),
            TranscriptSegment(speaker: TranscriptSpeaker(identifier: "speaker-2"), text: "second again")
        ])

        XCTAssertEqual(output, """
        User A: second speaks first
        User B: first speaks second
        User A: second again
        """)
    }

    func testBlankSegmentsAreOmitted() {
        let output = TranscriptFormatter.render([
            TranscriptSegment(text: "  "),
            TranscriptSegment(text: "\nhello\n"),
            TranscriptSegment(text: "")
        ])

        XCTAssertEqual(output, "User A: hello")
    }
}
