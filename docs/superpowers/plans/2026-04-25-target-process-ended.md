# Target Process Ended Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect active capture target process termination in the app and CLI, then persist capture diagnostics with `endedReason: targetProcessEnded`.

**Architecture:** Add testable PID liveness helpers to `MeetingProcessMonitor`, inject the target list provider into `MeetingAgentViewModel`, and let `MeetingRecorder.stopRecording` accept the final capture ended reason. The CLI will use the same liveness helper in its existing capture loop.

**Tech Stack:** Swift 5.9, Swift Package Manager, XCTest, macOS Core Audio Process Tap prototype.

---

## File Structure

- Modify `Sources/MeetingAgentCore/MeetingProcessMonitor.swift` to expose PID liveness helpers.
- Modify `Sources/MeetingAgentCore/MeetingRecorder.swift` to accept and persist a caller-provided `CaptureEndedReason`.
- Modify `Sources/MeetingAgentCore/MeetingAgentViewModel.swift` to inject a process target provider and stop active recordings when the PID disappears.
- Modify `Sources/CoreAudioTapProbe/ProbeMain.swift` to stop early with `.targetProcessEnded` when the target PID disappears.
- Modify `Tests/MeetingAgentCoreTests/MeetingProcessMonitorTests.swift` for liveness helper coverage.
- Modify `Tests/MeetingAgentCoreTests/MeetingRecorderTests.swift` for target-ended diagnostics persistence.
- Modify `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift` for app state transition coverage.

