# Caption Translation Budget Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add bounded draft caption translation scheduling and analysis-grade performance telemetry for live meetings.

**Architecture:** Keep the policy inside `CaptionTranslationScheduler`, where draft/final ownership already lives. Add a small scheduler configuration, draft debounce state, request queue state, and richer telemetry metadata while preserving the existing `LiveCaptionPipeline` API.

**Tech Stack:** Swift 5.9, Swift concurrency, XCTest, existing `PerformanceEventLogger` JSONL sink.

---

### Task 1: Add Scheduler Budget Configuration And Telemetry Fields

**Files:**
- Modify: `Sources/MeetingAgentCore/CaptionTranslationScheduler.swift`
- Test: `Tests/MeetingAgentCoreTests/CaptionTranslationSchedulerTests.swift`

- [ ] **Step 1: Write failing telemetry tests**

Add tests that schedule one draft translation and assert `caption_translation_started` has `isFinal == false`, `translationKind == "draft"`, `sourceTextHash`, `sourceTextLength`, `requestOrdinalForTurn`, `inFlightCount`, and `concurrencyLimit`.

- [ ] **Step 2: Run focused test**

Run: `swift test --filter CaptionTranslationSchedulerTests`

Expected: FAIL because current telemetry lacks budget metadata and draft started events are marked final.

- [ ] **Step 3: Add config and metadata**

Add a `CaptionTranslationSchedulerConfiguration` with defaults: draft debounce 0.2 seconds and max concurrent requests 2. Extend `ActiveCaptionTranslationRequest` with request ordinal, source text, scheduled reason, and budget metadata. Fix started/finished/attached top-level `isFinal` to use `!request.isDraft`.

- [ ] **Step 4: Run focused test**

Run: `swift test --filter CaptionTranslationSchedulerTests`

Expected: PASS for the new telemetry test or fail only for later missing behavior.

### Task 2: Add Draft Debounce And Latest-Wins Pending Drafts

**Files:**
- Modify: `Sources/MeetingAgentCore/CaptionTranslationScheduler.swift`
- Test: `Tests/MeetingAgentCoreTests/CaptionTranslationSchedulerTests.swift`

- [ ] **Step 1: Write failing debounce tests**

Add tests for rapid same-turn draft updates. The first draft should log `caption_translation_debounce_scheduled`, the second should log `caption_translation_debounce_replaced`, and only the latest text should reach the provider after debounce fires.

- [ ] **Step 2: Run focused test**

Run: `swift test --filter CaptionTranslationSchedulerTests`

Expected: FAIL because drafts currently call the provider immediately.

- [ ] **Step 3: Implement debounce**

Track pending draft requests by turn ID. Delay draft execution by the configured debounce interval. Replacing a pending draft cancels the older pending item and logs `caption_translation_debounce_replaced`. Final requests bypass this path.

- [ ] **Step 4: Run focused test**

Run: `swift test --filter CaptionTranslationSchedulerTests`

Expected: PASS for debounce tests.

### Task 3: Add Global Concurrency Budget With Final Priority

**Files:**
- Modify: `Sources/MeetingAgentCore/CaptionTranslationScheduler.swift`
- Test: `Tests/MeetingAgentCoreTests/CaptionTranslationSchedulerTests.swift`

- [ ] **Step 1: Write failing concurrency tests**

Add a delayed provider test with max concurrency 1. Schedule two draft requests and one final request. Assert no more than one provider call is in flight, the final request starts before waiting draft work, and no final request is dropped.

- [ ] **Step 2: Run focused test**

Run: `swift test --filter CaptionTranslationSchedulerTests`

Expected: FAIL because the current scheduler awaits each provider call directly and has no queue telemetry.

- [ ] **Step 3: Implement queue policy**

Maintain final and draft queues. Start work while `inFlightCount < maxConcurrentTranslationRequests`. Final queue drains before draft queue. Draft queue uses latest-wins semantics and can log `caption_translation_dropped` when superseded. Final queue is durable.

- [ ] **Step 4: Run focused test**

Run: `swift test --filter CaptionTranslationSchedulerTests`

Expected: PASS for concurrency tests.

### Task 4: Preserve Stale Completion Safety

**Files:**
- Modify: `Sources/MeetingAgentCore/CaptionTranslationScheduler.swift`
- Test: `Tests/MeetingAgentCoreTests/CaptionTranslationSchedulerTests.swift`

- [ ] **Step 1: Write failing stale tests**

Add a delayed draft provider test where a draft request completes after a newer draft or hard-final turn is current. Assert the stale completion logs `caption_translation_stale` and does not overwrite the current translated text or final state.

- [ ] **Step 2: Run focused test**

Run: `swift test --filter CaptionTranslationSchedulerTests`

Expected: FAIL if stale draft application is not guarded by the current key and request kind.

- [ ] **Step 3: Keep apply guard strict**

Reuse `translationKey` checks and request kind checks in `apply(_:,to:)`. Ensure cancellation and stale logging include `reason` and budget metadata.

- [ ] **Step 4: Run focused test**

Run: `swift test --filter CaptionTranslationSchedulerTests`

Expected: PASS for stale tests.

### Task 5: Verify Pipeline Integration And Full Test Suite

**Files:**
- Modify: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift` if existing performance event expectations need stricter metadata.

- [ ] **Step 1: Run focused integration tests**

Run: `swift test --filter MeetingAgentViewModelTests/testCaptionTranslationPerformanceEventsShareRequestID`

Expected: PASS with updated metadata.

- [ ] **Step 2: Run package tests**

Run: `make test`

Expected: PASS, including coverage gate.

- [ ] **Step 3: Commit implementation**

Run:

```bash
git add Sources/MeetingAgentCore/CaptionTranslationScheduler.swift Tests/MeetingAgentCoreTests/CaptionTranslationSchedulerTests.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift
git commit -m "feat: budget caption translation requests (#118)"
```
