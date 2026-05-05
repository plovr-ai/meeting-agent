# Replay Performance Separation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop idle/post-recording transcript replay from running every 250ms and keep replay events out of realtime meeting performance metrics.

**Architecture:** Keep `drainRecordingFrames()` as the recording tick. Add a selected-meeting replay cache so file-backed replay only runs when the selected meeting, transcript caption signature, or display-relevant configuration changes. Mark replay-generated caption events with `path=replay`, and update the performance analyzer to default to realtime recording-window metrics while reporting replay overhead separately.

**Tech Stack:** Swift 5.9, XCTest, Swift script analyzer, JSONL performance events.

---

### Task 1: Stop Replaying Unchanged Selected Meetings

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [x] **Step 1: Write failing test**

Add a test that starts from an idle selected meeting with a transcript, calls `drainRecordingFrames()` twice, and asserts the live caption replay logger does not emit duplicate replay-visible events for the unchanged document.

- [x] **Step 2: Run test to verify failure**

Run: `swift test --filter MeetingAgentViewModelTests`

Expected: the new test fails because idle replay currently runs every call.

- [x] **Step 3: Implement replay cache**

Add private state to `MeetingAgentViewModel` for the last replayed selected meeting signature. Use a caption-only signature that excludes translated text fields. In `refreshLiveCaptionTurnsFromSelectedMeetingSynchronously()`, return early when the selected meeting ID, caption signature, source locale, target locale, and translation provider availability have not changed. Throttle unchanged selected-meeting pending translation retries so idle ticks do not emit translation scheduling noise every 250ms.

- [x] **Step 4: Run test to verify pass**

Run: `swift test --filter MeetingAgentViewModelTests`

Expected: the new test passes.

### Task 2: Mark Replay Events Separately

**Files:**
- Modify: `Sources/MeetingAgentCore/LiveCaptionPipeline.swift`
- Test: `Tests/MeetingAgentCoreTests/LiveCaptionPipelineTests.swift`

- [x] **Step 1: Write failing test**

Add a replay test that calls `replayCaptionsOnly(_:)` and asserts generated `caption_turn_visible` events include `metadata["path"] == "replay"`.

- [x] **Step 2: Run test to verify failure**

Run: `swift test --filter LiveCaptionPipelineTests`

Expected: the new test fails because replay events are not marked.

- [x] **Step 3: Implement replay path metadata**

Thread a `visibilityPath` value through replay `applyEvents` calls. Use `path=realtime` for live `apply(_:)` events and `path=replay` for `replayCaptionsOnly(_:)` / `replay(_:)` caption rebuild events.

- [x] **Step 4: Run test to verify pass**

Run: `swift test --filter LiveCaptionPipelineTests`

Expected: the new test passes.

### Task 3: Separate Realtime And Replay Metrics

**Files:**
- Modify: `scripts/analyze-meeting-performance.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingPerformanceAnalysisScriptTests.swift`

- [x] **Step 1: Write failing test**

Add analyzer fixtures with recording-window realtime events plus post-stop replay events. Assert experience KPIs use only realtime/path-less legacy events within the recording window, and assert the report includes replay overhead counts.

- [x] **Step 2: Run test to verify failure**

Run: `swift test --filter MeetingPerformanceAnalysisScriptTests`

Expected: the new test fails because replay events are counted as realtime and no replay section exists.

- [x] **Step 3: Implement analyzer filtering**

Parse `recording_started` / `recording_stopped` wall times. Treat `caption_turn_visible` with `metadata.path == "replay"` as replay. Default realtime KPIs to events inside the recording window and not marked replay. Add a `Replay / Idle Overhead` section with replay visible event count and post-stop translation event count.

- [x] **Step 4: Run test to verify pass**

Run: `swift test --filter MeetingPerformanceAnalysisScriptTests`

Expected: the new test passes.

### Task 4: Full Verification

**Files:**
- No new files.

- [x] Run `make test`.
- [x] Run `env CLANG_MODULE_CACHE_PATH=/tmp/meeting-agent-clang-cache swift scripts/analyze-meeting-performance.swift "$HOME/Library/Application Support/MeetingAgent/Meetings/402CE21B-04EC-42A7-899A-ED0B1D8A71F4"`.
- [x] Confirm report keeps realtime caption stability separate from replay overhead.
