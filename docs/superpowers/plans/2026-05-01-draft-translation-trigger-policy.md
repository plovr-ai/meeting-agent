# Draft Translation Trigger Policy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a draft translation trigger policy that keeps the first draft translation fast while reducing stale follow-up requests.

**Architecture:** Add scheduler-local draft trigger state and decision logic inside `CaptionTranslationScheduler.swift`, then route draft translation candidates through that policy before provider requests are created. Preserve the existing final translation path and extend the meeting performance script with readable draft trigger/skip metrics.

**Tech Stack:** Swift 5.9, XCTest, Swift Package Manager, existing `PerformanceEventLogger`, existing `scripts/analyze-meeting-performance.swift`.

---

## File Structure

- Modify `Sources/MeetingAgentCore/CaptionTranslationScheduler.swift`
  - Add draft trigger configuration fields.
  - Add scheduler-local draft trigger state and decision types.
  - Gate draft request creation before provider execution.
  - Emit `caption_translation_draft_triggered` and `caption_translation_draft_skipped`.
- Modify `scripts/analyze-meeting-performance.swift`
  - Count draft trigger and skip events.
  - Report draft stale rate and visible update interval with readable names.
- Modify `Tests/MeetingAgentCoreTests/CaptionTranslationSchedulerTests.swift`
  - Add policy-level and scheduler integration coverage.
- Modify `Tests/MeetingAgentCoreTests/LiveCaptionPipelineTests.swift`
  - Add regression coverage that replay and flush do not schedule draft translations.
- Modify `Tests/MeetingAgentCoreTests/MeetingPerformanceAnalysisScriptTests.swift`
  - Add fixture events for draft trigger/skip/stale analysis output.

---

### Task 1: Add Draft Trigger Configuration And Policy State

**Files:**
- Modify: `Sources/MeetingAgentCore/CaptionTranslationScheduler.swift`
- Test: `Tests/MeetingAgentCoreTests/CaptionTranslationSchedulerTests.swift`

- [ ] **Step 1: Write failing test for draft policy configuration**

Add these tests near the existing draft scheduler tests in `Tests/MeetingAgentCoreTests/CaptionTranslationSchedulerTests.swift`:

```swift
func testDraftTranslationSchedulerConfigurationExposesPolicyDefaults() {
    let configuration = CaptionTranslationSchedulerConfiguration()

    XCTAssertEqual(configuration.followUpDraftMinimumIntervalNanoseconds, 1_500_000_000)
    XCTAssertEqual(configuration.followUpDraftMaximumWaitNanoseconds, 3_000_000_000)
    XCTAssertEqual(configuration.minimumDraftWordDelta, 8)
    XCTAssertEqual(configuration.minimumDraftCharacterDelta, 48)
    XCTAssertTrue(configuration.semanticBoundaryCharacters.contains(","))
    XCTAssertTrue(configuration.semanticBoundaryCharacters.contains("。"))
}
```

- [ ] **Step 2: Run the focused tests and verify they fail**

Run:

```bash
swift test --filter CaptionTranslationSchedulerTests/testDraftTranslationSchedulerConfigurationExposesPolicyDefaults
```

Expected:

- The test fails because `CaptionTranslationSchedulerConfiguration` has no follow-up draft policy fields.

- [ ] **Step 3: Add configuration fields and scheduler clock**

In `Sources/MeetingAgentCore/CaptionTranslationScheduler.swift`, replace `CaptionTranslationSchedulerConfiguration` with:

```swift
public struct CaptionTranslationSchedulerConfiguration: Equatable {
    public var draftDebounceNanoseconds: UInt64
    public var maxConcurrentTranslationRequests: Int
    public var followUpDraftMinimumIntervalNanoseconds: UInt64
    public var followUpDraftMaximumWaitNanoseconds: UInt64
    public var minimumDraftWordDelta: Int
    public var minimumDraftCharacterDelta: Int
    public var semanticBoundaryCharacters: Set<Character>

    public init(
        draftDebounceNanoseconds: UInt64 = 200_000_000,
        maxConcurrentTranslationRequests: Int = 2,
        followUpDraftMinimumIntervalNanoseconds: UInt64 = 1_500_000_000,
        followUpDraftMaximumWaitNanoseconds: UInt64 = 3_000_000_000,
        minimumDraftWordDelta: Int = 8,
        minimumDraftCharacterDelta: Int = 48,
        semanticBoundaryCharacters: Set<Character> = Set(".?!,;:。？！、，；：\n")
    ) {
        self.draftDebounceNanoseconds = draftDebounceNanoseconds
        self.maxConcurrentTranslationRequests = max(1, maxConcurrentTranslationRequests)
        self.followUpDraftMinimumIntervalNanoseconds = followUpDraftMinimumIntervalNanoseconds
        self.followUpDraftMaximumWaitNanoseconds = followUpDraftMaximumWaitNanoseconds
        self.minimumDraftWordDelta = max(1, minimumDraftWordDelta)
        self.minimumDraftCharacterDelta = max(1, minimumDraftCharacterDelta)
        self.semanticBoundaryCharacters = semanticBoundaryCharacters
    }
}
```

