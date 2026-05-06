import XCTest
@testable import MeetingAgentCore

@MainActor
final class ReplayTranslationBackfillSchedulerTests: XCTestCase {
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
        let target = CaptionTranslationAttachmentTarget(
            originalTurnID: "turn-1",
            primarySourceSegmentID: "segment-1",
            sourceSegmentIDs: ["segment-1"],
            sourceText: "hello",
            speaker: nil,
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            createdAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(target.primarySourceSegmentID, "segment-1")
        XCTAssertFalse(CaptionTranslationApplyOutcome.none.publishedVisibleText)
        XCTAssertTrue(CaptionTranslationApplyOutcome.attached(turnID: "turn-1").publishedVisibleText)
        XCTAssertTrue(CaptionTranslationApplyOutcome.rebound(originalTurnID: "old", reboundTurnID: "new").publishedVisibleText)
        XCTAssertFalse(CaptionTranslationApplyOutcome.persisted(segmentID: "segment-1").publishedVisibleText)
    }

    func testDraftTranslationSchedulerConfigurationExposesPolicyDefaults() {
        let configuration = ReplayTranslationBackfillSchedulerConfiguration()

        XCTAssertEqual(configuration.followUpDraftMinimumIntervalNanoseconds, 1_500_000_000)
        XCTAssertEqual(configuration.followUpDraftMaximumWaitNanoseconds, 3_000_000_000)
        XCTAssertEqual(configuration.minimumDraftWordDelta, 8)
        XCTAssertEqual(configuration.minimumDraftCharacterDelta, 48)
        XCTAssertTrue(configuration.semanticBoundaryCharacters.contains(","))
        XCTAssertTrue(configuration.semanticBoundaryCharacters.contains("。"))
    }

    func testSameLanguageCompletesWithoutProviderCall() async {
        var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "en-GB")
        store.upsert(hardSealedTurn(sourceLocale: "en-US", targetLocale: "en-GB"))
        let provider = RecordingTextTranslationProvider()
        let scheduler = ReplayTranslationBackfillScheduler(provider: provider, performanceEventLogger: nil)

        await scheduler.scheduleTranslations(in: &store)

