import XCTest
@testable import MeetingAgentCore

@MainActor
final class LiveCaptionPipelineTests: XCTestCase {
    func testRealtimeCaptionSessionExposesOnlyCaptionOperations() throws {
        let source = try Self.sourceFile(named: "Sources/MeetingAgentCore/RealtimeCaptionSession.swift")

        XCTAssertFalse(source.contains("scheduleLegacyReplayBackfillTranslations"))
        XCTAssertFalse(source.contains("scheduleLivePendingTranslations"))
        XCTAssertFalse(source.contains("attachTranslationResults"))
        XCTAssertFalse(source.contains("TranslationResult"))
        XCTAssertTrue(source.contains("func apply("))
        XCTAssertTrue(source.contains("func flushCaptionsOnly("))
    }

    func testMeetingAgentViewModelDoesNotCallForbiddenRealtimeTranslationComponents() throws {
        let source = try Self.sourceFile(named: "Sources/MeetingAgentCore/MeetingAgentViewModel.swift")

        XCTAssertFalse(source.contains("scheduleLegacyReplayBackfillTranslations"))
        XCTAssertFalse(source.contains("scheduleLivePendingTranslations"))
        XCTAssertFalse(source.contains("attachTranslationResults"))
        XCTAssertFalse(source.contains("TranslationRuntime"))
        XCTAssertFalse(source.contains("TranslationExperiencePipeline"))
        XCTAssertFalse(source.contains("LiveTranslationScheduler"))
        XCTAssertFalse(source.contains("ReplayTranslationBackfillScheduler"))
    }

    func testLegacyTranslatedSegmentFieldsAreNotProjectedIntoLiveCaptions() async {
        let pipeline = LiveCaptionPipeline(
            sourceLocale: "en-US",
            targetLocale: "en-US",
            performanceEventLogger: nil
        )

        let snapshot = await pipeline.apply(TranscriptSegmentAccumulationResult(
            document: TranscriptDocument(segments: [
                TranscriptSegment(
                    id: "segment-1",
                    text: "We should confirm the launch owner today.",
                    language: "en-US",
                    isFinal: true,
                    translatedText: "我们应该确认上线负责人。",
                    translationTargetLocale: "zh-CN",
                    translationIsFinal: true
                )
            ]),
            changedSegmentIDs: ["segment-1"],
            plainTextReplacement: nil
        ))

        XCTAssertEqual(snapshot.turns.first?.originalText, "We should confirm the launch owner today.")
        XCTAssertNil(snapshot.turns.first?.translatedText)
        XCTAssertEqual(snapshot.translationHealth, .idle)
    }

