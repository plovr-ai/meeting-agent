# Feishu System Audio Capture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Meeting Agent detect Feishu/Lark desktop meetings as system-audio capture targets.

**Architecture:** Keep capture, recording, STT, subtitles, translation, summaries, and exports unchanged. Centralize preferred meeting-target classification in `RunningProcessDiscovery` and use it from process sorting, automatic target selection, and prompt detection.

**Tech Stack:** Swift 5.9, Swift Package Manager, XCTest, macOS process discovery via `NSWorkspace` and Core Audio activity checks.

---

### Task 1: Add Feishu/Lark Classification Tests

**Files:**
- Modify: `Tests/MeetingAgentCoreTests/RunningProcessDiscoveryTests.swift`
- Modify: `Tests/MeetingAgentCoreTests/MeetingProcessMonitorTests.swift`

- [ ] **Step 1: Write failing process-discovery tests**

Add tests asserting that display-name-only Feishu/Lark targets are treated as preferred targets and still require active audio for automatic selection.

- [ ] **Step 2: Run focused tests to verify RED**

Run: `swift test --filter RunningProcessDiscoveryTests`

Expected: at least one new test fails because unknown-bundle Feishu/Lark names are not preferred yet.

- [ ] **Step 3: Write failing prompt-detection test**

Add a `MeetingProcessMonitorTests` case asserting that an active `飞书` target with an unknown bundle ID is detected as a new candidate.

- [ ] **Step 4: Run focused tests to verify RED**

Run: `swift test --filter MeetingProcessMonitorTests`

Expected: the new Feishu display-name prompt test fails because prompt detection currently checks only preferred bundle IDs.

### Task 2: Centralize Preferred Target Classification

**Files:**
- Modify: `Sources/MeetingAgentCore/RunningProcessDiscovery.swift`
- Modify: `Sources/MeetingAgentCore/MeetingProcessMonitor.swift`

- [ ] **Step 1: Add `isPreferredMeetingTarget`**

Implement `RunningProcessDiscovery.isPreferredMeetingTarget(_:)` using known bundle IDs first, then exact or prefix display-name matches for `Feishu`, `飞书`, and `Lark`.

- [ ] **Step 2: Use the helper everywhere**

Replace direct `preferredBundleIDs.contains` checks in sorting, automatic target selection, and `MeetingProcessMonitor.detectNewCandidates` with the helper.

- [ ] **Step 3: Run focused tests to verify GREEN**

Run:

```bash
swift test --filter RunningProcessDiscoveryTests
swift test --filter MeetingProcessMonitorTests
```

Expected: both focused suites pass.

### Task 3: Full Verification And Commit

**Files:**
- Verify all changed files.

- [ ] **Step 1: Run required verification**

Run: `make test`

Expected: command exits 0 with repository coverage checks passing.

- [ ] **Step 2: Commit**

Commit source, tests, spec, and plan with:

```bash
git add Sources/MeetingAgentCore/RunningProcessDiscovery.swift Sources/MeetingAgentCore/MeetingProcessMonitor.swift Tests/MeetingAgentCoreTests/RunningProcessDiscoveryTests.swift Tests/MeetingAgentCoreTests/MeetingProcessMonitorTests.swift docs/superpowers/specs/2026-04-28-feishu-system-audio-capture-design.md docs/superpowers/plans/2026-04-28-feishu-system-audio-capture.md
git commit -m "feat: detect Feishu meetings for system audio capture (#48)"
```