Add a clock property to `CaptionTranslationScheduler`:

```swift
private let now: () -> Date
private var draftTriggerStatesByTurnID: [String: DraftTranslationTriggerState] = [:]
```

Update the scheduler initializer:

```swift
public init(
    provider: TextTranslationProvider?,
    performanceEventLogger: PerformanceEventLogger?,
    persistTranslation: ((CaptionTranslationAttachmentTarget, String, Bool) -> Bool)? = nil,
    configuration: CaptionTranslationSchedulerConfiguration = CaptionTranslationSchedulerConfiguration(),
    now: @escaping () -> Date = Date.init
) {
    self.provider = provider
    self.performanceEventLogger = performanceEventLogger
    self.persistTranslation = persistTranslation
    self.configuration = configuration
    self.now = now
}
```

Add helper types near `ActiveCaptionTranslationRequest`:

```swift
private struct DraftTranslationTriggerState: Equatable {
    var hasSentInitialRequest = false
    var lastRequestedSourceText: String = ""
    var lastRequestedWordCount = 0
    var lastRequestedCharacterCount = 0
    var lastRequestAt: Date?
    var lastVisibleTranslationAt: Date?
    var isInFlight = false
}

private enum DraftTranslationTriggerDecision: Equatable {
    case trigger(reason: String, metadata: [String: String])
    case skip(reason: String, metadata: [String: String])
}
```

- [ ] **Step 4: Add policy decision helper**

Add these private helpers inside `CaptionTranslationScheduler`:

```swift
private func draftTriggerDecision(for turn: LiveCaptionTurn, sourceText: String) -> DraftTranslationTriggerDecision {
    var state = draftTriggerStatesByTurnID[turn.id, default: DraftTranslationTriggerState()]
    let currentWordCount = wordCount(in: sourceText)
    let currentCharacterCount = sourceText.count
    let wordDelta = max(0, currentWordCount - state.lastRequestedWordCount)
    let characterDelta = max(0, currentCharacterCount - state.lastRequestedCharacterCount)
    let hasBoundary = hasSemanticBoundary(sourceText)
    let currentTime = now()

    var metadata: [String: String] = [
        "wordDelta": String(wordDelta),
        "characterDelta": String(characterDelta),
        "hasSemanticBoundary": String(hasBoundary)
    ]

    if let lastRequestAt = state.lastRequestAt {
        metadata["millisecondsSinceLastDraftRequest"] = String(milliseconds(from: lastRequestAt, to: currentTime))
    }
    if let lastVisibleTranslationAt = state.lastVisibleTranslationAt {
        metadata["millisecondsSinceLastVisibleDraftTranslation"] = String(milliseconds(from: lastVisibleTranslationAt, to: currentTime))
    }

    guard !state.isInFlight else {
        return .skip(reason: "in_flight", metadata: metadata)
    }

    guard state.hasSentInitialRequest else {
        state.hasSentInitialRequest = true
        state.lastRequestedSourceText = sourceText
        state.lastRequestedWordCount = currentWordCount
        state.lastRequestedCharacterCount = currentCharacterCount
        state.lastRequestAt = currentTime
        state.isInFlight = true
        draftTriggerStatesByTurnID[turn.id] = state
        return .trigger(reason: "initial", metadata: metadata)
    }

    if let lastRequestAt = state.lastRequestAt,
       nanoseconds(from: lastRequestAt, to: currentTime) < configuration.followUpDraftMinimumIntervalNanoseconds {
        return .skip(reason: "min_interval", metadata: metadata)
    }

    let exceededMaximumWait: Bool = {
        guard let lastVisibleTranslationAt = state.lastVisibleTranslationAt ?? state.lastRequestAt else {
            return false
        }
        return nanoseconds(from: lastVisibleTranslationAt, to: currentTime) >= configuration.followUpDraftMaximumWaitNanoseconds
    }()

    let reachedContentDelta = wordDelta >= configuration.minimumDraftWordDelta
        || characterDelta >= configuration.minimumDraftCharacterDelta

    guard hasBoundary || reachedContentDelta || exceededMaximumWait else {
        return .skip(reason: "not_stable_enough", metadata: metadata)
    }

    let reason: String
    if hasBoundary {
        reason = "semantic_boundary"
    } else if reachedContentDelta {
        reason = "content_delta"
    } else {
        reason = "max_wait"
    }
    state.lastRequestedSourceText = sourceText
    state.lastRequestedWordCount = currentWordCount
    state.lastRequestedCharacterCount = currentCharacterCount
    state.lastRequestAt = currentTime
    state.isInFlight = true
    draftTriggerStatesByTurnID[turn.id] = state
    return .trigger(reason: reason, metadata: metadata)
}

private func hasSemanticBoundary(_ text: String) -> Bool {
    guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else {
        return false
    }
    return configuration.semanticBoundaryCharacters.contains(last)
}

private func wordCount(in text: String) -> Int {
    text.split { $0.isWhitespace || $0.isNewline }.count
}

private func nanoseconds(from start: Date, to end: Date) -> UInt64 {
    UInt64(max(0, end.timeIntervalSince(start)) * 1_000_000_000)
}

private func milliseconds(from start: Date, to end: Date) -> Int {
    max(0, Int((end.timeIntervalSince(start) * 1_000).rounded()))
}
```