### Task 1: Process Liveness Helper

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingProcessMonitor.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingProcessMonitorTests.swift`

- [ ] **Step 1: Write failing liveness tests**

Add these tests to `MeetingProcessMonitorTests`:

```swift
func testDetectsRunningProcessIDFromTargets() {
    let monitor = MeetingProcessMonitor()
    let zoom = AudioCaptureTarget(processID: 123, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
    let chrome = AudioCaptureTarget(processID: 456, displayName: "Google Chrome", bundleIdentifier: "com.google.Chrome")

    XCTAssertTrue(monitor.isProcessRunning(processID: 123, in: [zoom, chrome]))
    XCTAssertFalse(monitor.isProcessRunning(processID: 789, in: [zoom, chrome]))
}

func testDetectsEndedProcessIDFromTargets() {
    let monitor = MeetingProcessMonitor()
    let zoom = AudioCaptureTarget(processID: 123, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")

    XCTAssertFalse(monitor.hasProcessEnded(processID: 123, in: [zoom]))
    XCTAssertTrue(monitor.hasProcessEnded(processID: 456, in: [zoom]))
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter MeetingProcessMonitorTests`

Expected: FAIL because `isProcessRunning(processID:in:)` and `hasProcessEnded(processID:in:)` do not exist.

- [ ] **Step 3: Implement liveness helper**

Add these methods to `MeetingProcessMonitor`:

```swift
public func isProcessRunning(processID: pid_t, in targets: [AudioCaptureTarget]) -> Bool {
    targets.contains { $0.processID == processID }
}

public func hasProcessEnded(processID: pid_t, in targets: [AudioCaptureTarget]) -> Bool {
    !isProcessRunning(processID: processID, in: targets)
}
```

- [ ] **Step 4: Run tests to verify pass**

Run: `swift test --filter MeetingProcessMonitorTests`

Expected: PASS.

### Task 2: Recorder Ended Reason

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingRecorder.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingRecorderTests.swift`

- [ ] **Step 1: Write failing recorder diagnostics test**

Add this test to `MeetingRecorderTests`:

```swift
func testRecorderPersistsTargetProcessEndedReason() throws {
    let storeRoot = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-recorder-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: storeRoot) }
    let store = MeetingStore(baseDirectory: storeRoot)
    let recorder = MeetingRecorder(store: store)
    let target = AudioCaptureTarget(processID: 1, displayName: "Google Chrome", bundleIdentifier: "com.google.Chrome")

    let record = try recorder.prepareRecord(for: target, startedAt: Date(timeIntervalSince1970: 100))
    _ = try recorder.markStopped(at: Date(timeIntervalSince1970: 200), endedReason: .targetProcessEnded)

    let data = try Data(contentsOf: XCTUnwrap(record.diagnosticsURL))
    let diagnostics = try JSONDecoder.meetingAgent.decode(CaptureDiagnostics.self, from: data)
    XCTAssertEqual(diagnostics.endedReason, .targetProcessEnded)
    XCTAssertEqual(diagnostics.status, .targetProcessEnded)
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter MeetingRecorderTests`

Expected: FAIL because `markStopped(at:endedReason:)` does not exist.

- [ ] **Step 3: Implement ended reason plumbing**

Change signatures and calls in `MeetingRecorder`:

```swift
public func stopRecording(
    at endedAt: Date = Date(),
    endedReason: CaptureEndedReason = .saved
) throws -> MeetingRecord? {
    try writer?.close()
    let activeTranscriber = transcriber
    activeTranscriber?.finish()
    if let failureReason = activeTranscriber?.failureReason {
        try markTranscriptionFailed(failureReason)
    }
    captureSession?.stop()
    diagnosticsTracker?.finish(endedReason: endedReason)
    writer = nil
    transcriber = nil
    captureSession = nil
    return try markStopped(at: endedAt, endedReason: endedReason)
}

public func markStopped(
    at endedAt: Date = Date(),
    endedReason: CaptureEndedReason = .saved
) throws -> MeetingRecord? {
    guard var record = activeRecord else {
        state = .idle
        return nil
    }

    record.endedAt = endedAt
    if record.transcriptionStatus == .transcribing {
        record.transcriptionStatus = .transcribed
        record.transcriptionFailureReason = nil
    }
    diagnosticsTracker?.finish(endedReason: endedReason)
    try diagnosticsTracker?.snapshot().writeIfPossible(to: record.diagnosticsURL)
    diagnosticsTracker = nil
    try store.save(record)
    activeRecord = nil
    state = .idle
    return record
}
```

- [ ] **Step 4: Run tests to verify pass**

Run: `swift test --filter MeetingRecorderTests`

Expected: PASS.

### Task 3: App Target End Handling

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] **Step 1: Write failing view-model test**

Add this test to `MeetingAgentViewModelTests`:

```swift
func testDrainRecordingFramesStopsWhenTargetProcessEnds() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(baseDirectory: root)
    var targets: [AudioCaptureTarget] = []
    let endedAt = Date(timeIntervalSince1970: 200)
    let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
    let viewModel = MeetingAgentViewModel(
        store: store,
        processTargetsProvider: { targets }
    )

    viewModel.setPendingCandidate(target)
    try viewModel.acceptPendingCandidate(startedAt: Date(timeIntervalSince1970: 100))

    viewModel.drainRecordingFrames(endedAt: endedAt)

    XCTAssertEqual(viewModel.meetings.first?.endedAt, endedAt)
    XCTAssertEqual(viewModel.statusText, "Target process ended: zoom.us")
    XCTAssertFalse(viewModel.isRecording)

    let data = try Data(contentsOf: XCTUnwrap(viewModel.meetings.first?.diagnosticsURL))
    let diagnostics = try JSONDecoder.meetingAgent.decode(CaptureDiagnostics.self, from: data)
    XCTAssertEqual(diagnostics.endedReason, .targetProcessEnded)
    XCTAssertEqual(diagnostics.status, .targetProcessEnded)
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter MeetingAgentViewModelTests`

Expected: FAIL because `processTargetsProvider` injection does not exist.

- [ ] **Step 3: Inject process targets provider**

Add a stored provider to `MeetingAgentViewModel`:

```swift
private let processTargetsProvider: () -> [AudioCaptureTarget]
```

Add this initializer parameter:

```swift
processTargetsProvider: @escaping () -> [AudioCaptureTarget] = RunningProcessDiscovery.currentTargets,
```

Assign it in `init`:

```swift
self.processTargetsProvider = processTargetsProvider
```

Update `pollForMeetingCandidates()`:

```swift
let targets = processTargetsProvider()
```

- [ ] **Step 4: Implement app stop on target end**

Update `drainRecordingFrames()`:

```swift
public func drainRecordingFrames(endedAt: Date = Date()) {
    try? recorder.drainFrames()
    if stopRecordingIfTargetProcessEnded(at: endedAt) {
        objectWillChange.send()
        return
    }
    updateRecordingStatus()
    objectWillChange.send()
}
```

Add this helper:

```swift
private func stopRecordingIfTargetProcessEnded(at endedAt: Date = Date()) -> Bool {
    guard let activeTarget else { return false }
    let targets = processTargetsProvider()
    guard processMonitor.hasProcessEnded(processID: activeTarget.processID, in: targets) else {
        return false
    }
    if let stopped = try? recorder.stopRecording(at: endedAt, endedReason: .targetProcessEnded),
       let index = meetings.firstIndex(where: { $0.id == stopped.id }) {
        meetings[index] = stopped
    }
    statusText = "Target process ended: \(activeTarget.displayName)"
    self.activeTarget = nil
    return true
}
```

- [ ] **Step 5: Run tests to verify pass**

Run: `swift test --filter MeetingAgentViewModelTests`

Expected: PASS.

### Task 4: CLI Target End Handling

**Files:**
- Modify: `Sources/CoreAudioTapProbe/ProbeMain.swift`

- [ ] **Step 1: Refactor loop ended reason variable**

Before the CLI capture loop, add:

```swift
var endedReason = CaptureEndedReason.saved
let processMonitor = MeetingProcessMonitor()
```

- [ ] **Step 2: Check target liveness in the loop**

Inside the `while Date() < end` loop, after sleep and before draining frames, add:

```swift
let currentTargets = RunningProcessDiscovery.currentTargets()
let targetProcessEnded = processMonitor.hasProcessEnded(processID: target.processID, in: currentTargets)
if targetProcessEnded {
    endedReason = .targetProcessEnded
}
```

After logging any frame results for the tick, add:

```swift
if targetProcessEnded {
    log("Target process ended: \(target.displayName) pid=\(target.processID)")
    break
}
```

For the `frames.isEmpty` branch, log idle and then break when `targetProcessEnded` is true before continuing.

- [ ] **Step 3: Persist dynamic ended reason**

Change:

```swift
diagnosticsTracker.finish(endedReason: .saved)
```

to:

```swift
diagnosticsTracker.finish(endedReason: endedReason)
```

- [ ] **Step 4: Build CLI**

Run: `swift build --product CoreAudioTapProbe`

Expected: PASS.

### Task 5: Full Verification and Commit

**Files:**
- Verify all changed files.

- [ ] **Step 1: Run full tests**

Run: `swift test`

Expected: PASS.

- [ ] **Step 2: Run app build**

Run: `swift build --product MeetingAgentApp`

Expected: PASS.

- [ ] **Step 3: Run CLI build**

Run: `swift build --product CoreAudioTapProbe`

Expected: PASS.

- [ ] **Step 4: Review diff**

Run: `git diff --check` and `git diff --stat`

Expected: no whitespace errors; diff only includes issue #15 files.

- [ ] **Step 5: Commit implementation**

Run:

```bash
git add Sources/MeetingAgentCore/MeetingProcessMonitor.swift Sources/MeetingAgentCore/MeetingRecorder.swift Sources/MeetingAgentCore/MeetingAgentViewModel.swift Sources/CoreAudioTapProbe/ProbeMain.swift Tests/MeetingAgentCoreTests/MeetingProcessMonitorTests.swift Tests/MeetingAgentCoreTests/MeetingRecorderTests.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift
git commit -m "feat: detect target process ended during capture (#15)"
```

Expected: commit created.
