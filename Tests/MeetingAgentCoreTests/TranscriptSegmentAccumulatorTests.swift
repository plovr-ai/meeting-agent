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

    func testUpsertPreservesAdjacentDeepgramFinalTextWhenTimingDoesNotOverlap() {
        var accumulator = TranscriptSegmentAccumulator()

        _ = accumulator.apply(.upsert(deepgramSegment(
            id: "deepgram-transcribe-stream-44.34",
            start: 44.34,
            end: 46.9,
            text: "inside Microsoft Teams, which are outlined here, to be able to take",
            isFinal: true
        )))
        let result = accumulator.apply(.upsert(deepgramSegment(
            id: "deepgram-transcribe-stream-47.52",
            start: 47.52,
            end: 52.08,
            text: "to be able to take advantage of these public preview features.",
            isFinal: true
        )))

        XCTAssertEqual(result.document.segments.map(\.text), [
            "inside Microsoft Teams, which are outlined here, to be able to take",
            "to be able to take advantage of these public preview features."
        ])
    }

    func testDeepgramFinalReplacementUsesTimingNotTextSimilarity() {
        var accumulator = TranscriptSegmentAccumulator()

        _ = accumulator.apply(.upsert(deepgramSegment(
            id: "deepgram-transcribe-stream-10.0",
            start: 10.0,
            end: 11.0,
            text: "old phrase",
            isFinal: true
        )))
        let result = accumulator.apply(.upsert(deepgramSegment(
            id: "deepgram-transcribe-stream-10.02",
            start: 10.02,
            end: 11.02,
            text: "corrected phrase",
            isFinal: true
        )))

        XCTAssertEqual(result.document.segments.map(\.text), ["corrected phrase"])
    }

    func testUpsertTrimsInterimCoveredBySurroundingFinalSegments() {
        var accumulator = TranscriptSegmentAccumulator()

        _ = accumulator.apply(.upsert(deepgramSegment(
            id: "deepgram-transcribe-stream-44.34",
            start: 44.34,
            end: 46.9,
            text: "inside Microsoft Teams, are outlined here,",
            isFinal: true
        )))
        _ = accumulator.apply(.upsert(deepgramSegment(
            id: "deepgram-transcribe-stream-44.5",
            start: 44.5,
            end: 48.42,
            text: "inside Microsoft Teams, which are outlined here, to be able to take",
            isFinal: false
        )))
        let result = accumulator.apply(.upsert(deepgramSegment(
            id: "deepgram-transcribe-stream-47.52",
            start: 47.52,
            end: 52.08,
            text: "to be able to take advantage of these public preview features.",
            isFinal: true
        )))

        XCTAssertEqual(result.document.segments.map(\.id), [
            "deepgram-transcribe-stream-44.34",
            "deepgram-transcribe-stream-47.52"
        ])
        XCTAssertEqual(result.document.segments.map(\.text).joined(separator: " "), """
        inside Microsoft Teams, are outlined here, to be able to take advantage of these public preview features.
        """.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testUpsertTrimsInterimSuffixCoveredByFollowingFinalSegment() {
        var accumulator = TranscriptSegmentAccumulator()

        _ = accumulator.apply(.upsert(deepgramSegment(
            id: "deepgram-transcribe-stream-40.0",
            start: 40,
            end: 41,
            text: "introductory context",
            isFinal: true
        )))
        _ = accumulator.apply(.upsert(deepgramSegment(
            id: "deepgram-transcribe-stream-42.0",
            start: 42,
            end: 48,
            text: "please review to be able to take",
            isFinal: false
        )))
        let result = accumulator.apply(.upsert(deepgramSegment(
            id: "deepgram-transcribe-stream-47.52",
            start: 47.52,
            end: 52.08,
            text: "to be able to take advantage of these public preview features.",
            isFinal: true
        )))

        XCTAssertEqual(result.document.segments.map(\.id), [
            "deepgram-transcribe-stream-40.0",
            "deepgram-transcribe-stream-42.0",
            "deepgram-transcribe-stream-47.52"
        ])
        XCTAssertEqual(result.document.segments.map(\.text), [
            "introductory context",
            "please review",
            "to be able to take advantage of these public preview features."
        ])
    }

    func testIssue135MeetingShapeDoesNotRepeatAbleToTake() {
        var accumulator = TranscriptSegmentAccumulator()

        for segment in [
            deepgramSegment(
                id: "deepgram-transcribe-stream-39.9",
                start: 39.9,
                end: 44.1,
                text: "below, as an end user, you have to take some steps",
                isFinal: true
            ),
            deepgramSegment(
                id: "deepgram-transcribe-stream-44.34",
                start: 44.34,
                end: 46.9,
                text: "inside Microsoft Teams, are outlined here,",
                isFinal: true
            ),
            deepgramSegment(
                id: "deepgram-transcribe-stream-44.5",
                start: 44.5,
                end: 48.42,
                text: "inside Microsoft Teams, which are outlined here, to be able to take",
                isFinal: false
            ),
            deepgramSegment(
                id: "deepgram-transcribe-stream-47.52",
                start: 47.52,
                end: 52.08,
                text: "to be able to take advantage of these public preview features. So inside the new Teams client,",
                isFinal: true
            )
        ] {
            _ = accumulator.apply(.upsert(segment))
        }

        let renderedText = accumulator.currentDocument.segments.map(\.text).joined(separator: " ")
        XCTAssertFalse(renderedText.contains("to be able to take to be able to take"))
        XCTAssertEqual(
            renderedText,
            "below, as an end user, you have to take some steps inside Microsoft Teams, are outlined here, to be able to take advantage of these public preview features. So inside the new Teams client,"
        )
    }

    func testLegacyTranscriptUpdateFileSinkPersistsUpdates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-sink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appendingPathComponent("transcript.txt")
        let sink = try LegacyTranscriptUpdateFileSink(transcriptURL: transcriptURL)

        sink.receive(.replaceAll([
            TranscriptSegment(id: "segment-1", text: "hello", language: "en-US", isFinal: true)
        ]))
        try sink.persist(.upsert(TranscriptSegment(id: "segment-2", text: "world", language: "en-US", isFinal: true)))

        let document = try LegacyTranscriptBridge.readDocument(
            from: transcriptURL.deletingPathExtension().appendingPathExtension("json")
        )
        XCTAssertEqual(document.segments.map(\.id), ["segment-1", "segment-2"])
        XCTAssertEqual(document.segments.map(\.text), ["hello", "world"])
        XCTAssertEqual(try String(contentsOf: transcriptURL, encoding: .utf8), "User A:\nhello world\n")
    }

    private func deepgramSegment(
        id: String,
        speaker: String = "deepgram-speaker-0",
        start: Double,
        end: Double,
        text: String,
        isFinal: Bool
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            speaker: TranscriptSpeaker(identifier: speaker),
            startTimeSeconds: start,
            endTimeSeconds: end,
            text: text,
            sourceProvider: SpeechTranscriptionConfiguration.defaultDeepgramTranscriptionProviderID,
            isFinal: isFinal,
            speechFinal: false,
            timingSource: .precise
        )
    }
}