- [ ] **Step 5: Run focused tests**

Run:

```bash
swift test --filter CaptionTranslationSchedulerTests/testDraftTranslationSchedulerConfigurationExposesPolicyDefaults
```

Expected:

- The configuration test passes.

- [ ] **Step 6: Commit configuration and policy scaffold**

Commit only the scheduler and tests added in this task:

```bash
git add Sources/MeetingAgentCore/CaptionTranslationScheduler.swift Tests/MeetingAgentCoreTests/CaptionTranslationSchedulerTests.swift
git commit -m "test: define draft translation trigger policy"
```

---

### Task 2: Gate Draft Request Creation Through The Policy

**Files:**
- Modify: `Sources/MeetingAgentCore/CaptionTranslationScheduler.swift`
- Test: `Tests/MeetingAgentCoreTests/CaptionTranslationSchedulerTests.swift`

- [ ] **Step 1: Add tests for initial trigger, min interval, semantic boundary, content delta, max wait, and in-flight skip**

Add these tests to `CaptionTranslationSchedulerTests`:

```swift
func testInitialDraftTranslationTriggersQuickly() async {
    var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
    store.upsert(draftTurn(text: "hello team", sourceLocale: "en-US", targetLocale: "zh-CN"))
    let provider = RecordingTextTranslationProvider(translations: ["segment-1": "大家好"])
    let scheduler = CaptionTranslationScheduler(
        provider: provider,
        performanceEventLogger: nil,
        configuration: CaptionTranslationSchedulerConfiguration(
            draftDebounceNanoseconds: 0,
            maxConcurrentTranslationRequests: 1
        )
    )

    let updates = await scheduler.liveTranslationUpdates(for: store)

    XCTAssertEqual(updates.count, 1)
    XCTAssertEqual(provider.requests.map(\.sourceText), ["hello team"])
}

func testFollowUpDraftSmallChangeWithinMinimumIntervalIsSkipped() async {
    var now = Date(timeIntervalSince1970: 1_000)
    let provider = RecordingTextTranslationProvider(translations: ["segment-1": "翻译"])
    let scheduler = CaptionTranslationScheduler(
        provider: provider,
        performanceEventLogger: nil,
        configuration: CaptionTranslationSchedulerConfiguration(
            draftDebounceNanoseconds: 0,
            maxConcurrentTranslationRequests: 1,
            followUpDraftMinimumIntervalNanoseconds: 1_500_000_000,
            followUpDraftMaximumWaitNanoseconds: 3_000_000_000,
            minimumDraftWordDelta: 8,
            minimumDraftCharacterDelta: 48
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
    let scheduler = CaptionTranslationScheduler(
        provider: provider,
        performanceEventLogger: nil,
        configuration: CaptionTranslationSchedulerConfiguration(
            draftDebounceNanoseconds: 0,
            maxConcurrentTranslationRequests: 1,
            followUpDraftMinimumIntervalNanoseconds: 1_500_000_000
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
    let scheduler = CaptionTranslationScheduler(
        provider: provider,
        performanceEventLogger: nil,
        configuration: CaptionTranslationSchedulerConfiguration(
            draftDebounceNanoseconds: 0,
            maxConcurrentTranslationRequests: 1,
            followUpDraftMinimumIntervalNanoseconds: 1_500_000_000,
            minimumDraftWordDelta: 3,
            minimumDraftCharacterDelta: 100
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
    let scheduler = CaptionTranslationScheduler(
        provider: provider,
        performanceEventLogger: nil,
        configuration: CaptionTranslationSchedulerConfiguration(
            draftDebounceNanoseconds: 0,
            maxConcurrentTranslationRequests: 1,
            followUpDraftMinimumIntervalNanoseconds: 1_500_000_000,
            followUpDraftMaximumWaitNanoseconds: 3_000_000_000,
            minimumDraftWordDelta: 20,
            minimumDraftCharacterDelta: 200
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
    store.upsert(draftTurn(text: "first draft", sourceLocale: "en-US", targetLocale: "zh-CN"))
    let provider = CancellationRecordingTextTranslationProvider()
    let scheduler = CaptionTranslationScheduler(
        provider: provider,
        performanceEventLogger: nil,
        configuration: CaptionTranslationSchedulerConfiguration(draftDebounceNanoseconds: 0, maxConcurrentTranslationRequests: 1)
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
```

