import XCTest
@testable import MeetingAgentCore

final class CaptionDocumentTests: XCTestCase {
    func testCaptionDocumentDefaultsToVersionTwo() {
        let document = CaptionDocument()

        XCTAssertEqual(document.version, 2)
        XCTAssertTrue(document.turns.isEmpty)
        XCTAssertTrue(document.speakers.isEmpty)
        XCTAssertNil(document.provider)
        XCTAssertNil(document.finalizedAt)
    }

    func testCaptionTurnNormalizesTextSectionsAndSourceIDs() {
        let turn = CaptionTurn(
            id: "turn-1",
            speakerID: " speaker-1 ",
            speakerLabel: " Alice ",
            startTimeSeconds: 1.0,
            endTimeSeconds: 2.0,
            sections: [
                CaptionSection(
                    id: "section-1",
                    text: " 你好。 ",
                    utteranceIDs: ["utt-2", "utt-1", "utt-1"],
                    startTimeSeconds: 1.0,
                    endTimeSeconds: 1.5
                ),
                CaptionSection(
                    id: "section-2",
                    text: "\n继续说\n",
                    utteranceIDs: ["utt-3"],
                    startTimeSeconds: 1.6,
                    endTimeSeconds: 2.0
                )
            ],
            state: .draft,
            source: CaptionTurnSource(
                providerID: "deepgram",
                streamID: "stream-1",
                resultIDs: ["result-2", "result-1", "result-2"],
                utteranceIDs: ["utt-2", "utt-1", "utt-1"]
            ),
            createdAt: Date(timeIntervalSince1970: 1_777_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_777_000_001)
        )

        XCTAssertEqual(turn.speakerID, "speaker-1")
        XCTAssertEqual(turn.speakerLabel, "Alice")
        XCTAssertEqual(turn.text, "你好。\n继续说")
        XCTAssertEqual(turn.source.resultIDs, ["result-1", "result-2"])
        XCTAssertEqual(turn.source.utteranceIDs, ["utt-1", "utt-2"])
    }

    func testCaptionDocumentCodableRoundTripPreservesMetadata() throws {
        let document = CaptionDocument(
            speakers: [
                CaptionSpeaker(id: "speaker-0", label: "Alice", providerSpeakerID: "0")
            ],
            turns: [
                CaptionTurn(
                    id: "turn-1",
                    speakerID: "speaker-0",
                    speakerLabel: "Alice",
                    startTimeSeconds: 0.2,
                    endTimeSeconds: 1.4,
                    sections: [
                        CaptionSection(
                            id: "section-1",
                            text: "hello.",
                            utteranceIDs: ["utt-1"],
                            startTimeSeconds: 0.2,
                            endTimeSeconds: 1.4
                        )
                    ],
                    state: .final,
                    source: CaptionTurnSource(providerID: "deepgram", streamID: "stream-1", resultIDs: ["r1"], utteranceIDs: ["utt-1"]),
                    createdAt: Date(timeIntervalSince1970: 1_777_000_000),
                    updatedAt: Date(timeIntervalSince1970: 1_777_000_001)
                )
            ],
            provider: CaptionProviderInfo(id: "deepgram", model: "nova-3", locale: "zh-CN"),
            createdAt: Date(timeIntervalSince1970: 1_777_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_777_000_001),
            finalizedAt: Date(timeIntervalSince1970: 1_777_000_002)
        )

        let data = try JSONEncoder.meetingAgent.encode(document)
        let decoded = try JSONDecoder.meetingAgent.decode(CaptionDocument.self, from: data)

        XCTAssertEqual(decoded, document)
    }

    func testCaptionTurnCanProjectToTranscriptSegmentForLegacyConsumers() {
        let turn = CaptionTurn(
            id: "turn-1",
            speakerID: "speaker-1",
            speakerLabel: "Alice",
            startTimeSeconds: 1.0,
            endTimeSeconds: 2.0,
            sections: [
                CaptionSection(id: "section-1", text: "第一句。", utteranceIDs: ["utt-1"], startTimeSeconds: 1.0, endTimeSeconds: 1.5),
                CaptionSection(id: "section-2", text: "第二句。", utteranceIDs: ["utt-2"], startTimeSeconds: 1.6, endTimeSeconds: 2.0)
            ],
            state: .final,
            source: CaptionTurnSource(providerID: "deepgram", streamID: "stream-1", resultIDs: ["r1"], utteranceIDs: ["utt-1", "utt-2"]),
            createdAt: Date(timeIntervalSince1970: 1_777_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_777_000_001)
        )

        let segment = turn.transcriptSegment

        XCTAssertEqual(segment.id, "turn-1")
        XCTAssertEqual(segment.speakerID, "speaker-1")
        XCTAssertEqual(segment.speakerLabel, "Alice")
        XCTAssertEqual(segment.text, "第一句。\n第二句。")
        XCTAssertEqual(segment.sourceProvider, "deepgram")
        XCTAssertTrue(segment.isFinal)
        XCTAssertEqual(segment.timingSource, .precise)
    }
}