        XCTAssertEqual(provider.requests.count, 0)
        XCTAssertNil(store.turns.first?.translatedText)
        XCTAssertEqual(store.turns.first?.translationHealth, .live)
    }

    func testHardSealedTurnRequestsFinalTranslation() async {
        var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        store.upsert(hardSealedTurn(text: "hello", sourceLocale: "en-US", targetLocale: "zh-CN"))
        let provider = RecordingTextTranslationProvider(translations: ["segment-1": "你好"])
        let scheduler = ReplayTranslationBackfillScheduler(provider: provider, performanceEventLogger: nil)

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
        let scheduler = ReplayTranslationBackfillScheduler(provider: provider, performanceEventLogger: nil)

        await scheduler.scheduleTranslations(in: &store)
        await scheduler.scheduleTranslations(in: &store)

        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertEqual(store.turns.first?.translatedText, "你好")
        XCTAssertEqual(store.turns.first?.translationState, .final)
    }

    func testFinalTranslationKeyIgnoresMutableLiveTurnState() async throws {
        var originalStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        originalStore.upsert(hardSealedTurn(text: "confirm the launch owner", sourceLocale: "en-US", targetLocale: "zh-CN"))
        let provider = RecordingTextTranslationProvider(translations: ["segment-1": "确认上线负责人"])
        let scheduler = ReplayTranslationBackfillScheduler(
            provider: provider,
            performanceEventLogger: nil,
            configuration: ReplayTranslationBackfillSchedulerConfiguration(draftDebounceNanoseconds: 0, maxConcurrentTranslationRequests: 1)
        )

        let updates = await scheduler.translationUpdates(for: originalStore)
        let update = try XCTUnwrap(updates.first)
        var changedTurn = hardSealedTurn(text: "confirm the launch owner", sourceLocale: "en-US", targetLocale: "zh-CN")
        changedTurn.displayState = .sealed
        changedTurn.boundaryStrength = .soft
        changedTurn.boundaryReason = .punctuation
        changedTurn.translationRevision = 42
        var changedStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        changedStore.upsert(changedTurn)

        let outcome = scheduler.apply(update, to: &changedStore)

        XCTAssertTrue(outcome.publishedVisibleText)
        XCTAssertEqual(changedStore.turns.first?.translatedText, "确认上线负责人")
        XCTAssertEqual(changedStore.turns.first?.translationState, .final)
    }

    func testFinalTranslationRebindsWhenOriginalTurnWasMerged() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("caption-translation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let eventsURL = root.appendingPathComponent("performance-events.jsonl")
        var originalStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        originalStore.upsert(hardSealedTurn(id: "segment-1", text: "confirm launch owner", sourceLocale: "en-US", targetLocale: "zh-CN"))
        let provider = RecordingTextTranslationProvider(translations: ["segment-1": "确认上线负责人"])
        let scheduler = ReplayTranslationBackfillScheduler(
            provider: provider,
            performanceEventLogger: PerformanceEventLogger(url: eventsURL),
            configuration: ReplayTranslationBackfillSchedulerConfiguration(draftDebounceNanoseconds: 0, maxConcurrentTranslationRequests: 1)
        )

        let updates = await scheduler.translationUpdates(for: originalStore)
        let update = try XCTUnwrap(updates.first)
        var currentStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        var merged = hardSealedTurn(id: "segment-2", text: "confirm launch owner and timeline", sourceLocale: "en-US", targetLocale: "zh-CN")
        merged.id = "merged-turn"
        merged.sourceSegmentID = "segment-2"
        merged.sourceSegmentIDs = ["segment-1", "segment-2"]
        currentStore.upsert(merged)

        let outcome = scheduler.apply(update, to: &currentStore)

        XCTAssertEqual(outcome, .rebound(originalTurnID: "segment-1", reboundTurnID: "merged-turn"))
        XCTAssertEqual(currentStore.turns.first?.translatedText, "确认上线负责人")
        XCTAssertEqual(currentStore.turns.first?.translationState, .final)
        let events = try readEvents(from: eventsURL)
        XCTAssertTrue(events.contains { $0.event == "caption_translation_rebound" && $0.metadata["translationKind"] == "final" })
        XCTAssertTrue(events.contains { $0.event == "caption_translation_attached" && $0.segmentID == "merged-turn" })
        XCTAssertFalse(events.contains { $0.event == "caption_translation_stale" && $0.metadata["reason"] == "final_no_longer_current" })
    }

    func testFinalTranslationPersistsWhenLiveTurnNoLongerExists() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("caption-translation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let eventsURL = root.appendingPathComponent("performance-events.jsonl")
        var originalStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        originalStore.upsert(hardSealedTurn(id: "segment-1", text: "confirm launch owner", sourceLocale: "en-US", targetLocale: "zh-CN"))
        let provider = RecordingTextTranslationProvider(translations: ["segment-1": "确认上线负责人"])
        var persisted: [(segmentID: String, text: String, targetLocale: String, isFinal: Bool)] = []
        let scheduler = ReplayTranslationBackfillScheduler(
            provider: provider,
            performanceEventLogger: PerformanceEventLogger(url: eventsURL),
            persistTranslation: { target, text, isFinal in
                persisted.append((target.primarySourceSegmentID, text, target.targetLocale, isFinal))
                return true
            },
            configuration: ReplayTranslationBackfillSchedulerConfiguration(draftDebounceNanoseconds: 0, maxConcurrentTranslationRequests: 1)
        )

        let updates = await scheduler.translationUpdates(for: originalStore)
        let update = try XCTUnwrap(updates.first)
        var emptyStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        let outcome = scheduler.apply(update, to: &emptyStore)

        XCTAssertEqual(outcome, .persisted(segmentID: "segment-1"))
        XCTAssertEqual(persisted.first?.segmentID, "segment-1")
        XCTAssertEqual(persisted.first?.text, "确认上线负责人")
        XCTAssertEqual(persisted.first?.targetLocale, "zh-CN")
        XCTAssertEqual(persisted.first?.isFinal, true)
        let events = try readEvents(from: eventsURL)
        XCTAssertTrue(events.contains { $0.event == "caption_translation_persisted" && $0.metadata["translationKind"] == "final" })
        XCTAssertFalse(events.contains { $0.event == "caption_translation_stale" && $0.metadata["reason"] == "final_no_longer_current" })
    }

    func testFinalTranslationWithoutLiveTurnOrPersistenceLogsTrueStaleReason() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("caption-translation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let eventsURL = root.appendingPathComponent("performance-events.jsonl")
        var originalStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        originalStore.upsert(hardSealedTurn(id: "segment-1", text: "confirm launch owner", sourceLocale: "en-US", targetLocale: "zh-CN"))
        let provider = RecordingTextTranslationProvider(translations: ["segment-1": "确认上线负责人"])
        let scheduler = ReplayTranslationBackfillScheduler(
            provider: provider,
            performanceEventLogger: PerformanceEventLogger(url: eventsURL),
            configuration: ReplayTranslationBackfillSchedulerConfiguration(draftDebounceNanoseconds: 0, maxConcurrentTranslationRequests: 1)
        )

        let updates = await scheduler.translationUpdates(for: originalStore)
        let update = try XCTUnwrap(updates.first)
        var emptyStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        let outcome = scheduler.apply(update, to: &emptyStore)

        XCTAssertEqual(outcome, .none)
        let events = try readEvents(from: eventsURL)
        XCTAssertTrue(events.contains {
            $0.event == "caption_translation_stale"
                && $0.metadata["translationKind"] == "final"
                && $0.metadata["reason"] == "source_segment_deleted"
        })
        XCTAssertTrue(events.contains {
            $0.event == "caption_translation_stale_count"
                && $0.metadata["count"] == "1"
                && $0.metadata["reason"] == "source_segment_deleted"
        })
    }

    func testLegacyFinalUpdateWithoutAttachmentTargetFallsBackToTurnID() {
        var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        let turn = hardSealedTurn(id: "segment-1", text: "legacy final", sourceLocale: "en-US", targetLocale: "zh-CN")
        store.upsert(turn)
        let request = ActiveCaptionTranslationRequest(
            id: "legacy-request",
            turn: turn,
            key: "legacy-key",
            isDraft: false,
            revision: 0,
            sourceText: "legacy final"
        )
        let scheduler = ReplayTranslationBackfillScheduler(provider: nil, performanceEventLogger: nil)

        let outcome = scheduler.apply(
            CaptionTranslationUpdate(
                turnID: turn.id,
                key: request.key,
                result: .finalText("兼容翻译"),
                request: request
            ),
            to: &store
        )

        XCTAssertEqual(outcome, .attached(turnID: turn.id))
        XCTAssertEqual(store.turns.first?.translatedText, "兼容翻译")
        XCTAssertEqual(store.turns.first?.translationState, .final)
    }

    func testDiscardStaleFinalUpdateLogsNoLongerCurrentWhenCurrentTurnIsDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("caption-translation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let eventsURL = root.appendingPathComponent("performance-events.jsonl")
        let current = draftTurn(id: "segment-1", text: "still changing", sourceLocale: "en-US", targetLocale: "zh-CN")
        let request = ActiveCaptionTranslationRequest(
            id: "final-request",
            turn: hardSealedTurn(id: "segment-1", text: "final text", sourceLocale: "en-US", targetLocale: "zh-CN"),
            key: "old-final-key",
            isDraft: false,
            revision: 0,
            sourceText: "final text"
        )
        var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        store.upsert(current)
        let scheduler = ReplayTranslationBackfillScheduler(
            provider: nil,
            performanceEventLogger: PerformanceEventLogger(url: eventsURL)
        )

        scheduler.discardStale(
            CaptionTranslationUpdate(
                turnID: current.id,
                key: request.key,
                result: .finalText("旧最终翻译"),
                request: request
            ),
            against: store
        )

        let events = try readEvents(from: eventsURL)
        XCTAssertTrue(events.contains {
            $0.event == "caption_translation_stale"
                && $0.metadata["translationKind"] == "final"
                && $0.metadata["reason"] == "final_no_longer_current"
        })
    }

    func testDiscardStaleFinalUpdateLogsKeyMismatchWhenCurrentTurnIsDifferentFinal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("caption-translation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let eventsURL = root.appendingPathComponent("performance-events.jsonl")
        let current = hardSealedTurn(id: "segment-1", text: "new final text", sourceLocale: "en-US", targetLocale: "zh-CN")
        let request = ActiveCaptionTranslationRequest(
            id: "final-request",
            turn: hardSealedTurn(id: "segment-1", text: "old final text", sourceLocale: "en-US", targetLocale: "zh-CN"),
            key: "old-final-key",
            isDraft: false,
            revision: 0,
            sourceText: "old final text"
        )
        var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        store.upsert(current)
        let scheduler = ReplayTranslationBackfillScheduler(
            provider: nil,
            performanceEventLogger: PerformanceEventLogger(url: eventsURL)
        )

        scheduler.discardStale(
            CaptionTranslationUpdate(
                turnID: current.id,
                key: request.key,
                result: .finalText("旧最终翻译"),
                request: request
            ),
            against: store
        )

        let events = try readEvents(from: eventsURL)
        XCTAssertTrue(events.contains {
            $0.event == "caption_translation_stale"
                && $0.metadata["translationKind"] == "final"
                && $0.metadata["reason"] == "translation_key_no_longer_current"
        })
    }

    func testFinalTranslationWithMissingReturnedSegmentAttachesEmptyCompletion() async {
        var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        store.upsert(hardSealedTurn(id: "segment-1", text: "hello", sourceLocale: "en-US", targetLocale: "zh-CN"))
        let provider = RecordingTextTranslationProvider(translations: ["other-segment": "不会匹配"])
        let scheduler = ReplayTranslationBackfillScheduler(
            provider: provider,
            performanceEventLogger: nil,
            configuration: ReplayTranslationBackfillSchedulerConfiguration(draftDebounceNanoseconds: 0, maxConcurrentTranslationRequests: 1)
        )

        await scheduler.scheduleTranslations(in: &store)

        XCTAssertEqual(store.turns.first?.translatedText, "")
        XCTAssertEqual(store.turns.first?.translationState, .final)
    }

    func testLatestMeetingFinalCompletionPatternAttachesOrPersistsInsteadOfStale() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("caption-translation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let eventsURL = root.appendingPathComponent("performance-events.jsonl")
        let longFinalText = String(repeating: "planning owner timeline risk ", count: 20).trimmingCharacters(in: .whitespaces)
        var originalStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        originalStore.upsert(hardSealedTurn(id: "deepgram-transcribe-stream-26.38", text: longFinalText, sourceLocale: "en-US", targetLocale: "zh-CN"))
        let provider = RecordingTextTranslationProvider(translations: ["deepgram-transcribe-stream-26.38": "完整上下文翻译"])
        var persisted: [(String, String)] = []
        let scheduler = ReplayTranslationBackfillScheduler(
            provider: provider,
            performanceEventLogger: PerformanceEventLogger(url: eventsURL),
            persistTranslation: { target, text, _ in
                persisted.append((target.primarySourceSegmentID, text))
                return true
            },
            configuration: ReplayTranslationBackfillSchedulerConfiguration(draftDebounceNanoseconds: 0, maxConcurrentTranslationRequests: 1)
        )

        let updates = await scheduler.translationUpdates(for: originalStore)
        let update = try XCTUnwrap(updates.first)
        var reshapedStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        var reshaped = draftTurn(id: "deepgram-transcribe-stream-42.43", text: "short current text", sourceLocale: "en-US", targetLocale: "zh-CN")
        reshaped.id = "current-merged-turn"
        reshaped.sourceSegmentIDs = ["deepgram-transcribe-stream-26.38", "deepgram-transcribe-stream-42.43"]
        reshapedStore.upsert(reshaped)

        let outcome = scheduler.apply(update, to: &reshapedStore)

        XCTAssertEqual(outcome, .rebound(originalTurnID: "deepgram-transcribe-stream-26.38", reboundTurnID: "current-merged-turn"))
        XCTAssertEqual(reshapedStore.turns.first?.translatedText, "完整上下文翻译")
        XCTAssertEqual(persisted.first?.0, "deepgram-transcribe-stream-26.38")
        let events = try readEvents(from: eventsURL)
        XCTAssertFalse(events.contains { $0.event == "caption_translation_stale" && $0.metadata["reason"] == "final_no_longer_current" })
        XCTAssertTrue(events.contains { $0.event == "caption_translation_attached" || $0.event == "caption_translation_persisted" })
    }

    func testHardSealedTurnMarksFailureWithNSErrorStyleMessage() async {
        var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        store.upsert(hardSealedTurn(text: "hello", sourceLocale: "en-US", targetLocale: "zh-CN"))
        let provider = RecordingTextTranslationProvider(error: NSError(domain: "translation", code: 2))
        let scheduler = ReplayTranslationBackfillScheduler(provider: provider, performanceEventLogger: nil)

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
        let scheduler = ReplayTranslationBackfillScheduler(provider: provider, performanceEventLogger: nil)

        await scheduler.scheduleTranslations(in: &store)

        XCTAssertTrue(provider.requests.isEmpty)
        XCTAssertEqual(store.turns.map(\.translationHealth), [.pending, .pending])
    }

    func testDraftTranslationKeyIncludesBoundaryStrengthWhenPresent() async {
        var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        var turn = draftTurn(text: "draft with boundary", sourceLocale: "en-US", targetLocale: "zh-CN")
        turn.boundaryReason = .punctuation
        turn.boundaryStrength = .soft
        store.upsert(turn)
        let scheduler = ReplayTranslationBackfillScheduler(provider: nil, performanceEventLogger: nil)

        let updates = await scheduler.liveTranslationUpdates(for: store)

        XCTAssertTrue(updates.isEmpty)
    }

    func testShortInitialDraftTranslationWaitsForMoreStableText() async {
        var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        store.upsert(draftTurn(text: "hello team", sourceLocale: "en-US", targetLocale: "zh-CN"))
        let provider = RecordingTextTranslationProvider(translations: ["segment-1": "大家好"])
        let scheduler = ReplayTranslationBackfillScheduler(
            provider: provider,
            performanceEventLogger: nil,
            configuration: ReplayTranslationBackfillSchedulerConfiguration(
                draftDebounceNanoseconds: 0,
                maxConcurrentTranslationRequests: 1
            )
        )

        let updates = await scheduler.liveTranslationUpdates(for: store)

        XCTAssertTrue(updates.isEmpty)
        XCTAssertTrue(provider.requests.isEmpty)
    }

    func testInitialDraftTranslationTriggersAfterMinimumInformationThreshold() async {
        var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        store.upsert(draftTurn(text: "we should review the launch owner and timeline", sourceLocale: "en-US", targetLocale: "zh-CN"))
        let provider = RecordingTextTranslationProvider(translations: ["segment-1": "翻译"])
        let scheduler = ReplayTranslationBackfillScheduler(
            provider: provider,
            performanceEventLogger: nil,
            configuration: ReplayTranslationBackfillSchedulerConfiguration(
                draftDebounceNanoseconds: 0,
                maxConcurrentTranslationRequests: 1
            )
        )

        let updates = await scheduler.liveTranslationUpdates(for: store)

        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(provider.requests.map(\.sourceText), ["we should review the launch owner and timeline"])
    }

    func testInitialDraftTranslationTriggersForSentenceBoundaryAboveShortThreshold() async {
        var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        store.upsert(draftTurn(text: "We agree.", sourceLocale: "en-US", targetLocale: "zh-CN"))
        let provider = RecordingTextTranslationProvider(translations: ["segment-1": "我们同意"])
        let scheduler = ReplayTranslationBackfillScheduler(
            provider: provider,
            performanceEventLogger: nil,
            configuration: ReplayTranslationBackfillSchedulerConfiguration(
                draftDebounceNanoseconds: 0,
                maxConcurrentTranslationRequests: 1
            )
        )

        let updates = await scheduler.liveTranslationUpdates(for: store)

        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(provider.requests.map(\.sourceText), ["We agree."])
    }

    func testFillerDraftTranslationIsSkippedUntilFinal() async {
        var draftStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        draftStore.upsert(draftTurn(text: "yeah", sourceLocale: "en-US", targetLocale: "zh-CN"))
        let provider = RecordingTextTranslationProvider(translations: ["segment-1": "是的"])
        let scheduler = ReplayTranslationBackfillScheduler(
            provider: provider,
            performanceEventLogger: nil,
            configuration: ReplayTranslationBackfillSchedulerConfiguration(
                draftDebounceNanoseconds: 0,
                maxConcurrentTranslationRequests: 1
            )
        )

        let draftUpdates = await scheduler.liveTranslationUpdates(for: draftStore)

        XCTAssertTrue(draftUpdates.isEmpty)
        XCTAssertTrue(provider.requests.isEmpty)

        var finalStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        finalStore.upsert(hardSealedTurn(text: "yeah", sourceLocale: "en-US", targetLocale: "zh-CN"))

        let finalUpdates = await scheduler.finalTranslationUpdates(for: finalStore)

        XCTAssertEqual(finalUpdates.count, 1)
        XCTAssertEqual(provider.requests.map(\.sourceText), ["yeah"])
    }

    func testFollowUpDraftSmallChangeWithinMinimumIntervalIsSkipped() async {
        var now = Date(timeIntervalSince1970: 1_000)
        let provider = RecordingTextTranslationProvider(translations: ["segment-1": "翻译"])
        let scheduler = ReplayTranslationBackfillScheduler(
            provider: provider,
            performanceEventLogger: nil,
            configuration: ReplayTranslationBackfillSchedulerConfiguration(
                draftDebounceNanoseconds: 0,
                maxConcurrentTranslationRequests: 1,
                followUpDraftMinimumIntervalNanoseconds: 1_500_000_000,
                followUpDraftMaximumWaitNanoseconds: 3_000_000_000,
                minimumDraftWordDelta: 8,
                minimumDraftCharacterDelta: 48,
                minimumInitialDraftWordCount: 1,
                minimumInitialDraftCharacterCount: 1
            ),
            now: { now }
        )
        var firstStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        firstStore.upsert(draftTurn(text: "hello team", sourceLocale: "en-US", targetLocale: "zh-CN"))
        _ = await scheduler.liveTranslationUpdates(for: firstStore)

        now = now.addingTimeInterval(0.5)
        var secondStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        secondStore.upsert(draftTurn(text: "hello team now", sourceLocale: "en-US", targetLocale: "zh-CN"))

        let updates = await scheduler.liveTranslationUpdates(for: secondStore)

        XCTAssertTrue(updates.isEmpty)
        XCTAssertEqual(provider.requests.map(\.sourceText), ["hello team"])
    }

    func testFollowUpDraftSemanticBoundaryTriggersAfterMinimumInterval() async {
        var now = Date(timeIntervalSince1970: 1_000)
        let provider = RecordingTextTranslationProvider(translations: ["segment-1": "翻译"])
        let scheduler = ReplayTranslationBackfillScheduler(
            provider: provider,
            performanceEventLogger: nil,
            configuration: ReplayTranslationBackfillSchedulerConfiguration(
                draftDebounceNanoseconds: 0,
                maxConcurrentTranslationRequests: 1,
                followUpDraftMinimumIntervalNanoseconds: 1_500_000_000,
                minimumInitialDraftWordCount: 1,
                minimumInitialDraftCharacterCount: 1
            ),
            now: { now }
        )
        var firstStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        firstStore.upsert(draftTurn(text: "we should check", sourceLocale: "en-US", targetLocale: "zh-CN"))
        _ = await scheduler.liveTranslationUpdates(for: firstStore)

        now = now.addingTimeInterval(1.6)
        var secondStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        secondStore.upsert(draftTurn(text: "we should check this,", sourceLocale: "en-US", targetLocale: "zh-CN"))

        let updates = await scheduler.liveTranslationUpdates(for: secondStore)

        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(provider.requests.map(\.sourceText), ["we should check", "we should check this,"])
    }

    func testFollowUpDraftContentDeltaTriggersAfterMinimumInterval() async {
        var now = Date(timeIntervalSince1970: 1_000)
        let provider = RecordingTextTranslationProvider(translations: ["segment-1": "翻译"])
        let scheduler = ReplayTranslationBackfillScheduler(
            provider: provider,
            performanceEventLogger: nil,
            configuration: ReplayTranslationBackfillSchedulerConfiguration(
                draftDebounceNanoseconds: 0,
                maxConcurrentTranslationRequests: 1,
                followUpDraftMinimumIntervalNanoseconds: 1_500_000_000,
                minimumDraftWordDelta: 3,
                minimumDraftCharacterDelta: 100,
                minimumInitialDraftWordCount: 1,
                minimumInitialDraftCharacterCount: 1
            ),
            now: { now }
        )
        var firstStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        firstStore.upsert(draftTurn(text: "we should check", sourceLocale: "en-US", targetLocale: "zh-CN"))
        _ = await scheduler.liveTranslationUpdates(for: firstStore)

        now = now.addingTimeInterval(1.6)
        var secondStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        secondStore.upsert(draftTurn(text: "we should check the launch owner today", sourceLocale: "en-US", targetLocale: "zh-CN"))

        let updates = await scheduler.liveTranslationUpdates(for: secondStore)

        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(provider.requests.map(\.sourceText), [
            "we should check",
            "we should check the launch owner today"
        ])
    }

    func testFollowUpDraftMaximumWaitTriggersWithoutBoundaryOrContentDelta() async {
        var now = Date(timeIntervalSince1970: 1_000)
        let provider = RecordingTextTranslationProvider(translations: ["segment-1": "翻译"])
        let scheduler = ReplayTranslationBackfillScheduler(
            provider: provider,
            performanceEventLogger: nil,
            configuration: ReplayTranslationBackfillSchedulerConfiguration(
                draftDebounceNanoseconds: 0,
                maxConcurrentTranslationRequests: 1,
                followUpDraftMinimumIntervalNanoseconds: 1_500_000_000,
                followUpDraftMaximumWaitNanoseconds: 3_000_000_000,
                minimumDraftWordDelta: 20,
                minimumDraftCharacterDelta: 200,
                minimumInitialDraftWordCount: 1,
                minimumInitialDraftCharacterCount: 1
            ),
            now: { now }
        )
        var firstStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        firstStore.upsert(draftTurn(text: "we should check", sourceLocale: "en-US", targetLocale: "zh-CN"))
        _ = await scheduler.liveTranslationUpdates(for: firstStore)

        now = now.addingTimeInterval(3.1)
        var secondStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        secondStore.upsert(draftTurn(text: "we should check this", sourceLocale: "en-US", targetLocale: "zh-CN"))

        let updates = await scheduler.liveTranslationUpdates(for: secondStore)

        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(provider.requests.map(\.sourceText), ["we should check", "we should check this"])
    }

    func testDraftInFlightSuppressesRedundantRequestForSameTurn() async throws {
        var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        store.upsert(draftTurn(text: "first draft includes enough context to translate", sourceLocale: "en-US", targetLocale: "zh-CN"))
        let provider = CancellationRecordingTextTranslationProvider()
        let scheduler = ReplayTranslationBackfillScheduler(
            provider: provider,
            performanceEventLogger: nil,
            configuration: ReplayTranslationBackfillSchedulerConfiguration(draftDebounceNanoseconds: 0, maxConcurrentTranslationRequests: 1)
        )

        let firstTask = Task {
            await scheduler.liveTranslationUpdates(for: store)
        }
        try await waitForSchedulerCondition { provider.startedRequestCount == 1 }

        var updatedStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        updatedStore.upsert(draftTurn(text: "first draft changed enough,", sourceLocale: "en-US", targetLocale: "zh-CN"))
        let secondUpdates = await scheduler.liveTranslationUpdates(for: updatedStore)

        XCTAssertTrue(secondUpdates.isEmpty)
        XCTAssertEqual(provider.startedRequestCount, 1)
        provider.completeAll()
        _ = await firstTask.value
    }

    func testDraftTriggerPolicyLogsTriggeredAndSkippedReasons() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("caption-translation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let eventsURL = root.appendingPathComponent("performance-events.jsonl")
        var now = Date(timeIntervalSince1970: 1_000)
        var firstStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        firstStore.upsert(draftTurn(text: "hello team", sourceLocale: "en-US", targetLocale: "zh-CN"))
        let provider = RecordingTextTranslationProvider(translations: ["segment-1": "大家好"])
        let scheduler = ReplayTranslationBackfillScheduler(
            provider: provider,
            performanceEventLogger: PerformanceEventLogger(url: eventsURL),
            configuration: ReplayTranslationBackfillSchedulerConfiguration(
                draftDebounceNanoseconds: 0,
                maxConcurrentTranslationRequests: 1,
                followUpDraftMinimumIntervalNanoseconds: 1_500_000_000,
                followUpDraftMaximumWaitNanoseconds: 3_000_000_000,
                minimumDraftWordDelta: 8,
                minimumDraftCharacterDelta: 48,
                minimumInitialDraftWordCount: 1,
                minimumInitialDraftCharacterCount: 1
            ),
            now: { now }
        )

        for update in await scheduler.liveTranslationUpdates(for: firstStore) {
            scheduler.apply(update, to: &firstStore)
        }

        now = now.addingTimeInterval(0.4)
        var secondStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        secondStore.upsert(draftTurn(text: "hello team now", sourceLocale: "en-US", targetLocale: "zh-CN"))
        let skippedUpdates = await scheduler.liveTranslationUpdates(for: secondStore)

        let events = try readEvents(from: eventsURL)
        let triggered = try XCTUnwrap(events.first { $0.event == "caption_translation_draft_triggered" })
        XCTAssertEqual(triggered.metadata["reason"], "initial")
        XCTAssertEqual(triggered.metadata["wordDelta"], "2")
        XCTAssertEqual(triggered.metadata["characterDelta"], "10")
        XCTAssertEqual(triggered.metadata["hasSemanticBoundary"], "false")

        let skipped = try XCTUnwrap(events.first { $0.event == "caption_translation_draft_skipped" })
        XCTAssertEqual(skipped.metadata["reason"], "min_interval")
        XCTAssertEqual(skipped.metadata["wordDelta"], "1")
        XCTAssertEqual(skipped.metadata["characterDelta"], "4")
        XCTAssertEqual(skipped.metadata["millisecondsSinceLastDraftRequest"], "400")
        XCTAssertEqual(skipped.metadata["millisecondsSinceLastVisibleDraftTranslation"], "400")
        XCTAssertTrue(skippedUpdates.isEmpty)
        XCTAssertEqual(provider.requests.map(\.sourceText), ["hello team"])
    }

    func testHardFinalTranslationBypassesDraftTriggerMinimumInterval() async {
        var now = Date(timeIntervalSince1970: 1_000)
        var draftStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        draftStore.upsert(draftTurn(text: "same words", sourceLocale: "en-US", targetLocale: "zh-CN"))
        let provider = RecordingTextTranslationProvider(translations: ["segment-1": "翻译"])
        let scheduler = ReplayTranslationBackfillScheduler(
            provider: provider,
            performanceEventLogger: nil,
            configuration: ReplayTranslationBackfillSchedulerConfiguration(
                draftDebounceNanoseconds: 0,
                maxConcurrentTranslationRequests: 1,
                followUpDraftMinimumIntervalNanoseconds: 10_000_000_000,
                minimumInitialDraftWordCount: 1,
                minimumInitialDraftCharacterCount: 1
            ),
            now: { now }
        )
        _ = await scheduler.liveTranslationUpdates(for: draftStore)

        now = now.addingTimeInterval(0.2)
        var finalStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        finalStore.upsert(hardSealedTurn(text: "same words", sourceLocale: "en-US", targetLocale: "zh-CN"))

        let finalUpdates = await scheduler.finalTranslationUpdates(for: finalStore)

        XCTAssertEqual(finalUpdates.count, 1)
        XCTAssertEqual(provider.requests.map(\.sourceText), ["same words", "same words"])
    }

    func testNilProviderLeavesHardSealedTranslationPending() async {
        var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        store.upsert(hardSealedTurn(text: "hello", sourceLocale: "en-US", targetLocale: "zh-CN"))
        let scheduler = ReplayTranslationBackfillScheduler(provider: nil, performanceEventLogger: nil)

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
        let scheduler = ReplayTranslationBackfillScheduler(
            provider: provider,
            performanceEventLogger: PerformanceEventLogger(url: eventsURL),
            configuration: ReplayTranslationBackfillSchedulerConfiguration(
                draftDebounceNanoseconds: 0,
                maxConcurrentTranslationRequests: 2,
                minimumInitialDraftWordCount: 1,
                minimumInitialDraftCharacterCount: 1
            )
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
        firstStore.upsert(draftTurn(text: "old draft contains enough context to translate", sourceLocale: "en-US", targetLocale: "zh-CN"))
        var secondStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        secondStore.upsert(draftTurn(text: "new draft contains enough context to translate", sourceLocale: "en-US", targetLocale: "zh-CN"))
        let firstStoreSnapshot = firstStore
        let provider = RecordingTextTranslationProvider(translations: ["segment-1": "新草稿"])
        let scheduler = ReplayTranslationBackfillScheduler(
            provider: provider,
            performanceEventLogger: nil,
            configuration: ReplayTranslationBackfillSchedulerConfiguration(draftDebounceNanoseconds: 30_000_000, maxConcurrentTranslationRequests: 2)
        )

        async let firstUpdates = scheduler.liveTranslationUpdates(for: firstStoreSnapshot)
        try? await Task.sleep(nanoseconds: 5_000_000)
        let secondUpdates = await scheduler.liveTranslationUpdates(for: secondStore)
        let resolvedFirstUpdates = await firstUpdates

        XCTAssertTrue(resolvedFirstUpdates.isEmpty)
        XCTAssertEqual(secondUpdates.count, 1)
        XCTAssertEqual(provider.requests.map(\.sourceText), ["new draft contains enough context to translate"])
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
        let scheduler = ReplayTranslationBackfillScheduler(
            provider: provider,
            performanceEventLogger: PerformanceEventLogger(url: eventsURL),
            configuration: ReplayTranslationBackfillSchedulerConfiguration(draftDebounceNanoseconds: 30_000_000, maxConcurrentTranslationRequests: 2)
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
        let scheduler = ReplayTranslationBackfillScheduler(
            provider: provider,
            performanceEventLogger: PerformanceEventLogger(url: eventsURL),
            configuration: ReplayTranslationBackfillSchedulerConfiguration(
                draftDebounceNanoseconds: 0,
                maxConcurrentTranslationRequests: 2,
                minimumInitialDraftWordCount: 1,
                minimumInitialDraftCharacterCount: 1
            )
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
        let scheduler = ReplayTranslationBackfillScheduler(
            provider: provider,
            performanceEventLogger: PerformanceEventLogger(url: eventsURL),
            configuration: ReplayTranslationBackfillSchedulerConfiguration(
                draftDebounceNanoseconds: 0,
                maxConcurrentTranslationRequests: 2,
                minimumInitialDraftWordCount: 1,
                minimumInitialDraftCharacterCount: 1
            )
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
        let scheduler = ReplayTranslationBackfillScheduler(
            provider: provider,
            performanceEventLogger: PerformanceEventLogger(url: eventsURL),
            configuration: ReplayTranslationBackfillSchedulerConfiguration(draftDebounceNanoseconds: 0, maxConcurrentTranslationRequests: 2)
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
        let scheduler = ReplayTranslationBackfillScheduler(
            provider: provider,
            performanceEventLogger: nil,
            configuration: ReplayTranslationBackfillSchedulerConfiguration(draftDebounceNanoseconds: 0, maxConcurrentTranslationRequests: 2)
        )

        let updates = await scheduler.translationUpdates(for: store)

        XCTAssertEqual(updates.count, 3)
        XCTAssertEqual(provider.maximumConcurrentRequests, 2)
    }

    func testCancellingSchedulingTaskDoesNotCancelProviderRequest() async throws {
        var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        store.upsert(hardSealedTurn(text: "do not cancel network", sourceLocale: "en-US", targetLocale: "zh-CN"))
        let provider = CancellationRecordingTextTranslationProvider()
        let scheduler = ReplayTranslationBackfillScheduler(
            provider: provider,
            performanceEventLogger: nil,
            configuration: ReplayTranslationBackfillSchedulerConfiguration(draftDebounceNanoseconds: 0, maxConcurrentTranslationRequests: 1)
        )

        let task = Task {
            await scheduler.translationUpdates(for: store)
        }
        try await waitForSchedulerCondition { provider.startedRequestCount == 1 }
        task.cancel()
        try await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertEqual(provider.cancelledRequestCount, 0)
        provider.completeAll()
        let updates = await task.value
        XCTAssertEqual(updates.first?.result, .finalText("translated"))
    }

    func testDraftTranslationApproximateAttachesForStablePrefix() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("caption-translation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let eventsURL = root.appendingPathComponent("performance-events.jsonl")
        let scheduler = ReplayTranslationBackfillScheduler(
            provider: RecordingTextTranslationProvider(translations: ["segment-1": "我们应该审查发布计划"]),
            performanceEventLogger: PerformanceEventLogger(url: eventsURL),
            configuration: ReplayTranslationBackfillSchedulerConfiguration(
                draftDebounceNanoseconds: 0,
                maxConcurrentTranslationRequests: 1,
                minimumInitialDraftWordCount: 1,
                minimumInitialDraftCharacterCount: 1
            ),
            now: { Date(timeIntervalSince1970: 12) }
        )
        var originalStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        originalStore.upsert(draftTurn(text: "We should review the rollout plan", sourceLocale: "en-US", targetLocale: "zh-CN"))

        let updates = await scheduler.liveTranslationUpdates(for: originalStore)
        let update = try XCTUnwrap(updates.first)
        var currentStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        currentStore.upsert(draftTurn(text: "We should review the rollout plan today", sourceLocale: "en-US", targetLocale: "zh-CN"))

        let outcome = scheduler.apply(update, to: &currentStore)

        XCTAssertEqual(outcome, .attached(turnID: "segment-1"))
        XCTAssertEqual(currentStore.turns.first?.translatedText, "我们应该审查发布计划")
        XCTAssertEqual(currentStore.turns.first?.translationFreshness, .approximate)
        let events = try readEvents(from: eventsURL)
        XCTAssertTrue(events.contains { $0.event == "caption_translation_approximate_attached" })
        XCTAssertFalse(events.contains { $0.event == "caption_translation_hidden_stale" })
    }

    func testDraftTranslationHiddenStaleForUnrelatedCurrentText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("caption-translation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let eventsURL = root.appendingPathComponent("performance-events.jsonl")
        let scheduler = ReplayTranslationBackfillScheduler(
            provider: RecordingTextTranslationProvider(translations: ["segment-1": "旧翻译"]),
            performanceEventLogger: PerformanceEventLogger(url: eventsURL),
            configuration: ReplayTranslationBackfillSchedulerConfiguration(
                draftDebounceNanoseconds: 0,
                maxConcurrentTranslationRequests: 1,
                minimumInitialDraftWordCount: 1,
                minimumInitialDraftCharacterCount: 1
            )
        )
        var originalStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        originalStore.upsert(draftTurn(text: "We should review the rollout plan", sourceLocale: "en-US", targetLocale: "zh-CN"))

        let updates = await scheduler.liveTranslationUpdates(for: originalStore)
        let update = try XCTUnwrap(updates.first)
        var currentStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        currentStore.upsert(draftTurn(text: "Completely different speaker content", sourceLocale: "en-US", targetLocale: "zh-CN"))

        let outcome = scheduler.apply(update, to: &currentStore)

        XCTAssertEqual(outcome, .none)
        XCTAssertNil(currentStore.turns.first?.translatedText)
        let events = try readEvents(from: eventsURL)
        XCTAssertTrue(events.contains { $0.event == "caption_translation_hidden_stale" })
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

private final class CancellationRecordingTextTranslationProvider: TextTranslationProvider {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<TranslatedTranscript, Error>] = []
    private var cancelledRequests = 0
    private var startedRequests = 0

    var startedRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return startedRequests
    }

    var cancelledRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cancelledRequests
    }

    var descriptor: ProviderDescriptor {
        ProviderDescriptor(
            id: "cancellation-recording-translation",
            displayName: "Cancellation Recording Translation",
            capability: .textTranslation,
            executionMode: .hosted,
            supportedSourceLocales: ["*"],
            supportedTargetLocales: ["*"],
            requiresNetwork: true,
            requiresAPIKey: true
        )
    }

    func translate(transcript: TranscriptDocument, options: TranslationOptions) async throws -> TranslatedTranscript {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                startedRequests += 1
                continuations.append(continuation)
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            cancelledRequests += 1
            let pending = continuations
            continuations = []
            lock.unlock()
            for continuation in pending {
                continuation.resume(throwing: CancellationError())
            }
        }
    }

    func completeAll() {
        lock.lock()
        let pending = continuations
        continuations = []
        lock.unlock()
        for continuation in pending {
            continuation.resume(returning: TranslatedTranscript(
                sourceLocale: "en-US",
                targetLocale: "zh-CN",
                segments: [
                    BilingualSubtitleSegment(
                        id: "segment-1",
                        speaker: .default,
                        sourceText: "do not cancel network",
                        targetText: "translated",
                        status: .complete,
                        providerChain: [descriptor.id]
                    )
                ],
                provenance: PipelineProvenance(profileID: "cancellation-recording")
            ))
        }
    }
}

private func waitForSchedulerCondition(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    condition: @escaping () -> Bool
) async throws {
    let start = DispatchTime.now().uptimeNanoseconds
    while !condition() {
        if DispatchTime.now().uptimeNanoseconds - start > timeoutNanoseconds {
            XCTFail("Timed out waiting for scheduler condition")
            return
        }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}