- [ ] **Step 2: Run tests and verify failures**

Run:

```bash
swift test --filter CaptionTranslationSchedulerTests/testFollowUpDraftSemanticBoundaryTriggersAfterMinimumInterval
swift test --filter CaptionTranslationSchedulerTests/testFollowUpDraftSmallChangeWithinMinimumIntervalIsSkipped
swift test --filter CaptionTranslationSchedulerTests/testFollowUpDraftContentDeltaTriggersAfterMinimumInterval
swift test --filter CaptionTranslationSchedulerTests/testFollowUpDraftMaximumWaitTriggersWithoutBoundaryOrContentDelta
swift test --filter CaptionTranslationSchedulerTests/testDraftInFlightSuppressesRedundantRequestForSameTurn
```

Expected:

- Tests fail because draft policy decisions are not yet used in `translationExecution(for:in:includingDrafts:)`.

- [ ] **Step 3: Wire policy before draft request creation**

In `translationExecution(for:in:includingDrafts:)`, after `guard let provider else { return nil }` and after final handling, add:

```swift
var draftDecisionMetadata: [String: String] = [:]
if !isFinalTranslation {
    let decision = draftTriggerDecision(for: turn, sourceText: sourceText)
    switch decision {
    case .trigger(let reason, let metadata):
        draftDecisionMetadata = metadata
        performanceEventLogger?.log(
            "caption_translation_draft_triggered",
            segmentID: turn.id,
            isFinal: false,
            textLength: turn.originalText.count,
            metadata: metadata.merging(["reason": reason]) { current, _ in current }
        )
    case .skip(let reason, let metadata):
        performanceEventLogger?.log(
            "caption_translation_draft_skipped",
            segmentID: turn.id,
            isFinal: false,
            textLength: turn.originalText.count,
            metadata: metadata.merging(["reason": reason]) { current, _ in current }
        )
        return nil
    }
}
```

When logging `caption_translation_scheduled`, merge `draftDecisionMetadata` for draft requests:

```swift
let metadata = translationMetadata(for: request, extra: request.isDraft ? draftDecisionMetadata : [:])
```

- [ ] **Step 4: Clear in-flight state after provider completion and record visible time only after attach**

After the `for update in updates { activeRequestsByKey.removeValue(forKey: update.key) }` loop in `execute(_:)`, clear draft in-flight state:

```swift
for update in updates {
    activeRequestsByKey.removeValue(forKey: update.key)
    if let request = update.request, request.isDraft {
        markDraftRequestFinished(forTurnID: request.turn.id)
    }
}
```

Add these helpers:

