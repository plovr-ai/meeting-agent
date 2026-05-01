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
        XCTAssertTrue(CaptionTranslationUpdate(
            turnID: turn.id,
            key: "key-1",
            result: .draftText("草稿"),
            request: request
        ).attachesVisibleText)
        XCTAssertEqual(CaptionTranslationUpdate(
            turnID: turn.id,
            key: "key-1",
            result: .finalText("最终"),
            request: request
        ).visibleTextLength, 2)
        XCTAssertFalse(CaptionTranslationUpdate(
            turnID: turn.id,
            key: "key-1",
            result: .completeWithoutText,
            request: request
        ).attachesVisibleText)
        XCTAssertNil(CaptionTranslationUpdate(
            turnID: turn.id,
            key: "key-1",
            result: .failed("timeout"),
            request: request
        ).visibleTextLength)
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

    func testDraftTranslationTelemetryUsesDraftFinalFlagAndBudgetMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("caption-translation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let eventsURL = root.appendingPathComponent("performance-events.jsonl")
        var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        store.upsert(draftTurn(text: "draft text", sourceLocale: "en-US", targetLocale: "zh-CN"))
        let provider = RecordingTextTranslationProvider(translations: ["segment-1": "草稿"])
        let scheduler = CaptionTranslationScheduler(
            provider: provider,
            performanceEventLogger: PerformanceEventLogger(url: eventsURL),
            configuration: CaptionTranslationSchedulerConfiguration(draftDebounceNanoseconds: 0, maxConcurrentTranslationRequests: 2)
        )

        for update in await scheduler.liveTranslationUpdates(for: store) {
            scheduler.apply(update, to: &store)
        }

        let events = try readEvents(from: eventsURL)
        let started = try XCTUnwrap(events.first { $0.event == "caption_translation_started" })
        XCTAssertEqual(started.isFinal, false)
        XCTAssertEqual(started.metadata["translationKind"], "draft")
        XCTAssertEqual(started.metadata["sourceTextLength"], "10")
        XCTAssertNotNil(started.metadata["sourceTextHash"])
        XCTAssertEqual(started.metadata["requestOrdinalForTurn"], "1")
        XCTAssertEqual(started.metadata["inFlightCount"], "1")
        XCTAssertEqual(started.metadata["concurrencyLimit"], "2")
        XCTAssertEqual(started.metadata["providerID"], "recording-translation")
        XCTAssertNil(started.metadata["sourceText"])
        let finished = try XCTUnwrap(events.first { $0.event == "caption_translation_finished" })
        XCTAssertNotNil(finished.metadata["durationMilliseconds"])
        let scheduledCount = try XCTUnwrap(events.first { $0.event == "caption_translation_scheduled_count" })
        XCTAssertEqual(scheduledCount.metadata["count"], "1")
        XCTAssertEqual(scheduledCount.metadata["translationKind"], "draft")
        let completedCount = try XCTUnwrap(events.first { $0.event == "caption_translation_completed_count" })
        XCTAssertEqual(completedCount.metadata["count"], "1")
        XCTAssertEqual(completedCount.metadata["translationKind"], "draft")
    }

    func testDraftTranslationDebounceKeepsLatestPendingDraftForTurn() async {
        var firstStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        firstStore.upsert(draftTurn(text: "old draft", sourceLocale: "en-US", targetLocale: "zh-CN"))
        var secondStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        secondStore.upsert(draftTurn(text: "new draft", sourceLocale: "en-US", targetLocale: "zh-CN"))
        let firstStoreSnapshot = firstStore
        let provider = RecordingTextTranslationProvider(translations: ["segment-1": "新草稿"])
        let scheduler = CaptionTranslationScheduler(
            provider: provider,
            performanceEventLogger: nil,
            configuration: CaptionTranslationSchedulerConfiguration(draftDebounceNanoseconds: 30_000_000, maxConcurrentTranslationRequests: 2)
        )

        async let firstUpdates = scheduler.liveTranslationUpdates(for: firstStoreSnapshot)
        try? await Task.sleep(nanoseconds: 5_000_000)
        let secondUpdates = await scheduler.liveTranslationUpdates(for: secondStore)
        let resolvedFirstUpdates = await firstUpdates

        XCTAssertTrue(resolvedFirstUpdates.isEmpty)
        XCTAssertEqual(secondUpdates.count, 1)
        XCTAssertEqual(provider.requests.map(\.sourceText), ["new draft"])
    }

    func testFinalTranslationBypassesDraftDebounceAndRunsWhenDraftTextMatches() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("caption-translation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let eventsURL = root.appendingPathComponent("performance-events.jsonl")
        var draftStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        draftStore.upsert(draftTurn(text: "same text", sourceLocale: "en-US", targetLocale: "zh-CN"))
        var finalStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        finalStore.upsert(hardSealedTurn(text: "same text", sourceLocale: "en-US", targetLocale: "zh-CN"))
        let draftStoreSnapshot = draftStore
        let provider = RecordingTextTranslationProvider(translations: ["segment-1": "最终"])
        let scheduler = CaptionTranslationScheduler(
            provider: provider,
            performanceEventLogger: PerformanceEventLogger(url: eventsURL),
            configuration: CaptionTranslationSchedulerConfiguration(draftDebounceNanoseconds: 30_000_000, maxConcurrentTranslationRequests: 2)
        )

        async let draftUpdates = scheduler.liveTranslationUpdates(for: draftStoreSnapshot)
        try? await Task.sleep(nanoseconds: 5_000_000)
        let finalUpdates = await scheduler.translationUpdates(for: finalStore)
        _ = await draftUpdates

        let events = try readEvents(from: eventsURL)
        XCTAssertEqual(finalUpdates.count, 1)
        XCTAssertEqual(provider.requests.map(\.sourceText), ["same text"])
        XCTAssertTrue(events.contains { $0.event == "caption_translation_started" && $0.metadata["translationKind"] == "final" })
        XCTAssertTrue(events.contains {
            $0.event == "caption_translation_scheduled_count"
                && $0.metadata["translationKind"] == "final"
                && $0.metadata["count"] == "1"
                && $0.metadata["providerID"] == "recording-translation"
        })
    }

    func testStaleDraftCompletionLogsStaleWithoutAttachedEvent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("caption-translation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let eventsURL = root.appendingPathComponent("performance-events.jsonl")
        var originalStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        originalStore.upsert(draftTurn(text: "old draft", sourceLocale: "en-US", targetLocale: "zh-CN"))
        var currentStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        currentStore.upsert(draftTurn(text: "new draft", sourceLocale: "en-US", targetLocale: "zh-CN"))
        let provider = RecordingTextTranslationProvider(translations: ["segment-1": "旧草稿"])
        let scheduler = CaptionTranslationScheduler(
            provider: provider,
            performanceEventLogger: PerformanceEventLogger(url: eventsURL),
            configuration: CaptionTranslationSchedulerConfiguration(draftDebounceNanoseconds: 0, maxConcurrentTranslationRequests: 2)
        )

        let updates = await scheduler.liveTranslationUpdates(for: originalStore)
        let update = try XCTUnwrap(updates.first)
        scheduler.apply(update, to: &currentStore)

        let events = try readEvents(from: eventsURL)
        let stale = try XCTUnwrap(events.first { $0.event == "caption_translation_stale" })
        XCTAssertEqual(stale.metadata["translationKind"], "draft")
        XCTAssertEqual(stale.metadata["reason"], "draft_no_longer_current")
        XCTAssertTrue(events.contains {
            $0.event == "caption_translation_stale_count"
                && $0.metadata["count"] == "1"
                && $0.metadata["translationKind"] == "draft"
        })
        XCTAssertFalse(events.contains { $0.event == "caption_translation_attached" })
        XCTAssertNil(currentStore.turns.first?.translatedText)
    }

    func testDiscardStaleLogsUpdateAgainstCurrentStore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("caption-translation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let eventsURL = root.appendingPathComponent("performance-events.jsonl")
        var originalStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        originalStore.upsert(draftTurn(text: "old draft", sourceLocale: "en-US", targetLocale: "zh-CN"))
        var currentStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        currentStore.upsert(draftTurn(text: "new draft", sourceLocale: "en-US", targetLocale: "zh-CN"))
        let provider = RecordingTextTranslationProvider(translations: ["segment-1": "旧草稿"])
        let scheduler = CaptionTranslationScheduler(
            provider: provider,
            performanceEventLogger: PerformanceEventLogger(url: eventsURL),
            configuration: CaptionTranslationSchedulerConfiguration(draftDebounceNanoseconds: 0, maxConcurrentTranslationRequests: 2)
        )

        let updates = await scheduler.liveTranslationUpdates(for: originalStore)
        let update = try XCTUnwrap(updates.first)
        scheduler.discardStale(update, against: currentStore)

        let events = try readEvents(from: eventsURL)
        XCTAssertTrue(events.contains {
            $0.event == "caption_translation_stale"
                && $0.metadata["reason"] == "draft_no_longer_current"
        })
    }

    func testProviderFailureLogsSanitizedErrorCount() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("caption-translation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let eventsURL = root.appendingPathComponent("performance-events.jsonl")
        var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        store.upsert(hardSealedTurn(text: "private words", sourceLocale: "en-US", targetLocale: "zh-CN"))
        let provider = RecordingTextTranslationProvider(error: NSError(domain: "translation", code: 2))
        let scheduler = CaptionTranslationScheduler(
            provider: provider,
            performanceEventLogger: PerformanceEventLogger(url: eventsURL),
            configuration: CaptionTranslationSchedulerConfiguration(draftDebounceNanoseconds: 0, maxConcurrentTranslationRequests: 2)
        )

        await scheduler.scheduleTranslations(in: &store)

        let events = try readEvents(from: eventsURL)
        let providerError = try XCTUnwrap(events.first { $0.event == "caption_translation_provider_error" })
        XCTAssertEqual(providerError.metadata["failureReason"], "translation error 2")
        XCTAssertEqual(providerError.metadata["retryCount"], "0")
        XCTAssertEqual(providerError.metadata["count"], "1")
        XCTAssertEqual(providerError.metadata["translationKind"], "final")
        XCTAssertEqual(providerError.metadata["providerID"], "recording-translation")
        XCTAssertFalse(providerError.metadata.values.contains("private words"))
        XCTAssertTrue(events.contains {
            $0.event == "caption_translation_failed_count"
                && $0.metadata["count"] == "1"
                && $0.metadata["translationKind"] == "final"
                && $0.metadata["failureReason"] == "translation error 2"
        })
    }

    func testTranslationRequestsRespectGlobalConcurrencyLimit() async {
        var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        store.upsert(hardSealedTurn(id: "segment-1", text: "first", sourceLocale: "en-US", targetLocale: "zh-CN"))
        store.upsert(hardSealedTurn(id: "segment-2", text: "second", sourceLocale: "en-US", targetLocale: "zh-CN"))
        store.upsert(hardSealedTurn(id: "segment-3", text: "third", sourceLocale: "en-US", targetLocale: "zh-CN"))
        let provider = DelayedRecordingTextTranslationProvider(delayNanoseconds: 20_000_000)
        let scheduler = CaptionTranslationScheduler(
            provider: provider,
            performanceEventLogger: nil,
            configuration: CaptionTranslationSchedulerConfiguration(draftDebounceNanoseconds: 0, maxConcurrentTranslationRequests: 2)
        )

        let updates = await scheduler.translationUpdates(for: store)

        XCTAssertEqual(updates.count, 3)
        XCTAssertEqual(provider.maximumConcurrentRequests, 2)
    }

    private func hardSealedTurn(
        id: String = "segment-1",
        text: String = "hello",
        sourceLocale: String,
        targetLocale: String
    ) -> LiveCaptionTurn {
        LiveCaptionTurn(
            sourceSegmentID: id,
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

    private func draftTurn(
        id: String = "segment-1",
        text: String,
        sourceLocale: String,
        targetLocale: String
    ) -> LiveCaptionTurn {
        LiveCaptionTurn(
            sourceSegmentID: id,
            originalText: text,
            sourceLocale: sourceLocale,
            targetLocale: targetLocale,
            isFinal: false,
            translationHealth: .pending,
            displayState: .draft,
            translationState: .draft
        )
    }

    private func readEvents(from url: URL) throws -> [PerformanceEvent] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try String(contentsOf: url, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map { try decoder.decode(PerformanceEvent.self, from: Data($0.utf8)) }
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

private final class DelayedRecordingTextTranslationProvider: TextTranslationProvider {
    let delayNanoseconds: UInt64
    private let lock = NSLock()
    private var activeRequestCount = 0
    private var maximumConcurrentRequestCount = 0

    var maximumConcurrentRequests: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximumConcurrentRequestCount
    }

    init(delayNanoseconds: UInt64) {
        self.delayNanoseconds = delayNanoseconds
    }

    var descriptor: ProviderDescriptor {
        ProviderDescriptor(
            id: "delayed-recording-translation",
            displayName: "Delayed Recording Translation",
            capability: .textTranslation,
            executionMode: .local,
            supportedSourceLocales: ["*"],
            supportedTargetLocales: ["*"],
            requiresNetwork: false,
            requiresAPIKey: false
        )
    }

    func translate(transcript: TranscriptDocument, options: TranslationOptions) async throws -> TranslatedTranscript {
        beginRequest()
        try? await Task.sleep(nanoseconds: delayNanoseconds)
        endRequest()
        return TranslatedTranscript(
            sourceLocale: options.sourceLocale,
            targetLocale: options.targetLocale,
            segments: transcript.segments.map { segment in
                BilingualSubtitleSegment(
                    id: segment.id,
                    speaker: segment.speaker,
                    sourceText: segment.text,
                    targetText: "translated \(segment.text)",
                    status: .complete,
                    providerChain: [descriptor.id]
                )
            },
            provenance: PipelineProvenance(profileID: "recording")
        )
    }

    private func beginRequest() {
        lock.lock()
        activeRequestCount += 1
        maximumConcurrentRequestCount = max(maximumConcurrentRequestCount, activeRequestCount)
        lock.unlock()
    }

    private func endRequest() {
        lock.lock()
        activeRequestCount -= 1
        lock.unlock()
    }
}
