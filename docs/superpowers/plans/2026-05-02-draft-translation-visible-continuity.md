# Draft Translation Visible Continuity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make draft translations remain visibly useful when provider results return slightly behind mutable Deepgram draft captions.

**Architecture:** Add translation freshness metadata to live caption turns, classify draft completions as exact, approximate, or hidden stale in `CaptionTranslationScheduler`, preserve carried-forward visible translations in `LiveCaptionStore`, and extend the performance analysis script with user-facing visibility metrics. Final translation remains authoritative and overrides every draft freshness state.

**Tech Stack:** Swift 5.9, XCTest, Swift Package Manager, existing JSONL performance telemetry, `scripts/analyze-meeting-performance.swift`.

---

### Task 1: Add Live Caption Translation Freshness Metadata

**Files:**
- Modify: `Sources/MeetingAgentCore/LiveMeetingCockpit.swift`
- Test: `Tests/MeetingAgentCoreTests/LiveCaptionStoreTests.swift`

- [ ] **Step 1: Write failing tests**

Add tests proving translated text is carried with freshness metadata and final translation overrides it:

```swift
func testDraftTranslationCarriesForwardWhenDraftTextChanges() {
    var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
    store.upsert(LiveCaptionTurn(sourceSegmentID: "segment-1", originalText: "We should review the rollout plan", isFinal: false, chunkState: .draft))
    store.attachTranslation(
        "我们应该审查发布计划",
        toTurnID: "segment-1",
        freshness: .approximate,
        sourceText: "We should review the rollout plan",
        sourceCreatedAt: Date(timeIntervalSince1970: 10)
    )

    let updated = store.upsert(LiveCaptionTurn(sourceSegmentID: "segment-1", originalText: "We should review the rollout plan today", isFinal: false, chunkState: .draft))

    XCTAssertEqual(updated.translatedText, "我们应该审查发布计划")
    XCTAssertEqual(updated.translationFreshness, .carried)
    XCTAssertEqual(updated.translationSourceText, "We should review the rollout plan")
}

func testFinalTranslationMarksFreshnessFinal() {
    var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
    store.upsert(LiveCaptionTurn(sourceSegmentID: "segment-1", originalText: "Final words", isFinal: true))

    store.attachTranslation("最终内容", toTurnID: "segment-1", freshness: .fresh, sourceText: "Final words")
    store.markTranslationFinal(forTurnID: "segment-1")

    XCTAssertEqual(store.turns.first?.translationFreshness, .final)
    XCTAssertEqual(store.turns.first?.translationState, .final)
}
```

- [ ] **Step 2: Run tests to verify RED**

Run:

```bash
swift test --filter LiveCaptionStoreTests/testDraftTranslationCarriesForwardWhenDraftTextChanges
swift test --filter LiveCaptionStoreTests/testFinalTranslationMarksFreshnessFinal
```

Expected: fail because `translationFreshness`, `translationSourceText`, and the extended `attachTranslation` API do not exist.

- [ ] **Step 3: Implement metadata**

Add `LiveCaptionTranslationFreshness: String, Codable, Equatable` with cases `fresh`, `approximate`, `carried`, `final`. Add optional `translationSourceText`, `translationSourceCreatedAt`, and `visibleTranslationUpdatedAt` fields to `LiveCaptionTurn`. Preserve Codable backward compatibility by decoding these fields as optional and defaulting freshness to `.final` for final translated turns, `.fresh` for translated draft turns, and `nil` when no translation exists.

Extend `LiveCaptionStore.attachTranslation` to accept defaulted parameters:

```swift
public mutating func attachTranslation(
    _ text: String,
    toTurnID turnID: String,
    freshness: LiveCaptionTranslationFreshness = .fresh,
    sourceText: String? = nil,
    sourceCreatedAt: Date? = nil,
    visibleUpdatedAt: Date = Date()
)
```

When draft text changes but previous translated text is preserved, mark freshness `.carried` and keep the previous `translationSourceText`.

- [ ] **Step 4: Run tests to verify GREEN**

Run:

```bash
swift test --filter LiveCaptionStoreTests
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingAgentCore/LiveMeetingCockpit.swift Tests/MeetingAgentCoreTests/LiveCaptionStoreTests.swift
git commit -m "feat: track live caption translation freshness"
```

### Task 2: Classify Draft Translation Completion Visibility

**Files:**
- Modify: `Sources/MeetingAgentCore/CaptionTranslationScheduler.swift`
- Test: `Tests/MeetingAgentCoreTests/CaptionTranslationSchedulerTests.swift`

- [ ] **Step 1: Write failing tests**

Add tests for exact attach, approximate attach, and hidden stale:

```swift
func testDraftTranslationApproximateAttachesForStablePrefix() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("caption-translation-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let eventsURL = root.appendingPathComponent("performance-events.jsonl")
    let scheduler = CaptionTranslationScheduler(
        provider: RecordingTextTranslationProvider(translations: ["segment-1": "我们应该审查发布计划"]),
        performanceEventLogger: PerformanceEventLogger(url: eventsURL),
        configuration: CaptionTranslationSchedulerConfiguration(draftDebounceNanoseconds: 0, maxConcurrentTranslationRequests: 1),
        now: { Date(timeIntervalSince1970: 12) }
    )
    var originalStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
    originalStore.upsert(draftTurn(text: "We should review the rollout plan", sourceLocale: "en-US", targetLocale: "zh-CN"))

    let update = try XCTUnwrap(await scheduler.liveTranslationUpdates(for: originalStore).first)
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
    let scheduler = CaptionTranslationScheduler(
        provider: RecordingTextTranslationProvider(translations: ["segment-1": "旧翻译"]),
        performanceEventLogger: PerformanceEventLogger(url: eventsURL),
        configuration: CaptionTranslationSchedulerConfiguration(draftDebounceNanoseconds: 0, maxConcurrentTranslationRequests: 1)
    )
    var originalStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
    originalStore.upsert(draftTurn(text: "We should review the rollout plan", sourceLocale: "en-US", targetLocale: "zh-CN"))

    let update = try XCTUnwrap(await scheduler.liveTranslationUpdates(for: originalStore).first)
    var currentStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
    currentStore.upsert(draftTurn(text: "Completely different speaker content", sourceLocale: "en-US", targetLocale: "zh-CN"))

    let outcome = scheduler.apply(update, to: &currentStore)

    XCTAssertEqual(outcome, .none)
    XCTAssertNil(currentStore.turns.first?.translatedText)
    let events = try readEvents(from: eventsURL)
    XCTAssertTrue(events.contains { $0.event == "caption_translation_hidden_stale" })
}
```

- [ ] **Step 2: Run tests to verify RED**

Run:

```bash
swift test --filter CaptionTranslationSchedulerTests/testDraftTranslationApproximateAttachesForStablePrefix
swift test --filter CaptionTranslationSchedulerTests/testDraftTranslationHiddenStaleForUnrelatedCurrentText
```

Expected: fail because approximate attach and hidden stale events do not exist.

- [ ] **Step 3: Implement classifier**

Add configuration defaults for approximate draft attach:

```swift
public var minimumApproximateDraftCharacters: Int
public var minimumApproximateDraftWords: Int
public var maximumApproximateDraftAgeNanoseconds: UInt64
public var approximateDraftSimilarityThreshold: Double
```

Use defaults: 24 characters, 5 words, 6 seconds, 0.75 similarity.

In `apply(.draftText)`, if exact current-key validation fails, evaluate approximate attach. Allow it only for same turn, same locale pair, non-hard-final current state, minimum request length, max age, and either normalized prefix containment or token similarity above threshold. Log `caption_translation_approximate_attached` or `caption_translation_hidden_stale` with `attachDecision`, `attachRejectReason`, `sourceSimilarity`, `sourceLagCharacters`, and `sourceLagWords`. Attach approximate text with freshness `.approximate`.

- [ ] **Step 4: Run tests to verify GREEN**

Run:

```bash
swift test --filter CaptionTranslationSchedulerTests
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingAgentCore/CaptionTranslationScheduler.swift Tests/MeetingAgentCoreTests/CaptionTranslationSchedulerTests.swift
git commit -m "feat: show safe approximate draft translations"
```

### Task 3: Add Visibility Metrics To Meeting Performance Analysis

**Files:**
- Modify: `scripts/analyze-meeting-performance.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingPerformanceAnalysisScriptTests.swift`

- [ ] **Step 1: Write failing test**

Add a script test fixture with exact attach, approximate attach, hidden stale, and carried-forward events. Assert the report includes readable names:

```swift
XCTAssertTrue(output.contains("Time to First Visible Translation: 2.00s"))
XCTAssertTrue(output.contains("Visible Translation Coverage:"))
XCTAssertTrue(output.contains("Visible Translation Gap p50/p95/max:"))
XCTAssertTrue(output.contains("Exact Draft Attach Rate: 50.0%"))
XCTAssertTrue(output.contains("Approximate Draft Attach Rate: 50.0%"))
XCTAssertTrue(output.contains("Hidden Draft Stale Rate: 33.3%"))
XCTAssertTrue(output.contains("Draft Translation Carry Forward Count: 1"))
```

- [ ] **Step 2: Run test to verify RED**

Run:

```bash
swift test --filter MeetingPerformanceAnalysisScriptTests
```

Expected: fail because the new report lines do not exist.

- [ ] **Step 3: Implement script metrics**

Count `caption_translation_exact_attached`, `caption_translation_approximate_attached`, `caption_translation_hidden_stale`, and `caption_translation_carried_forward`. Treat exact and approximate attach as visible translation outcomes. Compute time to first visible translation from the first exact/approximate/final attach. Compute attach rates from visible draft attach events over visible plus hidden draft outcomes. Add readable metric labels, not abbreviation-only names.

- [ ] **Step 4: Run tests to verify GREEN**

Run:

```bash
swift test --filter MeetingPerformanceAnalysisScriptTests
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add scripts/analyze-meeting-performance.swift Tests/MeetingAgentCoreTests/MeetingPerformanceAnalysisScriptTests.swift
git commit -m "feat: report visible translation continuity metrics"
```

### Task 4: Full Verification

**Files:**
- Verify all changed files.

- [ ] **Step 1: Run focused tests**

```bash
swift test --filter LiveCaptionStoreTests
swift test --filter CaptionTranslationSchedulerTests
swift test --filter MeetingPerformanceAnalysisScriptTests
```

Expected: all pass.

- [ ] **Step 2: Run full project verification**

```bash
make test
```

Expected: 642 tests pass and coverage gate passes.

- [ ] **Step 3: Analyze latest meeting if available**

Run the existing performance script against the latest meeting log and confirm the new visible translation metrics are present. The historical log will not contain new events, so this is only a schema/readability check until a new meeting is recorded with the new build.

- [ ] **Step 4: Commit any verification-only plan updates**

If the plan checklist was updated during execution:

```bash
git add docs/superpowers/plans/2026-05-02-draft-translation-visible-continuity.md
git commit -m "docs: track draft translation continuity plan"
```
