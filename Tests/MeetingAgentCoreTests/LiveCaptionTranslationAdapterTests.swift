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

    func testPartialCaptionSegmentDoesNotCallTranslationProviderDirectly() async throws {
        var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        let turn = store.append(TranscriptSegment(id: "segment-1", text: "hel", language: "en-US", isFinal: false))
        let provider = FakeTextTranslationProvider(translations: ["segment-1": "你"])
        let adapter = LiveCaptionTranslationAdapter(provider: provider)

        try await adapter.translate(turn: turn, in: &store)

        XCTAssertEqual(provider.translateCallCount, 0)
        XCTAssertNil(store.turns.first?.translatedText)
        XCTAssertEqual(store.turns.first?.translationHealth, .pending)
    }

    func testSameLanguageFinalCaptionDoesNotCallTranslationProvider() async throws {
        var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "en-GB")
        let turn = store.append(TranscriptSegment(id: "segment-1", text: "hello", language: "en-US", isFinal: true))
        let provider = FakeTextTranslationProvider(translations: ["segment-1": "translated"])
        let adapter = LiveCaptionTranslationAdapter(provider: provider)

        try await adapter.translate(turn: turn, in: &store)

        XCTAssertEqual(provider.translateCallCount, 0)
        XCTAssertNil(store.turns.first?.translatedText)
        XCTAssertEqual(store.turns.first?.translationHealth, .live)
    }
}

private final class FakeTextTranslationProvider: TextTranslationProvider {
    var translations: [String: String]
    var error: Error?
    private(set) var translateCallCount = 0

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
        translateCallCount += 1
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
