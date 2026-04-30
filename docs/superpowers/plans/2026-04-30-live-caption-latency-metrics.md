# Live Caption Latency Metrics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add non-sensitive latency and lifecycle metrics for realtime captions and caption translation.

**Architecture:** Keep the existing JSONL `PerformanceEventLogger` as the only sink. `LiveCaptionPipeline` owns STT-to-visible and snapshot-published checkpoints; `CaptionTranslationScheduler` owns translation request counts, provider timing, stale discard, and failure payloads.

**Tech Stack:** Swift 5.9, Swift Package Manager, XCTest, macOS 14.2 target.

---

### Task 1: Logger Duration Metadata

**Files:**
- Modify: `Sources/MeetingAgentCore/PerformanceEventLogger.swift`
- Test: `Tests/MeetingAgentCoreTests/PerformanceEventLoggerTests.swift`

- [ ] Add an internal helper that returns metadata with `durationMilliseconds` from two `Date` values.
- [ ] Add a logger test that confirms duration metadata remains encoded through JSONL.
- [ ] Run: `swift test --filter PerformanceEventLoggerTests`.

### Task 2: Pipeline Caption Latency Events

**Files:**
- Modify: `Sources/MeetingAgentCore/LiveCaptionPipeline.swift`
- Test: `Tests/MeetingAgentCoreTests/LiveCaptionPipelineTests.swift`

- [ ] Track receive time for each changed segment in `apply(_:)`.
- [ ] Log `caption_turn_visible` after upsert, append, or replace paths mutate the store.
- [ ] Include segment ID, turn ID, locale pair, final state, boundary metadata, and `durationMilliseconds`.
- [ ] Add a focused test proving raw transcript text is absent from event metadata.
- [ ] Run: `swift test --filter LiveCaptionPipelineTests`.

### Task 3: Translation Scheduler Metrics

**Files:**
- Modify: `Sources/MeetingAgentCore/CaptionTranslationScheduler.swift`
- Test: `Tests/MeetingAgentCoreTests/CaptionTranslationSchedulerTests.swift`

- [ ] Add `providerID` to provider-backed request metadata.
- [ ] Emit count events for draft/final scheduled, completed, stale, cancelled, skipped, and failed paths using `count=1`.
- [ ] Add `durationMilliseconds` to `caption_translation_finished`.
- [ ] Log provider failure events with sanitized error metadata.
- [ ] Add focused tests for draft, final, stale, and failure payload shape.
- [ ] Run: `swift test --filter CaptionTranslationSchedulerTests`.

### Task 4: Snapshot Publish Metrics

**Files:**
- Modify: `Sources/MeetingAgentCore/LiveCaptionPipeline.swift`
- Test: `Tests/MeetingAgentCoreTests/LiveCaptionPipelineTests.swift`

- [ ] Return enough scheduler update context for pipeline snapshot logging without exposing public API.
- [ ] Log `caption_snapshot_published` after successful translation attachment.
- [ ] Include translation request ID, turn ID, source/target locale, draft/final state, and duration from result receipt to snapshot publish.
- [ ] Run: `swift test --filter LiveCaptionPipelineTests`.

### Task 5: Full Verification And Commit

**Files:**
- All modified source and test files.

- [ ] Run: `swift build --product MeetingAgentApp`.
- [ ] Run: `make test`.
- [ ] Commit implementation with `feat: add live caption latency metrics (#120)`.