    func testReplayBuildsCaptionTurnsFromFinalTranscriptSegments() async {
        let pipeline = LiveCaptionPipeline(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
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
        XCTAssertEqual(snapshot.translationHealth, .idle)
    }

    func testApplyUsesChangedInterimSegmentsWithoutReloadingFiles() async {
        let pipeline = LiveCaptionPipeline(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            performanceEventLogger: nil
        )
        let result = TranscriptSegmentAccumulationResult(
            document: TranscriptDocument(segments: [
                TranscriptSegment(
                    id: "deepgram-transcribe-stream-0.0",
                    speaker: TranscriptSpeaker(identifier: "deepgram-speaker-0"),
                    text: "Live interim",
                    language: "en-US",
                    sourceProvider: "deepgram-transcribe",
                    isFinal: false,
                    speechFinal: false
                )
            ]),
            changedSegmentIDs: ["deepgram-transcribe-stream-0.0"],
            plainTextReplacement: nil
        )

        let snapshot = await pipeline.apply(result)

        XCTAssertEqual(snapshot.turns.count, 1)
        XCTAssertEqual(snapshot.turns.first?.originalText, "Live interim")
        XCTAssertEqual(snapshot.turns.first?.displayState, .draft)
        XCTAssertEqual(snapshot.translationHealth, .idle)
    }

    func testApplySameIDInterimUpdatePreservesMergedTurn() async {
        let pipeline = LiveCaptionPipeline(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            performanceEventLogger: nil
        )
        let first = TranscriptSegment(
            id: "deepgram-transcribe-stream-0.0",
            speaker: TranscriptSpeaker(identifier: "deepgram-speaker-0"),
            text: "We should confirm",
            language: "en-US",
            sourceProvider: "deepgram-transcribe",
            isFinal: false,
            speechFinal: false
        )
        let second = TranscriptSegment(
            id: "deepgram-transcribe-stream-0.0",
            speaker: TranscriptSpeaker(identifier: "deepgram-speaker-0"),
            text: "We should confirm the owner.",
            language: "en-US",
            sourceProvider: "deepgram-transcribe",
            isFinal: true,
            speechFinal: true
        )

        _ = await pipeline.apply(TranscriptSegmentAccumulationResult(
            document: TranscriptDocument(segments: [first]),
            changedSegmentIDs: [first.id],
            plainTextReplacement: nil
        ))
        let snapshot = await pipeline.apply(TranscriptSegmentAccumulationResult(
            document: TranscriptDocument(segments: [second]),
            changedSegmentIDs: [second.id],
            plainTextReplacement: nil
        ))

        XCTAssertEqual(snapshot.turns.count, 1)
        XCTAssertEqual(snapshot.turns.first?.originalText, "We should confirm the owner.")
        XCTAssertEqual(snapshot.turns.first?.displayState, .sealed)
        XCTAssertEqual(snapshot.turns.first?.sourceSegmentIDs, [second.id])
        XCTAssertNil(snapshot.turns.first?.translatedText)
    }

    func testApplyRemovalAfterProvisionalMergeRestoresFinalTurn() async {
        let pipeline = LiveCaptionPipeline(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            performanceEventLogger: nil
        )
        let finalSegment = TranscriptSegment(
            id: "segment-1",
            speaker: TranscriptSpeaker(identifier: "speaker-1"),
            text: "Final opening.",
            language: "en-US",
            isFinal: true,
            speechFinal: true
        )
        let interimSegment = TranscriptSegment(
            id: "segment-2",
            speaker: TranscriptSpeaker(identifier: "speaker-1"),
            text: "draft tail",
            language: "en-US",
            isFinal: false,
            speechFinal: false
        )

        _ = await pipeline.apply(TranscriptSegmentAccumulationResult(
            document: TranscriptDocument(segments: [finalSegment, interimSegment]),
            changedSegmentIDs: [finalSegment.id, interimSegment.id],
            plainTextReplacement: nil
        ))
        let snapshot = await pipeline.apply(TranscriptSegmentAccumulationResult(
            document: TranscriptDocument(segments: [finalSegment]),
            changedSegmentIDs: [],
            plainTextReplacement: nil
        ))

        XCTAssertEqual(snapshot.turns.count, 1)
        XCTAssertEqual(snapshot.turns.first?.originalText, "Final opening.")
        XCTAssertEqual(snapshot.turns.first?.sourceSegmentIDs, [finalSegment.id])
        XCTAssertEqual(snapshot.turns.first?.displayState, .sealed)
    }

    func testReplayBuildsDraftTurnFromInterimTranscriptSegment() async {
        let pipeline = LiveCaptionPipeline(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            performanceEventLogger: nil
        )
        let document = TranscriptDocument(segments: [
            TranscriptSegment(
                id: "segment-1",
                speaker: TranscriptSpeaker(identifier: "speaker-1"),
                text: "Still speaking",
                language: "en-US",
                isFinal: false,
                speechFinal: false
            )
        ])

        let snapshot = pipeline.replayCaptionsOnly(document)

        XCTAssertEqual(snapshot.turns.count, 1)
        XCTAssertEqual(snapshot.turns.first?.originalText, "Still speaking")
        XCTAssertEqual(snapshot.turns.first?.displayState, .draft)
        XCTAssertEqual(snapshot.captionHealth, .live)
        XCTAssertEqual(snapshot.translationHealth, .idle)
    }

    func testFlushSealsOpenCaptionChunk() async {
        let pipeline = LiveCaptionPipeline(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            performanceEventLogger: nil
        )
        _ = await pipeline.apply(TranscriptSegmentAccumulationResult(
            document: TranscriptDocument(segments: [
                TranscriptSegment(
                    id: "segment-1",
                    speaker: TranscriptSpeaker(identifier: "speaker-1"),
                    text: "We should finish this thought",
                    language: "en-US",
                    isFinal: false,
                    speechFinal: false
                )
            ]),
            changedSegmentIDs: ["segment-1"],
            plainTextReplacement: nil
        ))

        let snapshot = pipeline.flushCaptionsOnly(reason: .manualStop)

        XCTAssertEqual(snapshot.turns.first?.displayState, .sealed)
        XCTAssertEqual(snapshot.turns.first?.boundaryStrength, .hard)
        XCTAssertEqual(snapshot.turns.first?.boundaryReason, .manualStop)
        XCTAssertEqual(snapshot.translationHealth, .idle)
    }

    func testPlainTextReplacementFailsCaptionProjectionWithoutTranslationWork() async {
        let pipeline = LiveCaptionPipeline(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            performanceEventLogger: nil
        )

        let snapshot = await pipeline.apply(TranscriptSegmentAccumulationResult(
            document: TranscriptDocument(segments: []),
            changedSegmentIDs: [],
            plainTextReplacement: "fallback transcript"
        ))

        XCTAssertTrue(snapshot.turns.isEmpty)
        XCTAssertEqual(snapshot.captionHealth, .failed("Plain text transcript replacements are not supported by live captions."))
        XCTAssertEqual(snapshot.translationHealth, .idle)
    }

    private static func sourceFile(named relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