```swift
private func markDraftRequestFinished(forTurnID turnID: String) {
    guard var state = draftTriggerStatesByTurnID[turnID] else { return }
    state.isInFlight = false
    draftTriggerStatesByTurnID[turnID] = state
}

private func markDraftTranslationVisible(forTurnID turnID: String) {
    guard var state = draftTriggerStatesByTurnID[turnID] else { return }
    state.lastVisibleTranslationAt = now()
    draftTriggerStatesByTurnID[turnID] = state
}
```

In the `.draftText` success branch of `apply(_:to:)`, after `store.attachTranslation(text, toTurnID: update.turnID)`, add:

```swift
markDraftTranslationVisible(forTurnID: update.turnID)
```

In `cancelDraftsSuperseded(by:)`, after removing a request, clear the state:

```swift
if var state = draftTriggerStatesByTurnID[request.turn.id] {
    state.isInFlight = false
    draftTriggerStatesByTurnID[request.turn.id] = state
}
```

- [ ] **Step 5: Run focused scheduler tests**

Run:

```bash
swift test --filter CaptionTranslationSchedulerTests
```

Expected:

- All scheduler tests pass.

- [ ] **Step 6: Commit scheduler integration**

```bash
git add Sources/MeetingAgentCore/CaptionTranslationScheduler.swift Tests/MeetingAgentCoreTests/CaptionTranslationSchedulerTests.swift
git commit -m "feat: gate draft translation triggers"
```

---

### Task 3: Add Draft Trigger Telemetry Coverage And Preserve Final Behavior

**Files:**
- Modify: `Tests/MeetingAgentCoreTests/CaptionTranslationSchedulerTests.swift`
- Modify: `Tests/MeetingAgentCoreTests/LiveCaptionPipelineTests.swift`

- [ ] **Step 1: Add telemetry assertions for trigger and skip events**

Add this test to `CaptionTranslationSchedulerTests`:

```swift
func testDraftTriggerPolicyLogsTriggeredAndSkippedReasons() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("draft-trigger-policy-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let eventsURL = root.appendingPathComponent("performance-events.jsonl")
    var now = Date(timeIntervalSince1970: 1_000)
    let provider = RecordingTextTranslationProvider(translations: ["segment-1": "翻译"])
    let scheduler = CaptionTranslationScheduler(
        provider: provider,
        performanceEventLogger: PerformanceEventLogger(url: eventsURL),
        configuration: CaptionTranslationSchedulerConfiguration(
            draftDebounceNanoseconds: 0,
            maxConcurrentTranslationRequests: 1,
            followUpDraftMinimumIntervalNanoseconds: 1_500_000_000
        ),
        now: { now }
    )
    var firstStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
    firstStore.upsert(draftTurn(text: "first draft", sourceLocale: "en-US", targetLocale: "zh-CN"))
    _ = await scheduler.liveTranslationUpdates(for: firstStore)

    now = now.addingTimeInterval(0.4)
    var secondStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
    secondStore.upsert(draftTurn(text: "first draft small", sourceLocale: "en-US", targetLocale: "zh-CN"))
    _ = await scheduler.liveTranslationUpdates(for: secondStore)

    let events = try readEvents(from: eventsURL)
    XCTAssertTrue(events.contains {
        $0.event == "caption_translation_draft_triggered"
            && $0.metadata["reason"] == "initial"
            && $0.metadata["wordDelta"] != nil
            && $0.metadata["characterDelta"] != nil
    })
    XCTAssertTrue(events.contains {
        $0.event == "caption_translation_draft_skipped"
            && $0.metadata["reason"] == "min_interval"
    })
}
```

- [ ] **Step 2: Add final regression test**

Add this test to `CaptionTranslationSchedulerTests`:

```swift
func testHardFinalTranslationBypassesDraftTriggerMinimumInterval() async {
    var now = Date(timeIntervalSince1970: 1_000)
    let provider = RecordingTextTranslationProvider(translations: ["segment-1": "最终"])
    let scheduler = CaptionTranslationScheduler(
        provider: provider,
        performanceEventLogger: nil,
        configuration: CaptionTranslationSchedulerConfiguration(
            draftDebounceNanoseconds: 0,
            maxConcurrentTranslationRequests: 1,
            followUpDraftMinimumIntervalNanoseconds: 10_000_000_000
        ),
        now: { now }
    )
    var draftStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
    draftStore.upsert(draftTurn(text: "same words", sourceLocale: "en-US", targetLocale: "zh-CN"))
    _ = await scheduler.liveTranslationUpdates(for: draftStore)

    now = now.addingTimeInterval(0.1)
    var finalStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
    finalStore.upsert(hardSealedTurn(text: "same words", sourceLocale: "en-US", targetLocale: "zh-CN"))

    let updates = await scheduler.finalTranslationUpdates(for: finalStore)

    XCTAssertEqual(updates.count, 1)
    XCTAssertEqual(provider.requests.map(\.sourceText), ["same words", "same words"])
}
```

