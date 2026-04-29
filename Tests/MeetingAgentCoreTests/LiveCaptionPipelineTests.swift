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
        XCTAssertEqual(snapshot.translationHealth, .pending)
    }

    func testApplyUsesChangedInterimSegmentsWithoutReloadingFiles() async {
        let pipeline = LiveCaptionPipeline(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            translationProvider: nil,
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
    }

    func testApplySameIDInterimUpdatePreservesMergedTurn() async {
        let pipeline = LiveCaptionPipeline(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            translationProvider: nil,
            performanceEventLogger: nil
        )
        let speaker = TranscriptSpeaker(identifier: "deepgram-speaker-0")
        let finalSegment = TranscriptSegment(
            id: "final-1",
            speaker: speaker,
            text: "select German",
            language: "en-US",
            sourceProvider: "deepgram-transcribe",
            isFinal: true,
            speechFinal: true
        )
        _ = await pipeline.apply(TranscriptSegmentAccumulationResult(
            document: TranscriptDocument(segments: [finalSegment]),
            changedSegmentIDs: ["final-1"],
            plainTextReplacement: nil
        ))

        let interimSegment = TranscriptSegment(
            id: "interim-1",
            speaker: speaker,
            text: "select German and hear",
            language: "en-US",
            sourceProvider: "deepgram-transcribe",
            isFinal: false,
            speechFinal: false
        )
        let firstInterimSnapshot = await pipeline.apply(TranscriptSegmentAccumulationResult(
            document: TranscriptDocument(segments: [finalSegment, interimSegment]),
            changedSegmentIDs: ["interim-1"],
            plainTextReplacement: nil
        ))

        XCTAssertEqual(firstInterimSnapshot.turns.count, 1)
        XCTAssertEqual(firstInterimSnapshot.turns.first?.originalText, "select German and hear")
        XCTAssertEqual(firstInterimSnapshot.turns.first?.displayState, .draft)

        let updatedInterimSegment = TranscriptSegment(
            id: "interim-1",
            speaker: speaker,
            text: "select German and hear the customer",
            language: "en-US",
            sourceProvider: "deepgram-transcribe",
            isFinal: false,
            speechFinal: false
        )
        let updatedSnapshot = await pipeline.apply(TranscriptSegmentAccumulationResult(
            document: TranscriptDocument(segments: [finalSegment, updatedInterimSegment]),
            changedSegmentIDs: ["interim-1"],
            plainTextReplacement: nil
        ))

        XCTAssertEqual(updatedSnapshot.turns.count, 1)
        XCTAssertEqual(updatedSnapshot.turns.first?.originalText, "select German and hear the customer")
        XCTAssertEqual(updatedSnapshot.turns.first?.sourceSegmentIDs, ["final-1", "interim-1"])
        XCTAssertEqual(updatedSnapshot.turns.first?.displayState, .draft)
    }

    func testApplySameIDInterimUpdateDoesNotHydrateSingleSegmentTranslationOntoMergedTurn() async {
        let pipeline = LiveCaptionPipeline(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            translationProvider: nil,
            performanceEventLogger: nil
        )
        let speaker = TranscriptSpeaker(identifier: "deepgram-speaker-0")
        let finalSegment = TranscriptSegment(
            id: "final-1",
            speaker: speaker,
            text: "select German",
            language: "en-US",
            sourceProvider: "deepgram-transcribe",
            isFinal: true,
            speechFinal: true
        )
        _ = await pipeline.apply(TranscriptSegmentAccumulationResult(
            document: TranscriptDocument(segments: [finalSegment]),
            changedSegmentIDs: ["final-1"],
            plainTextReplacement: nil
        ))

        let interimSegment = TranscriptSegment(
            id: "interim-1",
            speaker: speaker,
            text: "select German and hear",
            language: "en-US",
            sourceProvider: "deepgram-transcribe",
            isFinal: false,
            speechFinal: false
        )
        _ = await pipeline.apply(TranscriptSegmentAccumulationResult(
            document: TranscriptDocument(segments: [finalSegment, interimSegment]),
            changedSegmentIDs: ["interim-1"],
            plainTextReplacement: nil
        ))

        let translatedInterimUpdate = TranscriptSegment(
            id: "interim-1",
            speaker: speaker,
            text: "select German and hear the customer",
            language: "en-US",
            sourceProvider: "deepgram-transcribe",
            isFinal: false,
            speechFinal: false,
            translatedText: "并听客户讲话",
            translationTargetLocale: "zh-CN",
            translationIsFinal: false
        )
        let snapshot = await pipeline.apply(TranscriptSegmentAccumulationResult(
            document: TranscriptDocument(segments: [finalSegment, translatedInterimUpdate]),
            changedSegmentIDs: ["interim-1"],
            plainTextReplacement: nil
        ))

        XCTAssertEqual(snapshot.turns.count, 1)
        XCTAssertEqual(snapshot.turns.first?.sourceSegmentIDs, ["final-1", "interim-1"])
        XCTAssertEqual(snapshot.turns.first?.originalText, "select German and hear the customer")
        XCTAssertNil(snapshot.turns.first?.translatedText)
        XCTAssertEqual(snapshot.turns.first?.translationHealth, .pending)
    }

    func testApplyRemovalAfterProvisionalMergeRestoresFinalTurn() async {
        let pipeline = LiveCaptionPipeline(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            translationProvider: nil,
            performanceEventLogger: nil
        )
        let speaker = TranscriptSpeaker(identifier: "deepgram-speaker-0")
        let finalSegment = TranscriptSegment(
            id: "final-1",
            speaker: speaker,
            text: "select German",
            language: "en-US",
            sourceProvider: "deepgram-transcribe",
            isFinal: true,
            speechFinal: true
        )
        _ = await pipeline.apply(TranscriptSegmentAccumulationResult(
            document: TranscriptDocument(segments: [finalSegment]),
            changedSegmentIDs: ["final-1"],
            plainTextReplacement: nil
        ))

        let interimSegment = TranscriptSegment(
            id: "interim-1",
            speaker: speaker,
            text: "select German and hear",
            language: "en-US",
            sourceProvider: "deepgram-transcribe",
            isFinal: false,
            speechFinal: false
        )
        _ = await pipeline.apply(TranscriptSegmentAccumulationResult(
            document: TranscriptDocument(segments: [finalSegment, interimSegment]),
            changedSegmentIDs: ["interim-1"],
            plainTextReplacement: nil
        ))

        let snapshot = await pipeline.apply(TranscriptSegmentAccumulationResult(
            document: TranscriptDocument(segments: [finalSegment]),
            changedSegmentIDs: ["interim-1"],
            plainTextReplacement: nil
        ))

        XCTAssertEqual(snapshot.turns.count, 1)
        XCTAssertEqual(snapshot.turns.first?.originalText, "select German")
        XCTAssertEqual(snapshot.turns.first?.sourceSegmentIDs, ["final-1"])
        XCTAssertEqual(snapshot.turns.first?.displayState, .sealed)
        XCTAssertEqual(snapshot.turns.first?.boundaryStrength, .hard)
    }

    func testApplyRemovalAfterProvisionalMergeRestoresRemainingCachedTranslation() async {
        let pipeline = LiveCaptionPipeline(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            translationProvider: nil,
            performanceEventLogger: nil
        )
        let speaker = TranscriptSpeaker(identifier: "deepgram-speaker-0")
        let finalSegment = TranscriptSegment(
            id: "final-1",
            speaker: speaker,
            text: "select German",
            language: "en-US",
            sourceProvider: "deepgram-transcribe",
            isFinal: true,
            speechFinal: true
        )
        _ = await pipeline.apply(TranscriptSegmentAccumulationResult(
            document: TranscriptDocument(segments: [finalSegment]),
            changedSegmentIDs: ["final-1"],
            plainTextReplacement: nil
        ))

        let interimSegment = TranscriptSegment(
            id: "interim-1",
            speaker: speaker,
            text: "select German and hear",
            language: "en-US",
            sourceProvider: "deepgram-transcribe",
            isFinal: false,
            speechFinal: false
        )
        _ = await pipeline.apply(TranscriptSegmentAccumulationResult(
            document: TranscriptDocument(segments: [finalSegment, interimSegment]),
            changedSegmentIDs: ["interim-1"],
            plainTextReplacement: nil
        ))

        let translatedFinalSegment = TranscriptSegment(
            id: "final-1",
            speaker: speaker,
            text: "select German",
            language: "en-US",
            sourceProvider: "deepgram-transcribe",
            isFinal: true,
            speechFinal: true,
            translatedText: "选择德语",
            translationTargetLocale: "zh-CN",
            translationIsFinal: true
        )
        let snapshot = await pipeline.apply(TranscriptSegmentAccumulationResult(
            document: TranscriptDocument(segments: [translatedFinalSegment]),
            changedSegmentIDs: ["interim-1"],
            plainTextReplacement: nil
        ))

        XCTAssertEqual(snapshot.turns.count, 1)
        XCTAssertEqual(snapshot.turns.first?.sourceSegmentIDs, ["final-1"])
        XCTAssertEqual(snapshot.turns.first?.translatedText, "选择德语")
        XCTAssertEqual(snapshot.turns.first?.translationHealth, .live)
        XCTAssertEqual(snapshot.turns.first?.translationState, .final)
    }

    func testApplyFinalAfterProvisionalMergeUpdatesMergedTurnWithoutDuplicate() async {
        let pipeline = LiveCaptionPipeline(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            translationProvider: nil,
            performanceEventLogger: nil
        )
        let speaker = TranscriptSpeaker(identifier: "deepgram-speaker-0")
        let finalSegment = TranscriptSegment(
            id: "final-1",
            speaker: speaker,
            text: "select German",
            language: "en-US",
            sourceProvider: "deepgram-transcribe",
            isFinal: true,
            speechFinal: true
        )
        _ = await pipeline.apply(TranscriptSegmentAccumulationResult(
            document: TranscriptDocument(segments: [finalSegment]),
            changedSegmentIDs: ["final-1"],
            plainTextReplacement: nil
        ))

        let interimSegment = TranscriptSegment(
            id: "interim-1",
            speaker: speaker,
            text: "select German and hear",
            language: "en-US",
            sourceProvider: "deepgram-transcribe",
            isFinal: false,
            speechFinal: false
        )
        _ = await pipeline.apply(TranscriptSegmentAccumulationResult(
            document: TranscriptDocument(segments: [finalSegment, interimSegment]),
            changedSegmentIDs: ["interim-1"],
            plainTextReplacement: nil
        ))

        let finalizedInterim = TranscriptSegment(
            id: "interim-1",
            speaker: speaker,
            text: "select German and hear the customer",
            language: "en-US",
            sourceProvider: "deepgram-transcribe",
            isFinal: true,
            speechFinal: true
        )
        let snapshot = await pipeline.apply(TranscriptSegmentAccumulationResult(
            document: TranscriptDocument(segments: [finalSegment, finalizedInterim]),
            changedSegmentIDs: ["interim-1"],
            plainTextReplacement: nil
        ))

        XCTAssertEqual(snapshot.turns.count, 1)
        XCTAssertEqual(snapshot.turns.first?.originalText, "select German and hear the customer")
        XCTAssertEqual(snapshot.turns.first?.sourceSegmentIDs, ["final-1", "interim-1"])
        XCTAssertEqual(snapshot.turns.first?.displayState, .sealed)
        XCTAssertEqual(snapshot.turns.first?.boundaryStrength, .hard)
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

    func testReplayMergesOverlappingInterimWithPreviousFinalTurn() async {
        let pipeline = LiveCaptionPipeline(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            translationProvider: nil,
            performanceEventLogger: nil
        )
        let speaker = TranscriptSpeaker(identifier: "speaker-1")
        let document = TranscriptDocument(segments: [
            TranscriptSegment(
                id: "final-1",
                speaker: speaker,
                text: "Now what we can do is select German",
                language: "en-US",
                isFinal: true,
                speechFinal: true
            ),
            TranscriptSegment(
                id: "interim-1",
                speaker: speaker,
                text: "select German and hear what it sounds like",
                language: "en-US",
                isFinal: false,
                speechFinal: false
            )
        ])

        let snapshot = await pipeline.replay(document)

        XCTAssertEqual(snapshot.turns.count, 1)
        XCTAssertEqual(snapshot.turns.first?.sourceSegmentIDs, ["final-1", "interim-1"])
        XCTAssertEqual(
            snapshot.turns.first?.originalText,
            "Now what we can do is select German and hear what it sounds like"
        )
        XCTAssertEqual(snapshot.turns.first?.displayState, .draft)
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

    func testReplaySchedulesFinalTranslationForHardSealedTurn() async {
        let provider = PipelineRecordingTranslationProvider(translations: ["segment-1": "你好"])
        let pipeline = LiveCaptionPipeline(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            translationProvider: provider,
            performanceEventLogger: nil
        )
        let document = TranscriptDocument(segments: [
            TranscriptSegment(
                id: "segment-1",
                text: "hello",
                language: "en-US",
                isFinal: true,
                speechFinal: true
            )
        ])

        let snapshot = await pipeline.replay(document)

        XCTAssertEqual(provider.requests, ["hello"])
        XCTAssertEqual(snapshot.turns.first?.translatedText, "你好")
        XCTAssertEqual(snapshot.turns.first?.translationHealth, .live)
        XCTAssertEqual(snapshot.turns.first?.translationState, .final)
        XCTAssertEqual(snapshot.translationHealth, .live)
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

private final class PipelineRecordingTranslationProvider: TextTranslationProvider {
    var translations: [String: String]
    private(set) var requests: [String] = []

    init(translations: [String: String]) {
        self.translations = translations
    }

    var descriptor: ProviderDescriptor {
        ProviderDescriptor(
            id: "pipeline-recording-translation",
            displayName: "Pipeline Recording Translation",
            capability: .textTranslation,
            executionMode: .local,
            supportedSourceLocales: ["*"],
            supportedTargetLocales: ["*"],
            requiresNetwork: false,
            requiresAPIKey: false
        )
    }

    func translate(transcript: TranscriptDocument, options: TranslationOptions) async throws -> TranslatedTranscript {
        requests.append(transcript.segments.map(\.text).joined(separator: " "))
        return TranslatedTranscript(
            sourceLocale: options.sourceLocale,
            targetLocale: options.targetLocale,
            segments: transcript.segments.map { segment in
                BilingualSubtitleSegment(
                    id: segment.id,
                    speaker: segment.speaker,
                    sourceText: segment.text,
                    targetText: translations[segment.id] ?? "",
                    status: .complete,
                    providerChain: [descriptor.id]
                )
            },
            provenance: PipelineProvenance(profileID: "pipeline-recording")
        )
    }
}
