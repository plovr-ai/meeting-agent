import XCTest
@testable import MeetingAgentCore

final class TranscriptSegmentTests: XCTestCase {
    func testTranscriptSpeakerAndDocumentInitializersNormalizeDefaults() {
        let speaker = TranscriptSpeaker(identifier: " speaker-1 ", label: " Alice ")
        let document = TranscriptDocument(segments: [
            TranscriptSegment(speaker: speaker, text: "hello")
        ])

        XCTAssertEqual(speaker.identifier, "speaker-1")
        XCTAssertEqual(speaker.label, "Alice")
        XCTAssertEqual(document.version, 1)
        XCTAssertEqual(document.segments.first?.speaker, speaker)
    }

    func testTranscriptDocumentCodableRoundTripPreservesSegmentMetadata() throws {
        let document = TranscriptDocument(version: 2, segments: [
            TranscriptSegment(
                id: "segment-1",
                speaker: TranscriptSpeaker(identifier: "speaker-1", label: "Alice"),
                startTimeSeconds: 1.25,
                endTimeSeconds: 2.5,
                text: "hello",
                language: "en-US",
                sourceProvider: "deepgram-transcribe",
                isFinal: false,
                speechFinal: true,
                confidence: 0.92,
                createdAt: Date(timeIntervalSince1970: 1_777_000_000),
                timingSource: .precise
            )
        ])

        let data = try JSONEncoder.meetingAgent.encode(document)
        let decoded = try JSONDecoder.meetingAgent.decode(TranscriptDocument.self, from: data)

        XCTAssertEqual(decoded, document)
    }

    func testLegacyTranscriptSegmentDecodingAppliesDefaults() throws {
        let json = """
        {
          "id": "segment-1",
          "text": "hello"
        }
        """

        let decoded = try JSONDecoder.meetingAgent.decode(TranscriptSegment.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.sourceProvider, "unknown")
        XCTAssertTrue(decoded.isFinal)
        XCTAssertFalse(decoded.speechFinal)
        XCTAssertEqual(decoded.timingSource, .unavailable)
    }

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

    func testSpeakerLabelMapperAllocatesLabelsWithoutPreRegisteredSpeakers() {
        var mapper = SpeakerLabelMapper()

        XCTAssertEqual(mapper.label(for: TranscriptSpeaker(identifier: "speaker-1")), "User A")
        XCTAssertEqual(mapper.label(for: TranscriptSpeaker(identifier: "speaker-1")), "User A")
        XCTAssertEqual(mapper.label(for: TranscriptSpeaker(identifier: "speaker-2")), "User B")
    }
}
