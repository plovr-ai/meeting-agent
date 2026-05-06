import XCTest
@testable import MeetingAgentCore

@MainActor
final class TranslationExperiencePipelineTests: XCTestCase {
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
        return TranslatedTranscript(
            sourceLocale: options.sourceLocale,
            targetLocale: options.targetLocale,
            segments: [
                BilingualSubtitleSegment(
                    id: segment.id,
                    sourceText: segment.text,
                    targetText: translations[segment.id] ?? "translated"
                )
            ],
            provenance: PipelineProvenance(profileID: "test-pipeline", successfulProviders: ["test-pipeline"])
        )
    }
}
