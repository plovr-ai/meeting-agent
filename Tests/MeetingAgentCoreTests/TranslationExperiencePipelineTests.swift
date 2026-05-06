import XCTest
@testable import MeetingAgentCore

@MainActor
final class TranslationExperiencePipelineTests: XCTestCase {
    func testFlushAndFinalizePersistsStableFinalOnly() async {
        let provider = PipelineTranslationProvider(translations: [
            "stable-expected": "我们会复查上线状态。"
        ])
        var persisted: [TranslationResultPersistenceRecord] = []
        var pipeline = TranslationExperiencePipeline(
            meetingID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            liveProvider: provider,
            accurateProvider: provider,
            persistFinalResult: { record in persisted.append(record) }
        )
        let segment = TranscriptSegment(
            id: "segment-1",
            text: "We should review the rollout status",
            language: "en-US",
            isFinal: true,
            speechFinal: false,
            createdAt: Date(timeIntervalSince1970: 1)
        )

        _ = await pipeline.apply(segments: [segment], now: Date(timeIntervalSince1970: 2))
        let snapshot = await pipeline.flushAndFinalize(now: Date(timeIntervalSince1970: 3))

        XCTAssertTrue(snapshot.liveResults.isEmpty)
        XCTAssertEqual(snapshot.stableResults.count, 1)
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted.first?.displayState, .stableFinal)
        XCTAssertEqual(persisted.first?.sourceSegmentIDs, ["segment-1"])
    }

    func testPipelineBuildsUnitsAndStoresLiveResult() async {
        let provider = PipelineTranslationProvider(translations: ["segment-1-live-1": "我们确认负责人"])
        var pipeline = TranslationExperiencePipeline(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            liveProvider: provider,
            accurateProvider: provider
        )
        let segment = TranscriptSegment(
            id: "segment-1",
            text: "We should confirm the launch owner today",
            language: "en-US",
            isFinal: false
        )

        let snapshot = await pipeline.apply(segments: [segment])

        XCTAssertEqual(snapshot.liveResults.count, 1)
        XCTAssertEqual(snapshot.visibleResults.first?.translatedText, "我们确认负责人")
    }
}

private final class PipelineTranslationProvider: TextTranslationProvider {
    let translations: [String: String]

    init(translations: [String: String]) {
        self.translations = translations
    }

    var descriptor: ProviderDescriptor {
        ProviderDescriptor(
            id: "test-pipeline",
            displayName: "Test Pipeline",
            capability: .textTranslation,
            executionMode: .hosted,
            supportedSourceLocales: ["*"],
            supportedTargetLocales: ["*"],
            requiresNetwork: false,
            requiresAPIKey: false
        )
    }

    func translate(transcript: TranscriptDocument, options: TranslationOptions) async throws -> TranslatedTranscript {
        let segment = transcript.segments[0]
        let target = translations[segment.id] ?? translations["stable-expected"] ?? "translated"
        return TranslatedTranscript(
            sourceLocale: options.sourceLocale,
            targetLocale: options.targetLocale,
            segments: [
                BilingualSubtitleSegment(
                    id: segment.id,
                    sourceText: segment.text,
                    targetText: target
                )
            ],
            provenance: PipelineProvenance(profileID: "test-pipeline", successfulProviders: ["test-pipeline"])
        )
    }
}