- [ ] **Step 3: Add pipeline regression for replay and flush**

In `LiveCaptionPipelineTests.testReplayDoesNotScheduleDraftTranslations`, add these assertions after reading `events`:

```swift
let events = try readPipelineEvents(from: eventsURL)
XCTAssertFalse(events.contains { $0.event == "caption_translation_draft_triggered" })
XCTAssertFalse(events.contains { $0.event == "caption_translation_draft_skipped" && $0.metadata["reason"] != "superseded_by_final" })
```

Add this flush regression test to `LiveCaptionPipelineTests`:

```swift
func testFlushDoesNotScheduleDraftTranslationPolicyEvents() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("live-caption-flush-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let eventsURL = root.appendingPathComponent("performance-events.jsonl")
    let provider = PipelineRecordingTranslationProvider(translations: ["segment-1": "翻译"])
    let pipeline = LiveCaptionPipeline(
        sourceLocale: "en-US",
        targetLocale: "zh-CN",
        translationProvider: provider,
        performanceEventLogger: PerformanceEventLogger(url: eventsURL)
    )
    let document = TranscriptDocument(segments: [
        TranscriptSegment(id: "segment-1", text: "draft only", language: "en-US", isFinal: false)
    ])
    _ = await pipeline.apply(TranscriptSegmentAccumulationResult(
        document: document,
        changedSegmentIDs: ["segment-1"],
        plainTextReplacement: nil
    ))

    _ = await pipeline.flush(reason: .manualStop)

    let events = try readPipelineEvents(from: eventsURL)
    XCTAssertFalse(events.contains { $0.event == "caption_translation_draft_triggered" && $0.wallTime > events[0].wallTime })
}
```

- [ ] **Step 4: Run focused tests**

Run:

```bash
swift test --filter CaptionTranslationSchedulerTests/testDraftTriggerPolicyLogsTriggeredAndSkippedReasons
swift test --filter CaptionTranslationSchedulerTests/testHardFinalTranslationBypassesDraftTriggerMinimumInterval
swift test --filter LiveCaptionPipelineTests
```

Expected:

- The new tests pass.
- Existing replay and flush tests continue passing.

- [ ] **Step 5: Commit telemetry and final regression coverage**

```bash
git add Tests/MeetingAgentCoreTests/CaptionTranslationSchedulerTests.swift Tests/MeetingAgentCoreTests/LiveCaptionPipelineTests.swift
git commit -m "test: cover draft trigger telemetry"
```

---

### Task 4: Extend Meeting Performance Analysis Metrics

**Files:**
- Modify: `scripts/analyze-meeting-performance.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingPerformanceAnalysisScriptTests.swift`

- [ ] **Step 1: Add script test fixture for draft policy output**

Add this test to `MeetingPerformanceAnalysisScriptTests`:

