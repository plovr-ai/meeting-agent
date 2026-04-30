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
        XCTAssertEqual(accumulator.currentDocument.segments.map(\.id), ["active"])
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

    func testTranslationPatchUpdatesMatchingSegment() {
        var accumulator = TranscriptSegmentAccumulator(document: TranscriptDocument(segments: [
            TranscriptSegment(id: "segment-1", text: "Confirm owner."),
            TranscriptSegment(id: "segment-2", text: "Review timeline.")
        ]))

        let result = accumulator.apply(.translationPatch(
            segmentID: "segment-2",
            text: "复查时间线。",
            targetLocale: "zh-CN",
            isFinal: true
        ))

        XCTAssertEqual(result.changedSegmentIDs, ["segment-2"])
        XCTAssertNil(result.document.segments[0].translatedText)
        XCTAssertEqual(result.document.segments[1].translatedText, "复查时间线。")
        XCTAssertEqual(result.document.segments[1].translationTargetLocale, "zh-CN")
        XCTAssertEqual(result.document.segments[1].translationIsFinal, true)
    }

    func testTranslationPatchMissingSegmentLeavesDocumentUnchanged() {
        let document = TranscriptDocument(segments: [
            TranscriptSegment(id: "segment-1", text: "Confirm owner.")
        ])
        var accumulator = TranscriptSegmentAccumulator(document: document)

        let result = accumulator.apply(.translationPatch(
            segmentID: "missing",
            text: "确认负责人。",
            targetLocale: "zh-CN",
            isFinal: false
        ))

        XCTAssertEqual(result.changedSegmentIDs, [])
        XCTAssertEqual(result.document, document)
    }

    func testTranslationPatchNormalizesInputs() {
        var accumulator = TranscriptSegmentAccumulator(document: TranscriptDocument(segments: [
            TranscriptSegment(id: "segment-1", text: "Confirm owner.")
        ]))

        let result = accumulator.apply(.translationPatch(
            segmentID: " segment-1 ",
            text: " 确认负责人。 ",
            targetLocale: " zh-CN ",
            isFinal: false
        ))

        XCTAssertEqual(result.changedSegmentIDs, ["segment-1"])
        XCTAssertEqual(result.document.segments.first?.translatedText, "确认负责人。")
        XCTAssertEqual(result.document.segments.first?.translationTargetLocale, "zh-CN")
    }

    func testFileBackedTranscriptUpdateSinkPersistsUpdates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-sink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("transcript.txt")
        let sink = try FileBackedTranscriptUpdateSink(transcriptURL: transcriptURL)

        sink.receive(.replaceAll([
            TranscriptSegment(id: "segment-1", text: "hello", language: "en-US", isFinal: true)
        ]))
        try sink.persist(.upsert(TranscriptSegment(id: "segment-2", text: "world", language: "en-US", isFinal: true)))

        let document = try TranscriptFileWriter.readDocument(
            from: transcriptURL.deletingPathExtension().appendingPathExtension("json")
        )
        XCTAssertEqual(document.segments.map(\.id), ["segment-1", "segment-2"])
        XCTAssertEqual(document.segments.map(\.text), ["hello", "world"])
        XCTAssertEqual(try String(contentsOf: transcriptURL, encoding: .utf8), "User A:\nhello world\n")
    }
}
