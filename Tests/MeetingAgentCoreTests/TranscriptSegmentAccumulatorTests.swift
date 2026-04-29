import XCTest
@testable import MeetingAgentCore

final class TranscriptSegmentAccumulatorTests: XCTestCase {
    func testUpsertReplacesInterimWithFinalSameID() {
        var accumulator = TranscriptSegmentAccumulator()

        let first = accumulator.apply(.upsert(TranscriptSegment(id: "active", text: "hello", isFinal: false)))
        let second = accumulator.apply(.upsert(TranscriptSegment(id: "active", text: "hello world", isFinal: true)))

        XCTAssertEqual(first.document.segments.map(\.text), ["hello"])
        XCTAssertEqual(second.document.segments.map(\.id), ["active"])
        XCTAssertEqual(second.document.segments.map(\.text), ["hello world"])
        XCTAssertEqual(second.document.segments.map(\.isFinal), [true])
    }

    func testUpsertFinalPrunesShiftedDeepgramInterim() {
        var accumulator = TranscriptSegmentAccumulator()

        _ = accumulator.apply(.upsert(TranscriptSegment(
            id: "deepgram-transcribe-stream-7.59",
            startTimeSeconds: 7.59,
            endTimeSeconds: 11.67,
            text: "to give it a like as it really does help the channel",
            sourceProvider: "deepgram-transcribe",
            isFinal: false,
            timingSource: .precise
        )))
        let result = accumulator.apply(.upsert(TranscriptSegment(
            id: "deepgram-transcribe-stream-7.51",
            startTimeSeconds: 7.51,
            endTimeSeconds: 11.75,
            text: "to give it a like as it really does help the channel",
            sourceProvider: "deepgram-transcribe",
            isFinal: true,
            timingSource: .precise
        )))

        XCTAssertEqual(result.document.segments.map(\.id), ["deepgram-transcribe-stream-7.51"])
        XCTAssertEqual(result.document.segments.map(\.isFinal), [true])
    }

    func testReplaceAllReplacesCurrentDocument() {
        var accumulator = TranscriptSegmentAccumulator()
        _ = accumulator.apply(.upsert(TranscriptSegment(id: "old", text: "old text")))

        let result = accumulator.apply(.replaceAll([
            TranscriptSegment(id: "new-1", text: "first"),
            TranscriptSegment(id: "new-2", text: "second")
        ]))

        XCTAssertEqual(result.document.segments.map(\.id), ["new-1", "new-2"])
        XCTAssertEqual(result.document.segments.map(\.text), ["first", "second"])
    }

    func testPreservesTranslationWhenSameTextUpdatesSameSegment() {
        var accumulator = TranscriptSegmentAccumulator(document: TranscriptDocument(segments: [
            TranscriptSegment(
                id: "segment-1",
                text: "Confirm owner.",
                translatedText: "确认负责人。",
                translationTargetLocale: "zh-CN",
                translationIsFinal: true
            )
        ]))

        let result = accumulator.apply(.upsert(TranscriptSegment(id: "segment-1", text: "Confirm owner.")))

        XCTAssertEqual(result.document.segments.first?.translatedText, "确认负责人。")
        XCTAssertEqual(result.document.segments.first?.translationTargetLocale, "zh-CN")
        XCTAssertEqual(result.document.segments.first?.translationIsFinal, true)
    }
}