```swift
func testAnalyzeMeetingPerformanceScriptReportsDraftTriggerPolicyMetrics() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("meeting-performance-draft-policy-\(UUID().uuidString)", isDirectory: true)
    let eventsURL = root.appendingPathComponent("performance-events.jsonl")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try [
        event("deepgram_audio_frame_sent", wallTime: "2026-05-01T00:00:00Z"),
        event("caption_turn_visible", wallTime: "2026-05-01T00:00:01Z", audio: 1, segmentID: "segment-1", isFinal: false, textLength: 10, metadata: ["turnID": "segment-1"]),
        event("caption_translation_draft_triggered", wallTime: "2026-05-01T00:00:01.100Z", segmentID: "segment-1", isFinal: false, textLength: 10, metadata: ["reason": "initial"]),
        event("caption_translation_scheduled", wallTime: "2026-05-01T00:00:01.100Z", segmentID: "segment-1", isFinal: false, textLength: 10, metadata: ["translationKind": "draft", "translationRequestID": "draft-1"]),
        event("caption_translation_started", wallTime: "2026-05-01T00:00:01.200Z", segmentID: "segment-1", isFinal: false, textLength: 10, metadata: ["translationKind": "draft", "translationRequestID": "draft-1"]),
        event("caption_translation_finished", wallTime: "2026-05-01T00:00:03.000Z", segmentID: "segment-1", isFinal: false, textLength: 8, metadata: ["translationKind": "draft", "translationRequestID": "draft-1"]),
        event("caption_translation_attached", wallTime: "2026-05-01T00:00:03.100Z", segmentID: "segment-1", isFinal: false, textLength: 8, metadata: ["translationKind": "draft", "translationRequestID": "draft-1"]),
        event("caption_snapshot_published", wallTime: "2026-05-01T00:00:03.100Z", segmentID: "segment-1", isFinal: false, textLength: 8, metadata: ["translationKind": "draft", "translationRequestID": "draft-1"]),
        event("caption_translation_draft_skipped", wallTime: "2026-05-01T00:00:03.200Z", segmentID: "segment-1", isFinal: false, textLength: 12, metadata: ["reason": "in_flight"]),
        event("caption_translation_draft_triggered", wallTime: "2026-05-01T00:00:04.000Z", segmentID: "segment-1", isFinal: false, textLength: 20, metadata: ["reason": "semantic_boundary"]),
        event("caption_translation_draft_triggered", wallTime: "2026-05-01T00:00:07.000Z", segmentID: "segment-1", isFinal: false, textLength: 24, metadata: ["reason": "max_wait"]),
        event("caption_translation_stale", wallTime: "2026-05-01T00:00:08.000Z", segmentID: "segment-1", isFinal: false, textLength: 24, metadata: ["translationKind": "draft", "reason": "draft_no_longer_current"])
    ].joined(separator: "\n").appending("\n").write(to: eventsURL, atomically: true, encoding: .utf8)

    let result = try runScript(arguments: [eventsURL.path])

    XCTAssertEqual(result.status, 0, result.stderr)
    XCTAssertTrue(result.stdout.contains("Draft Translation Trigger Rate: 75.0%"))
    XCTAssertTrue(result.stdout.contains("Draft Translation Skip Rate: 25.0%"))
    XCTAssertTrue(result.stdout.contains("Draft Translation In-Flight Skip Count: 1"))
    XCTAssertTrue(result.stdout.contains("Draft Translation Semantic Boundary Trigger Count: 1"))
    XCTAssertTrue(result.stdout.contains("Draft Translation Max-Wait Trigger Count: 1"))
    XCTAssertTrue(result.stdout.contains("Draft Translation Stale Rate: 100.0%"))
    XCTAssertTrue(result.stdout.contains("Time to First Draft Translation: 2.10s"))
    XCTAssertTrue(result.stdout.contains("Draft Visible Update Interval p50/p95: unavailable"))
}
```

- [ ] **Step 2: Run the script test and verify it fails**

Run:

```bash
swift test --filter MeetingPerformanceAnalysisScriptTests/testAnalyzeMeetingPerformanceScriptReportsDraftTriggerPolicyMetrics
```

Expected:

- Test fails because the report does not include the new draft policy metric lines.

- [ ] **Step 3: Add report lines**

In `MeetingPerformanceAnalyzer.report(inputPath:)`, after `Final True Failure Rate`, add:

```swift
lines.append("Draft Translation Trigger Rate: \(format(percent: draftTriggerRate()))")
lines.append("Draft Translation Skip Rate: \(format(percent: draftSkipRate()))")
lines.append("Draft Translation In-Flight Skip Count: \(draftSkipEvents(reason: "in_flight").count)")
lines.append("Draft Translation Semantic Boundary Trigger Count: \(draftTriggerEvents(reason: "semantic_boundary").count)")
lines.append("Draft Translation Max-Wait Trigger Count: \(draftTriggerEvents(reason: "max_wait").count)")
lines.append("Draft Translation Stale Rate: \(format(percent: draftStaleRate()))")
lines.append("Time to First Draft Translation: \(format(duration: timeToFirstDraftTranslation()))")
lines.append("Draft Visible Update Interval p50/p95: \(formatDraftVisibleUpdateInterval())")
```

- [ ] **Step 4: Add analyzer helper methods**

Add these methods inside `MeetingPerformanceAnalyzer`:

