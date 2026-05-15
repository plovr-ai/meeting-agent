import XCTest
@testable import MeetingAgentCore

final class TranscriptSpeakerLabelerTests: XCTestCase {
    func testAssignsStableLabelsForProviderSpeakerIDs() {
        let segments = TranscriptSpeakerLabeler.assignSpeakerLabels(to: [
            TranscriptSegment(
                id: "segment-1",
                speaker: TranscriptSpeaker(identifier: "deepgram-speaker-2"),
                text: "hello"
            ),
            TranscriptSegment(
                id: "segment-2",
                speaker: TranscriptSpeaker(identifier: "deepgram-speaker-7"),
                text: "hi"
            ),
            TranscriptSegment(
                id: "segment-3",
                speaker: TranscriptSpeaker(identifier: "deepgram-speaker-2"),
                text: "again"
            )
        ])

        XCTAssertEqual(segments.map(\.speakerID), [
            "deepgram-speaker-2",
            "deepgram-speaker-7",
            "deepgram-speaker-2"
        ])
        XCTAssertEqual(segments.map(\.speakerLabel), ["User A", "User B", "User A"])
    }

    func testGeneratesSpeakerIDsWhenProviderDoesNotSupplyThem() {
        let firstSpeaker = TranscriptSpeaker(identifier: nil, label: "Host")
        let secondSpeaker = TranscriptSpeaker(identifier: nil, label: "Guest")

        let segments = TranscriptSpeakerLabeler.assignSpeakerLabels(to: [
            TranscriptSegment(id: "segment-1", speaker: firstSpeaker, text: "hello"),
            TranscriptSegment(id: "segment-2", speaker: secondSpeaker, text: "hi"),
            TranscriptSegment(id: "segment-3", speaker: firstSpeaker, text: "again")
        ])

        XCTAssertEqual(segments.map(\.speakerID), ["speaker-1", "speaker-2", "speaker-1"])
        XCTAssertEqual(segments.map(\.speakerLabel), ["Host", "Guest", "Host"])
    }
}
