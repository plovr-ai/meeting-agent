# Visible Translation Latency Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prioritize the latest visible caption translation and prevent hard-final captions from waiting behind stale draft work.

**Architecture:** Keep source caption ingestion in `MeetingAgentViewModel` unchanged. Replace direct draft/final task spawning with a small in-view-model scheduler that queues final work first and keeps only the latest draft work per turn. Add request IDs to performance logs so future latency analysis can match translation lifecycle events precisely.

**Tech Stack:** Swift 5.9, Swift Concurrency, XCTest, existing `PerformanceEventLogger`, existing `MeetingAgentViewModelTests`.

---

### Task 1: Add Translation Request IDs To Logs

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] **Step 1: Write failing log correlation test**

Add a test that creates a meeting, writes one final segment, drains frames, waits for translation, then decodes `performance-events.jsonl` and asserts scheduled, started, finished, and attached events for that turn all include the same non-empty `translationRequestID`.

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testCaptionTranslationPerformanceEventsShareRequestID
```

Expected: FAIL because events do not include `translationRequestID`.

- [ ] **Step 2: Add request ID to `CaptionTranslationRequest`**

Add `let requestID: String` to `CaptionTranslationRequest`. Generate it when building draft and final requests with a stable prefix such as `caption-translation-\(UUID().uuidString)`.

- [ ] **Step 3: Log request metadata**

Update `translationMetadata` call sites for scheduled, started, finished, attached, failed, stale, and cancelled events to include:

```swift
[
    "translationRequestID": request.requestID,
    "translationRevision": String(request.revision),
    "translationKeyHash": String(request.key.hashValue)
]
```

For scheduled events, pass the generated request ID into `logTranslationScheduled`.

- [ ] **Step 4: Verify focused test passes**

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testCaptionTranslationPerformanceEventsShareRequestID
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingAgentCore/MeetingAgentViewModel.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift
git commit -m "feat: tag caption translation performance events"
```

### Task 2: Queue Latest Draft Instead Of Starting Every Draft Immediately

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] **Step 1: Write failing latest-only draft test**

Add a test using `DelayedViewModelFakeTextTranslationProvider`: write a draft segment, drain, immediately rewrite the same segment with longer text, drain, and assert the provider sees only one pending request with the latest text.

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testLatestVisibleDraftReplacesOlderPendingDraftBeforeProviderStart
```

Expected: FAIL until pending draft queue replacement is implemented.

- [ ] **Step 2: Add pending draft storage**

Add:

```swift
private var pendingDraftTranslationRequestsByTurnID: [String: CaptionTranslationRequest] = [:]
private var runningDraftTranslationTurnIDs = Set<String>()
```

Draft candidate submission should set `pendingDraftTranslationRequestsByTurnID[turn.id] = request` and cancel/remove any old task state for that turn that has not started.

- [ ] **Step 3: Add scheduler pump**

Create `pumpCaptionTranslationWork(using provider: TextTranslationProvider)` that starts draft work only if:

```swift
runningDraftTranslationTurnIDs.isEmpty
runningCaptionTranslationCount < maxConcurrentCaptionTranslations
```

Choose the pending draft request with the latest current turn order in `liveCaptionStore.turns`.

- [ ] **Step 4: Clear running state and pump on completion**

When draft work completes or is cancelled, remove its turn ID from `runningDraftTranslationTurnIDs`, then call `scheduleCaptionTextTranslationIfNeeded()` or a no-provider pump path that starts the next pending request using the provider captured by the scheduler.

- [ ] **Step 5: Verify focused test passes**

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testLatestVisibleDraftReplacesOlderPendingDraftBeforeProviderStart
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/MeetingAgentCore/MeetingAgentViewModel.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift
git commit -m "feat: queue latest draft caption translation"
```

### Task 3: Prioritize Final Requests And Bound Concurrency

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] **Step 1: Write failing final priority test**

Add a delayed-provider test with one pending draft and one hard-final turn. Drain frames and assert the hard-final provider request starts before the draft request when capacity is constrained.

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testHardFinalTranslationStartsBeforePendingDraftTranslation
```

Expected: FAIL until final priority scheduling is implemented.

- [ ] **Step 2: Add pending final queue and running counters**

Add:

```swift
private var pendingFinalTranslationRequestsByTurnID: [String: CaptionTranslationRequest] = [:]
private var runningFinalTranslationTurnIDs = Set<String>()
private let maxConcurrentCaptionTranslations = 2
private let maxConcurrentDraftTranslations = 1
```

Compute running count as final count plus draft count.

- [ ] **Step 3: Pump final first**

`pumpCaptionTranslationWork` should start pending final requests before draft requests while total running count is below `maxConcurrentCaptionTranslations`.

- [ ] **Step 4: Make final requests concurrent up to capacity**

Replace serial `translateCaptionTurns(finalRequests, using:)` for final batches with individual scheduled final tasks. Each final task clears `runningFinalTranslationTurnIDs` on completion and pumps again.

- [ ] **Step 5: Verify final priority test passes**

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testHardFinalTranslationStartsBeforePendingDraftTranslation
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/MeetingAgentCore/MeetingAgentViewModel.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift
git commit -m "feat: prioritize final caption translations"
```

### Task 4: Log Cancelled And Stale Translation Outcomes

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] **Step 1: Write failing stale log test**

Add a test where an older draft provider request completes after a newer revision is current. Assert `performance-events.jsonl` contains `caption_translation_stale` with the old request ID and `staleReason`.

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testStaleDraftTranslationLogsReasonWithRequestID
```

Expected: FAIL because stale outcomes are currently silent.

- [ ] **Step 2: Add stale logging helper**

Add:

```swift
private func logStaleCaptionTranslation(_ request: CaptionTranslationRequest, reason: String)
```

The helper logs `caption_translation_stale` with request metadata and `staleReason`.

- [ ] **Step 3: Log cancellation helper**

When replacing pending draft work or cancelling superseded draft work for a hard final, log `caption_translation_cancelled` with `staleReason` values such as `replacedByNewerDraft` and `supersededByHardFinal`.

- [ ] **Step 4: Verify stale log test passes**

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testStaleDraftTranslationLogsReasonWithRequestID
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingAgentCore/MeetingAgentViewModel.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift
git commit -m "feat: log stale caption translation outcomes"
```

### Task 5: Full Verification

**Files:**
- No source edits expected.

- [ ] **Step 1: Run view model tests**

Run:

```bash
swift test --filter MeetingAgentViewModelTests
```

Expected: PASS.

- [ ] **Step 2: Run app build**

Run:

```bash
swift build --product MeetingAgentApp
```

Expected: PASS.

- [ ] **Step 3: Run required test command**

Run:

```bash
make test
```

Expected: PASS and coverage gate passed.