```swift
private func draftTriggerEvents(reason: String? = nil) -> [PerformanceEvent] {
    let events = events.filter { $0.event == "caption_translation_draft_triggered" }
    guard let reason else { return events }
    return events.filter { $0.metadata["reason"] == reason }
}

private func draftSkipEvents(reason: String? = nil) -> [PerformanceEvent] {
    let events = events.filter { $0.event == "caption_translation_draft_skipped" }
    guard let reason else { return events }
    return events.filter { $0.metadata["reason"] == reason }
}

private func draftScheduledEvents() -> [PerformanceEvent] {
    translationEvents("caption_translation_scheduled")
        .filter { $0.metadata["translationKind"] == "draft" }
}

private func draftStaleEvents() -> [PerformanceEvent] {
    translationEvents("caption_translation_stale")
        .filter { $0.metadata["translationKind"] == "draft" }
}

private func draftTriggerRate() -> Double? {
    let decisions = draftTriggerEvents().count + draftSkipEvents().count
    guard decisions > 0 else { return nil }
    return Double(draftTriggerEvents().count) / Double(decisions) * 100
}

private func draftSkipRate() -> Double? {
    let decisions = draftTriggerEvents().count + draftSkipEvents().count
    guard decisions > 0 else { return nil }
    return Double(draftSkipEvents().count) / Double(decisions) * 100
}

private func draftStaleRate() -> Double? {
    let scheduled = draftScheduledEvents().count
    guard scheduled > 0 else { return nil }
    return Double(draftStaleEvents().count) / Double(scheduled) * 100
}

private func timeToFirstDraftTranslation() -> Double? {
    guard let firstDraftCaption = events.first(where: { $0.event == "caption_turn_visible" && $0.isFinal == false })?.wallTime,
          let firstDraftAttach = translationEvents("caption_translation_attached")
            .first(where: { $0.metadata["translationKind"] == "draft" })?.wallTime
    else {
        return nil
    }
    return max(0, firstDraftAttach.timeIntervalSince(firstDraftCaption))
}

private func formatDraftVisibleUpdateInterval() -> String {
    let publishTimes = events
        .filter { $0.event == "caption_snapshot_published" && $0.metadata["translationKind"] == "draft" }
        .map(\.wallTime)
        .sorted()
    guard publishTimes.count >= 2 else {
        return "unavailable"
    }
    let intervals = zip(publishTimes.dropFirst(), publishTimes)
        .map { current, previous in max(0, current.timeIntervalSince(previous)) }
    let stats = Stats(values: intervals)
    return "\(format(duration: stats.percentile(50))) / \(format(duration: stats.percentile(95)))"
}
```

- [ ] **Step 5: Run analysis tests**

Run:

```bash
swift test --filter MeetingPerformanceAnalysisScriptTests
```

Expected:

- All meeting performance analysis script tests pass.

- [ ] **Step 6: Commit analysis metrics**

```bash
git add scripts/analyze-meeting-performance.swift Tests/MeetingAgentCoreTests/MeetingPerformanceAnalysisScriptTests.swift
git commit -m "feat: report draft translation trigger metrics"
```

---

### Task 5: Full Verification And Current Meeting Baseline

**Files:**
- No source changes expected.

- [ ] **Step 1: Run full test suite**

Run:

```bash
make test
```

Expected:

- XCTest suite passes.
- Coverage gate passes.

- [ ] **Step 2: Analyze latest recorded meeting as baseline**

Run:

```bash
latest_events="$(ls -t "$HOME/Library/Application Support/MeetingAgent/Meetings"/*/performance-events.jsonl | head -1)"
swift scripts/analyze-meeting-performance.swift "$latest_events"
```

Expected:

- Existing meetings without new draft trigger events show the new draft trigger metrics as `unavailable` or `0` based on available denominators.
- Existing final metrics still show the recent final success behavior.

- [ ] **Step 3: Inspect git status**

Run:

```bash
git status --short
```

Expected:

- Only expected tracked changes are present.
- Existing untracked `.env` and `x.log` may remain and must not be committed.

- [ ] **Step 4: Confirm no final cleanup commit is needed**

Run:

```bash
git diff --stat
```

Expected:

- No unstaged changes remain after the Task 4 commit.
- `.env` and `x.log` may appear as untracked in `git status --short`; leave them untracked.

---

## Implementation Notes

- Do not attach stale draft translations just to improve success rate. Stale draft results remain stale.
- Do not route replay, flush, or batch through live draft scheduling.
- Do not change final translation request identity or final persistence behavior.
- Keep event names readable and stable because the analysis script depends on them.
- If method coverage drops below the existing threshold, add focused tests for the new helper branches rather than weakening the coverage gate.
