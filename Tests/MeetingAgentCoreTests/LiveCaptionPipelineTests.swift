import XCTest
@testable import MeetingAgentCore

@MainActor
final class LiveCaptionPipelineTests: XCTestCase {
    func testReplayBuildsCaptionTurnsFromFinalTranscriptSegments() async {
        let pipeline = LiveCaptionPipeline(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            translationProvider: nil,
            performanceEventLogger: nil
        )
        let document = TranscriptDocument(segments: [
            TranscriptSegment(
                id: "segment-1",
                speaker: TranscriptSpeaker(identifier: "speaker-1"),
                text: "Hello team.",
                language: "en-US",
                isFinal: true,
                speechFinal: true
            )
        ])

        let snapshot = await pipeline.replay(document)

        XCTAssertEqual(snapshot.turns.count, 1)
        XCTAssertEqual(snapshot.turns.first?.originalText, "Hello team.")
        XCTAssertEqual(snapshot.turns.first?.sourceSegmentIDs, ["segment-1"])
        XCTAssertEqual(snapshot.turns.first?.displayState, .sealed)
        XCTAssertEqual(snapshot.turns.first?.boundaryStrength, .hard)
        XCTAssertEqual(snapshot.captionHealth, .live)
    }

    func testApplyReplaysAccumulationDocument() async {
        let pipeline = LiveCaptionPipeline(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            translationProvider: nil,
            performanceEventLogger: nil
        )
        let result = TranscriptSegmentAccumulationResult(
            document: TranscriptDocument(segments: [
                TranscriptSegment(
                    id: "segment-1",
                    text: "We are aligned.",
                    language: "en-US",
                    isFinal: true,
                    speechFinal: true
                )
            ]),
            changedSegmentIDs: ["segment-1"],
            plainTextReplacement: nil
        )

        let snapshot = await pipeline.apply(result)

        XCTAssertEqual(snapshot.turns.map(\.originalText), ["We are aligned."])
        XCTAssertEqual(snapshot.captionHealth, .live)
        XCTAssertEqual(snapshot.translationHealth, .idle)
    }

    func testReplayBuildsDraftTurnFromInterimTranscriptSegment() async {
        let pipeline = LiveCaptionPipeline(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            translationProvider: nil,
            performanceEventLogger: nil
        )
        let document = TranscriptDocument(segments: [
            TranscriptSegment(
                id: "segment-1",
                text: "Still speaking",
                language: "en-US",
                isFinal: false,
                speechFinal: false
            )
        ])

        let snapshot = await pipeline.replay(document)

        XCTAssertEqual(snapshot.turns.count, 1)
        XCTAssertEqual(snapshot.turns.first?.originalText, "Still speaking")
        XCTAssertEqual(snapshot.turns.first?.sourceSegmentIDs, ["segment-1"])
        XCTAssertEqual(snapshot.turns.first?.displayState, .draft)
        XCTAssertEqual(snapshot.turns.first?.chunkState, .draft)
        XCTAssertEqual(snapshot.captionHealth, .live)
    }

    func testReplayHydratesCachedTranslationFromFinalTranscriptSegment() async {
        let pipeline = LiveCaptionPipeline(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            translationProvider: nil,
            performanceEventLogger: nil
        )
        let document = TranscriptDocument(segments: [
            TranscriptSegment(
                id: "segment-1",
                text: "Confirm the launch owner.",
                language: "en-US",
                isFinal: true,
                speechFinal: true,
                translatedText: "确认上线负责人。",
                translationTargetLocale: "zh-CN",
                translationIsFinal: true
            )
        ])

        let snapshot = await pipeline.replay(document)

        XCTAssertEqual(snapshot.turns.count, 1)
        XCTAssertEqual(snapshot.turns.first?.translatedText, "确认上线负责人。")
        XCTAssertEqual(snapshot.turns.first?.translationHealth, .live)
        XCTAssertEqual(snapshot.turns.first?.translationState, .final)
    }

    func testFlushSealsOpenCaptionChunk() async {
        let pipeline = LiveCaptionPipeline(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            translationProvider: nil,
            performanceEventLogger: nil
        )
        _ = await pipeline.replay(TranscriptDocument(segments: [
            TranscriptSegment(
                id: "segment-1",
                text: "Open caption draft",
                language: "en-US",
                isFinal: true,
                speechFinal: false
            )
        ]))

        let snapshot = await pipeline.flush(reason: .manualStop)

        XCTAssertEqual(snapshot.turns.count, 1)
        XCTAssertEqual(snapshot.turns.first?.displayState, .sealed)
        XCTAssertEqual(snapshot.turns.first?.boundaryReason, .manualStop)
        XCTAssertEqual(snapshot.turns.first?.boundaryStrength, .hard)
    }
}
