# Restart Meeting Listening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a manually stopped meeting process prompt for listening again when it is still running and has active audio.

**Architecture:** Keep candidate suppression inside `MeetingProcessMonitor`. Expose one focused method for releasing a prompted process ID, and call it from manual stop paths in `MeetingAgentViewModel`.

**Tech Stack:** Swift 5.9, Swift Package Manager, XCTest, macOS 14.2+.

---

### Task 1: Add Monitor Regression Tests

**Files:**
- Modify: `Tests/MeetingAgentCoreTests/MeetingProcessMonitorTests.swift`

- [ ] **Step 1: Add tests for releasing prompted state and preserving ignored state**

```swift
func testAllowRepromptDetectsSameActiveProcessAgain() {
    let zoom = AudioCaptureTarget(
        processID: 123,
        displayName: "zoom.us",
        bundleIdentifier: "us.zoom.xos",
        isAudioOutputActive: true
    )
    let monitor = MeetingProcessMonitor()

    _ = monitor.detectNewCandidates(in: [zoom], isRecording: false)
    XCTAssertEqual(monitor.detectNewCandidates(in: [zoom], isRecording: false), [])

    monitor.allowReprompt(processID: 123)

    XCTAssertEqual(monitor.detectNewCandidates(in: [zoom], isRecording: false), [zoom])
}

func testAllowRepromptDoesNotClearIgnoredProcess() {
    let zoom = AudioCaptureTarget(
        processID: 123,
        displayName: "zoom.us",
        bundleIdentifier: "us.zoom.xos",
        isAudioOutputActive: true
    )
    let monitor = MeetingProcessMonitor()

    _ = monitor.detectNewCandidates(in: [zoom], isRecording: false)
    monitor.ignore(processID: 123)
    monitor.allowReprompt(processID: 123)

    XCTAssertEqual(monitor.detectNewCandidates(in: [zoom], isRecording: false), [])
}
```

- [ ] **Step 2: Run focused test to verify failure**

Run: `swift test --filter MeetingProcessMonitorTests/testAllowRepromptDetectsSameActiveProcessAgain`

Expected: FAIL because `allowReprompt(processID:)` does not exist.

### Task 2: Implement Monitor API

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingProcessMonitor.swift`

- [ ] **Step 1: Add the focused API**

```swift
public func allowReprompt(processID: pid_t) {
    promptedProcessIDs.remove(processID)
}
```

- [ ] **Step 2: Run monitor tests**

Run: `swift test --filter MeetingProcessMonitorTests`

Expected: PASS.

### Task 3: Wire Manual Stop

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Modify: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] **Step 1: Add view-model regression test**

```swift
func testStopRecordingAllowsSameRunningTargetToPromptAgain() async throws {
    let fixture = try ViewModelRecorderFixture()
    let target = AudioCaptureTarget(
        processID: 10,
        displayName: "zoom.us",
        bundleIdentifier: "us.zoom.xos",
        isAudioOutputActive: true
    )
    let viewModel = MeetingAgentViewModel(
        store: fixture.store,
        recorder: fixture.recorder,
        processTargetsProvider: { [target] }
    )

    XCTAssertEqual(viewModel.pollForMeetingCandidates(), target)
    try await viewModel.startRecordingForPendingCandidate()

    viewModel.stopRecording(at: Date(timeIntervalSince1970: 200))
    let candidate = viewModel.pollForMeetingCandidates()

    XCTAssertEqual(candidate, target)
    XCTAssertEqual(viewModel.pendingCandidate, target)
    XCTAssertEqual(viewModel.statusText, "Meeting detected: zoom.us")
}
```

- [ ] **Step 2: Run focused test to verify failure**

Run: `swift test --filter MeetingAgentViewModelTests/testStopRecordingAllowsSameRunningTargetToPromptAgain`

Expected: FAIL because Stop does not release prompted state yet.

- [ ] **Step 3: Update manual stop paths**

Before setting `activeTarget = nil`, call:

```swift
if let activeTarget {
    processMonitor.allowReprompt(processID: activeTarget.processID)
}
```

Apply this in `stopRecording(at:)` and `stopRecordingAndGenerateSummary(at:generatedAt:)`.

- [ ] **Step 4: Run focused tests**

Run: `swift test --filter MeetingAgentViewModelTests/testStopRecordingAllowsSameRunningTargetToPromptAgain`

Expected: PASS.

### Task 4: Full Verification and Commit

**Files:**
- Modified source and test files from previous tasks.
- Created docs under `docs/superpowers`.

- [ ] **Step 1: Run required verification**

Run: `make test`

Expected: PASS.

- [ ] **Step 2: Commit implementation**

```bash
git add docs/superpowers/specs/2026-04-28-restart-meeting-listening-design.md docs/superpowers/plans/2026-04-28-restart-meeting-listening.md Sources/MeetingAgentCore/MeetingProcessMonitor.swift Sources/MeetingAgentCore/MeetingAgentViewModel.swift Tests/MeetingAgentCoreTests/MeetingProcessMonitorTests.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift
git commit -m "feat: allow meeting listening restart after stop (#47)"
```
