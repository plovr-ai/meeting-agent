import XCTest
@testable import MeetingAgentCore

@MainActor
final class CaptionTranslationSchedulerTests: XCTestCase {
    func testTranslationUpdateEquatableCoversRequestAndResultVariants() {
        let turn = hardSealedTurn(text: "hello", sourceLocale: "en-US", targetLocale: "zh-CN")
        let request = ActiveCaptionTranslationRequest(
            id: "request-1",
            turn: turn,
            key: "key-1",
            isDraft: false,
            revision: 0
        )

        XCTAssertEqual(request, ActiveCaptionTranslationRequest(
            id: "request-1",
            turn: turn,
            key: "key-1",
            isDraft: false,
            revision: 0
        ))
        XCTAssertEqual(CaptionTranslationUpdateResult.completeWithoutText, .completeWithoutText)
        XCTAssertEqual(CaptionTranslationUpdateResult.draftText("草稿"), .draftText("草稿"))
        XCTAssertEqual(CaptionTranslationUpdateResult.finalText("最终"), .finalText("最终"))
        XCTAssertEqual(CaptionTranslationUpdateResult.failed("timeout"), .failed("timeout"))
        XCTAssertEqual(
            CaptionTranslationUpdate(
                turnID: turn.id,
                key: "key-1",
                result: .finalText("最终"),
                request: request
            ),
            CaptionTranslationUpdate(
                turnID: turn.id,
                key: "key-1",
                result: .finalText("最终"),
                request: request
            )
        )
    }

    func testSameLanguageCompletesWithoutProviderCall() async {
        var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "en-GB")
        store.upsert(hardSealedTurn(sourceLocale: "en-US", targetLocale: "en-GB"))
        let provider = RecordingTextTranslationProvider()
        let scheduler = CaptionTranslationScheduler(provider: provider, performanceEventLogger: nil)

        await scheduler.scheduleTranslations(in: &store)

        XCTAssertEqual(provider.requests.count, 0)
        XCTAssertNil(store.turns.first?.translatedText)
        XCTAssertEqual(store.turns.first?.translationHealth, .live)
    }

    func testHardSealedTurnRequestsFinalTranslation() async {
        var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        store.upsert(hardSealedTurn(text: "hello", sourceLocale: "en-US", targetLocale: "zh-CN"))
        let provider = RecordingTextTranslationProvider(translations: ["segment-1": "你好"])
        let scheduler = CaptionTranslationScheduler(provider: provider, performanceEventLogger: nil)

        await scheduler.scheduleTranslations(in: &store)

        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertEqual(provider.requests.first?.sourceText, "hello")
        XCTAssertEqual(provider.requests.first?.sourceLocale, "en-US")
        XCTAssertEqual(provider.requests.first?.targetLocale, "zh-CN")
        XCTAssertEqual(store.turns.first?.translatedText, "你好")
        XCTAssertEqual(store.turns.first?.translationHealth, .live)
        XCTAssertEqual(store.turns.first?.translationState, .final)
    }

    func testHardSealedTurnAvoidsDuplicateFinalTranslationForSameKey() async {
        var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        store.upsert(hardSealedTurn(text: "hello", sourceLocale: "en-US", targetLocale: "zh-CN"))
        let provider = RecordingTextTranslationProvider(translations: ["segment-1": "你好"])
        let scheduler = CaptionTranslationScheduler(provider: provider, performanceEventLogger: nil)

        await scheduler.scheduleTranslations(in: &store)
        await scheduler.scheduleTranslations(in: &store)

        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertEqual(store.turns.first?.translatedText, "你好")
        XCTAssertEqual(store.turns.first?.translationState, .final)
    }

    func testHardSealedTurnMarksFailureWithNSErrorStyleMessage() async {
        var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        store.upsert(hardSealedTurn(text: "hello", sourceLocale: "en-US", targetLocale: "zh-CN"))
        let provider = RecordingTextTranslationProvider(error: NSError(domain: "translation", code: 2))
        let scheduler = CaptionTranslationScheduler(provider: provider, performanceEventLogger: nil)

        await scheduler.scheduleTranslations(in: &store)

        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertEqual(store.turns.first?.translationHealth, .failed("translation error 2"))
        XCTAssertNil(store.turns.first?.translatedText)
    }

    func testSoftSealedAndDraftTurnsDoNotCallProvider() async {
        var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        store.upsert(LiveCaptionTurn(
            sourceSegmentID: "soft",
            originalText: "soft boundary",
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            isFinal: true,
            translationHealth: .pending,
            displayState: .sealed,
            translationState: .draft,
            boundaryReason: .punctuation,
            boundaryStrength: .soft
        ))
        store.upsert(LiveCaptionTurn(
            sourceSegmentID: "draft",
            originalText: "draft turn",
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            isFinal: false,
            translationHealth: .pending,
            displayState: .draft,
            translationState: .draft
        ))
        let provider = RecordingTextTranslationProvider(translations: ["soft": "软边界", "draft": "草稿"])
        let scheduler = CaptionTranslationScheduler(provider: provider, performanceEventLogger: nil)

        await scheduler.scheduleTranslations(in: &store)

        XCTAssertTrue(provider.requests.isEmpty)
        XCTAssertEqual(store.turns.map(\.translationHealth), [.pending, .pending])
    }

    func testNilProviderLeavesHardSealedTranslationPending() async {
        var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        store.upsert(hardSealedTurn(text: "hello", sourceLocale: "en-US", targetLocale: "zh-CN"))
        let scheduler = CaptionTranslationScheduler(provider: nil, performanceEventLogger: nil)

        await scheduler.scheduleTranslations(in: &store)

        XCTAssertNil(store.turns.first?.translatedText)
        XCTAssertEqual(store.turns.first?.translationHealth, .pending)
        XCTAssertEqual(store.turns.first?.translationState, .pendingFinal)
    }

    private func hardSealedTurn(
        text: String = "hello",
        sourceLocale: String,
        targetLocale: String
    ) -> LiveCaptionTurn {
        LiveCaptionTurn(
            sourceSegmentID: "segment-1",
            originalText: text,
            sourceLocale: sourceLocale,
            targetLocale: targetLocale,
            isFinal: true,
            translationHealth: .pending,
            displayState: .sealed,
            translationState: .pendingFinal,
            boundaryReason: .speechFinal,
            boundaryStrength: .hard
        )
    }
}

private final class RecordingTextTranslationProvider: TextTranslationProvider {
    struct Request: Equatable {
        var sourceText: String
        var sourceLocale: String
        var targetLocale: String
    }

    var translations: [String: String]
    var error: Error?
    private(set) var requests: [Request] = []

    init(translations: [String: String] = [:], error: Error? = nil) {
        self.translations = translations
        self.error = error
    }

    var descriptor: ProviderDescriptor {
        ProviderDescriptor(
            id: "recording-translation",
            displayName: "Recording Translation",
            capability: .textTranslation,
            executionMode: .local,
            supportedSourceLocales: ["*"],
            supportedTargetLocales: ["*"],
            requiresNetwork: false,
            requiresAPIKey: false
        )
    }

    func translate(transcript: TranscriptDocument, options: TranslationOptions) async throws -> TranslatedTranscript {
        let sourceText = transcript.segments.map(\.text).joined(separator: " ")
        requests.append(Request(
            sourceText: sourceText,
            sourceLocale: options.sourceLocale,
            targetLocale: options.targetLocale
        ))
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
            provenance: PipelineProvenance(profileID: "recording")
        )
    }
}
