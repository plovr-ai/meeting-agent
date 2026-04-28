import XCTest
@testable import MeetingAgentCore

final class TranscriptSegmentTests: XCTestCase {
    func testDefaultSpeakerRendersAsUserA() {
        let output = TranscriptFormatter.render([
            TranscriptSegment(text: "hello")
        ])

        XCTAssertEqual(output, """
        User A:
        hello
        """)
    }

    func testConsecutiveSegmentsFromSameSpeakerRenderAsOneTurn() {
        let output = TranscriptFormatter.render([
            TranscriptSegment(text: "first chunk"),
            TranscriptSegment(text: "second chunk")
        ])

        XCTAssertEqual(output, """
        User A:
        first chunk second chunk
        """)
    }

    func testConsecutiveSegmentsFromSameSpeakerDoNotSplitMidSentenceOnExport() {
        let speaker = TranscriptSpeaker(identifier: "deepgram-speaker-0")

        let output = TranscriptFormatter.render([
            TranscriptSegment(speaker: speaker, text: "Now what we can do is I'm gonna select"),
            TranscriptSegment(speaker: speaker, text: "German and you can hear what you sound like.")
        ])

        XCTAssertEqual(output, """
        User A:
        Now what we can do is I'm gonna select German and you can hear what you sound like.
        """)
    }

    func testSpeakerChangesStartNewTurnsAndReuseLabels() {
        let output = TranscriptFormatter.render([
            TranscriptSegment(speaker: TranscriptSpeaker(identifier: "speaker-2"), text: "second speaks first"),
            TranscriptSegment(speaker: TranscriptSpeaker(identifier: "speaker-1"), text: "first speaks second"),
            TranscriptSegment(speaker: TranscriptSpeaker(identifier: "speaker-2"), text: "second again")
        ])

        XCTAssertEqual(output, """
        User A:
        second speaks first

        User B:
        first speaks second

        User A:
        second again
        """)
    }

    func testBlankSegmentsAreOmitted() {
        let output = TranscriptFormatter.render([
            TranscriptSegment(text: "  "),
            TranscriptSegment(text: "\nhello\n"),
            TranscriptSegment(text: "")
        ])

        XCTAssertEqual(output, """
        User A:
        hello
        """)
    }

    func testReplacingCurrentSpeechResultUsesDefaultSpeakerFormat() {
        let output = TranscriptFormatter.render([
            TranscriptSegment(text: "current partial result")
        ])

        XCTAssertEqual(output, """
        User A:
        current partial result
        """)
    }
}
