import XCTest
@testable import MeetingAgentCore

final class LiveCaptionTranslationAdapterTests: XCTestCase {
    func testTranslatesFinalCaptionSegmentAndAttachesToSameTurn() async throws {
        var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        let turn = store.append(TranscriptSegment(id: "segment-1", text: "hello", language: "en-US", isFinal: true))
        let adapter = LiveCaptionTranslationAdapter(provider: FakeTextTranslationProvider(translations: ["segment-1": "你好"]))

        try await adapter.translate(turn: turn, in: &store)

        XCTAssertEqual(store.turns.first?.sourceSegmentID, "segment-1")
        XCTAssertEqual(store.turns.first?.translatedText, "你好")
        XCTAssertEqual(store.turns.first?.translationHealth, .live)
    }

    func testTranslationFailureMarksOnlyTranslationHealth() async {
        var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        let turn = store.append(TranscriptSegment(id: "segment-1", text: "hello", language: "en-US", isFinal: true))
        let adapter = LiveCaptionTranslationAdapter(provider: FakeTextTranslationProvider(error: NSError(domain: "translation", code: 2)))

        do {
            try await adapter.translate(turn: turn, in: &store)
            XCTFail("Expected translation to fail")
        } catch {}

        XCTAssertEqual(store.turns.first?.captionHealth, .live)
        XCTAssertEqual(store.turns.first?.translationHealth, .failed("translation error 2"))
        XCTAssertNil(store.turns.first?.translatedText)
    }
}

private struct FakeTextTranslationProvider: TextTranslationProvider {
    var translations: [String: String]
    var error: Error?

    init(translations: [String: String] = [:], error: Error? = nil) {
        self.translations = translations
        self.error = error
    }

    var descriptor: ProviderDescriptor {
        ProviderDescriptor(
            id: "fake-translation",
            displayName: "Fake Translation",
            capability: .textTranslation,
            executionMode: .local,
            supportedSourceLocales: ["*"],
            supportedTargetLocales: ["*"],
            requiresNetwork: false,
            requiresAPIKey: false
        )
    }

    func translate(transcript: TranscriptDocument, options: TranslationOptions) async throws -> TranslatedTranscript {
        if let error {
            throw error
        }
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
            provenance: PipelineProvenance(profileID: "fake")
        )
    }
}
