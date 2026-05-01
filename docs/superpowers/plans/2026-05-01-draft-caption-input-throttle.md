# Draft Caption Input Throttle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Coalesce high-frequency active-recording draft transcript updates for 200 ms before they enter the live caption pipeline, without delaying first draft captions, final captions, stop flush, replay, or translation attachments.

**Architecture:** Add a focused `DraftCaptionInputThrottler` inside `MeetingAgentViewModel` that wraps `recorder.drainTranscriptUpdates()` output before `LiveCaptionPipeline.apply(...)`. The throttler owns pending draft input, timer cancellation, and telemetry; `LiveCaptionPipeline` remains responsible for caption projection and translation scheduling. The existing UI snapshot debounce remains available but defaults to zero.

**Tech Stack:** Swift 5.9, Swift Concurrency `Task`, XCTest, existing `PerformanceEventLogger`, existing `TranscriptSegmentAccumulationResult` and `MeetingAgentViewModel.ActiveCaptionApplyContext`.

---

## File Structure

- Modify `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
  - Add `draftCaptionInputThrottleNanoseconds` initializer configuration.
  - Add pending source-throttle state and helper methods near active caption apply logic.
  - Change `liveCaptionSnapshotDebounceNanoseconds` default to `0`.
  - Route active recording transcript updates through the source throttler.
  - Cancel pending source-throttle tasks on reset, meeting switch, stop, and stale apply invalidation.
- Modify `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`
  - Add active-recording tests using `ViewModelRecorderFixture.transcriber.emit(...)` and `drainRecordingFrames()`.
  - Update the existing UI snapshot debounce default expectation if needed.
  - Keep existing tests that explicitly inject non-zero `liveCaptionSnapshotDebounceNanoseconds`.

No new production file is required. Keeping the throttler private to `MeetingAgentViewModel` is sufficient because it depends on ViewModel apply context and publication cancellation semantics.

---

### Task 1: Lock The UI Debounce Default Change

**Files:**
- Modify: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`

- [ ] **Step 1: Add a failing test proving default snapshot publication is immediate**

Add this test near `testActiveTranscriptUpdatesAreAppliedThroughPipeline`:

```swift
func testDefaultLiveCaptionSnapshotPublicationIsImmediate() async throws {
    let fixture = try ViewModelRecorderFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
    let viewModel = MeetingAgentViewModel(
        store: fixture.store,
        recorder: fixture.recorder,
        processTargetsProvider: { [target] }
    )
    try await viewModel.startRecording(for: target)
    var accumulator = TranscriptSegmentAccumulator()
    let result = accumulator.apply(.upsert(TranscriptSegment(
        id: "default-draft",
        text: "default debounce should not hold this",
        language: "en-US",
        isFinal: false
    )))

    await viewModel.applyTranscriptAccumulationResultsForTesting([result])

    XCTAssertEqual(viewModel.liveCaptionTurns.first?.sourceSegmentID, "default-draft")
    XCTAssertEqual(viewModel.liveCaptionTurns.first?.originalText, "default debounce should not hold this")
}
```

- [ ] **Step 2: Run the focused test and verify it fails**

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testDefaultLiveCaptionSnapshotPublicationIsImmediate
```

Expected: FAIL because default `liveCaptionSnapshotDebounceNanoseconds` is still `75_000_000`, so the draft snapshot is not immediately visible.

- [ ] **Step 3: Change the default UI debounce to zero**

In `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`, change the initializer default:

```swift
liveCaptionSnapshotDebounceNanoseconds: UInt64 = 0,
```

Do not remove the existing UI debounce implementation. Existing tests that inject `100_000_000` or `1_000_000_000` must continue to exercise that path.

- [ ] **Step 4: Run the focused test and existing snapshot debounce tests**

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testDefaultLiveCaptionSnapshotPublicationIsImmediate
swift test --filter MeetingAgentViewModelTests/testDraftCaptionSnapshotsAreDebouncedBeforePublication
swift test --filter MeetingAgentViewModelTests/testFinalCaptionSnapshotPublishesImmediatelyAndCancelsPendingDraft
swift test --filter MeetingAgentViewModelTests/testCoalescedDraftCaptionSnapshotsLogPerformanceEvent
```

Expected: all four tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingAgentCore/MeetingAgentViewModel.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift
git commit -m "test: make live caption snapshot debounce opt-in"
```

---

### Task 2: Add Source Throttle Tests

**Files:**
- Modify: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] **Step 1: Add a test that first active-recording draft applies immediately**

Add this test near the active transcript tests:

```swift
func testDraftCaptionInputThrottlePublishesFirstDraftImmediately() async throws {
    let fixture = try ViewModelRecorderFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
    let viewModel = MeetingAgentViewModel(
        store: fixture.store,
        recorder: fixture.recorder,
        draftCaptionInputThrottleNanoseconds: 200_000_000,
        processTargetsProvider: { [target] }
    )
    try await viewModel.startRecording(for: target)

    fixture.transcriber.emit(.upsert(TranscriptSegment(
        id: "source-draft-1",
        text: "first draft appears immediately",
        language: "en-US",
        isFinal: false
    )))
    viewModel.drainRecordingFrames()

    try await waitFor {
        viewModel.liveCaptionTurns.first?.originalText == "first draft appears immediately"
    }
    XCTAssertEqual(viewModel.liveCaptionTurns.first?.sourceSegmentID, "source-draft-1")
}
```

- [ ] **Step 2: Add a test that rapid active-recording draft updates coalesce**

Add this test after the first-draft test:

```swift
func testDraftCaptionInputThrottleCoalescesRapidDraftUpdatesBeforePipeline() async throws {
    let fixture = try ViewModelRecorderFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
    let viewModel = MeetingAgentViewModel(
        store: fixture.store,
        recorder: fixture.recorder,
        draftCaptionInputThrottleNanoseconds: 200_000_000,
        processTargetsProvider: { [target] }
    )
    try await viewModel.startRecording(for: target)

    fixture.transcriber.emit(.upsert(TranscriptSegment(
        id: "source-draft-1",
        text: "first draft",
        language: "en-US",
        isFinal: false
    )))
    viewModel.drainRecordingFrames()
    try await waitFor { viewModel.liveCaptionTurns.first?.originalText == "first draft" }

    fixture.transcriber.emit(.upsert(TranscriptSegment(
        id: "source-draft-1",
        text: "second draft should be replaced",
        language: "en-US",
        isFinal: false
    )))
    viewModel.drainRecordingFrames()
    fixture.transcriber.emit(.upsert(TranscriptSegment(
        id: "source-draft-1",
        text: "third draft wins",
        language: "en-US",
        isFinal: false
    )))
    viewModel.drainRecordingFrames()

    try await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertEqual(viewModel.liveCaptionTurns.first?.originalText, "first draft")

    try await waitFor {
        viewModel.liveCaptionTurns.first?.originalText == "third draft wins"
    }
    XCTAssertEqual(viewModel.liveCaptionTurns.count, 1)
}
```

- [ ] **Step 3: Add a test that final bypasses pending source throttle**

Add:

```swift
func testFinalTranscriptUpdateBypassesDraftCaptionInputThrottle() async throws {
    let fixture = try ViewModelRecorderFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
    let viewModel = MeetingAgentViewModel(
        store: fixture.store,
        recorder: fixture.recorder,
        draftCaptionInputThrottleNanoseconds: 1_000_000_000,
        processTargetsProvider: { [target] }
    )
    try await viewModel.startRecording(for: target)

    fixture.transcriber.emit(.upsert(TranscriptSegment(
        id: "final-bypass",
        text: "draft text",
        language: "en-US",
        isFinal: false
    )))
    viewModel.drainRecordingFrames()
    try await waitFor { viewModel.liveCaptionTurns.first?.originalText == "draft text" }

    fixture.transcriber.emit(.upsert(TranscriptSegment(
        id: "final-bypass",
        text: "pending draft text",
        language: "en-US",
        isFinal: false
    )))
    viewModel.drainRecordingFrames()
    XCTAssertEqual(viewModel.liveCaptionTurns.first?.originalText, "draft text")

    fixture.transcriber.emit(.upsert(TranscriptSegment(
        id: "final-bypass",
        text: "final text",
        language: "en-US",
        isFinal: true,
        speechFinal: true
    )))
    viewModel.drainRecordingFrames()

    XCTAssertEqual(viewModel.liveCaptionTurns.first?.originalText, "final text")
    XCTAssertEqual(viewModel.liveCaptionTurns.first?.isFinal, true)

    try await Task.sleep(nanoseconds: 150_000_000)
    XCTAssertEqual(viewModel.liveCaptionTurns.first?.originalText, "final text")
}
```

- [ ] **Step 4: Add a test that stop flush cancels pending source throttle**

Add:

```swift
func testStopRecordingCancelsPendingDraftCaptionInputThrottle() async throws {
    let fixture = try ViewModelRecorderFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
    let viewModel = MeetingAgentViewModel(
        store: fixture.store,
        recorder: fixture.recorder,
        draftCaptionInputThrottleNanoseconds: 1_000_000_000,
        processTargetsProvider: { [target] }
    )
    try await viewModel.startRecording(for: target)

    fixture.transcriber.emit(.upsert(TranscriptSegment(
        id: "stop-throttle",
        text: "visible draft",
        language: "en-US",
        isFinal: false
    )))
    viewModel.drainRecordingFrames()
    try await waitFor { viewModel.liveCaptionTurns.first?.originalText == "visible draft" }

    fixture.transcriber.emit(.upsert(TranscriptSegment(
        id: "stop-throttle",
        text: "pending draft should not publish after stop",
        language: "en-US",
        isFinal: false
    )))
    viewModel.drainRecordingFrames()
    viewModel.stopRecording(at: Date(timeIntervalSince1970: 200))

    XCTAssertEqual(viewModel.liveCaptionTurns.first?.freezeReason, .manualStop)
    try await Task.sleep(nanoseconds: 150_000_000)
    XCTAssertNotEqual(viewModel.liveCaptionTurns.first?.originalText, "pending draft should not publish after stop")
}
```

- [ ] **Step 5: Add a test that source throttle logs coalescing telemetry**

Add:

```swift
func testDraftCaptionInputThrottleLogsCoalescingTelemetry() async throws {
    let fixture = try ViewModelRecorderFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
    let viewModel = MeetingAgentViewModel(
        store: fixture.store,
        recorder: fixture.recorder,
        draftCaptionInputThrottleNanoseconds: 200_000_000,
        processTargetsProvider: { [target] }
    )
    try await viewModel.startRecording(for: target)
    let record = try XCTUnwrap(viewModel.selectedMeeting)

    fixture.transcriber.emit(.upsert(TranscriptSegment(
        id: "telemetry-draft",
        text: "first",
        language: "en-US",
        isFinal: false
    )))
    viewModel.drainRecordingFrames()
    try await waitFor { viewModel.liveCaptionTurns.first?.originalText == "first" }

    fixture.transcriber.emit(.upsert(TranscriptSegment(
        id: "telemetry-draft",
        text: "second",
        language: "en-US",
        isFinal: false
    )))
    viewModel.drainRecordingFrames()
    fixture.transcriber.emit(.upsert(TranscriptSegment(
        id: "telemetry-draft",
        text: "third",
        language: "en-US",
        isFinal: false
    )))
    viewModel.drainRecordingFrames()

    try await waitFor {
        ((try? readPerformanceEvents(from: XCTUnwrap(record.performanceEventsURL))) ?? [])
            .contains { $0.event == "caption_input_throttle_fired" }
    }
    let events = try readPerformanceEvents(from: XCTUnwrap(record.performanceEventsURL))
    XCTAssertTrue(events.contains { $0.event == "caption_input_throttle_scheduled" })
    XCTAssertTrue(events.contains { $0.event == "caption_input_throttle_coalesced" })
    XCTAssertTrue(events.contains {
        $0.event == "caption_input_throttle_fired"
            && $0.metadata["delayMilliseconds"] == "200"
            && $0.metadata["latestChangedSegmentID"] == "telemetry-draft"
    })
}
```

- [ ] **Step 6: Run source throttle tests and verify they fail**

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testDraftCaptionInputThrottlePublishesFirstDraftImmediately
swift test --filter MeetingAgentViewModelTests/testDraftCaptionInputThrottleCoalescesRapidDraftUpdatesBeforePipeline
swift test --filter MeetingAgentViewModelTests/testFinalTranscriptUpdateBypassesDraftCaptionInputThrottle
swift test --filter MeetingAgentViewModelTests/testStopRecordingCancelsPendingDraftCaptionInputThrottle
swift test --filter MeetingAgentViewModelTests/testDraftCaptionInputThrottleLogsCoalescingTelemetry
```

Expected: the first test may pass without implementation, but the coalescing, final-bypass cancellation, stop cancellation, and telemetry tests should FAIL because the source input throttle does not exist.

- [ ] **Step 7: Commit failing tests**

```bash
git add Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift
git commit -m "test: define draft caption input throttle behavior"
```

---

### Task 3: Implement Source Draft Input Throttling

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`

- [ ] **Step 1: Add configuration and pending throttle state**

Add a new stored property near `liveCaptionSnapshotDebounceNanoseconds`:

```swift
private let draftCaptionInputThrottleNanoseconds: UInt64
private var pendingDraftCaptionInput: PendingDraftCaptionInput?
private var pendingDraftCaptionInputTask: Task<Void, Never>?
private var pendingDraftCaptionInputGeneration = 0
private var hasPublishedActiveDraftCaptionInput = false
```

Add this private struct near `ActiveCaptionApplyContext`:

```swift
private struct PendingDraftCaptionInput {
    var results: [TranscriptSegmentAccumulationResult]
    var context: ActiveCaptionApplyContext
    var latestChangedSegmentID: String?
    var changedSegmentCount: Int
}
```

Add the new initializer parameter after `liveCaptionSnapshotDebounceNanoseconds`:

```swift
draftCaptionInputThrottleNanoseconds: UInt64 = 200_000_000,
```

Assign it in `init`:

```swift
self.draftCaptionInputThrottleNanoseconds = draftCaptionInputThrottleNanoseconds
```

- [ ] **Step 2: Add source throttle cancellation helpers**

Add these helpers near `invalidateActiveCaptionApplyTasks()`:

```swift
private func cancelPendingDraftCaptionInput(reason: String) {
    guard pendingDraftCaptionInput != nil || pendingDraftCaptionInputTask != nil else {
        return
    }
    currentPerformanceEventLogger()?.log(
        "caption_input_throttle_cancelled",
        metadata: [
            "reason": reason,
            "delayMilliseconds": String(draftCaptionInputThrottleNanoseconds / 1_000_000)
        ]
    )
    pendingDraftCaptionInputGeneration += 1
    pendingDraftCaptionInputTask?.cancel()
    pendingDraftCaptionInputTask = nil
    pendingDraftCaptionInput = nil
}

private func resetDraftCaptionInputThrottleState(reason: String) {
    cancelPendingDraftCaptionInput(reason: reason)
    hasPublishedActiveDraftCaptionInput = false
}
```

Update `invalidateActiveCaptionApplyTasks()`:

```swift
private func invalidateActiveCaptionApplyTasks() {
    activeCaptionApplySequence += 1
    activeCaptionApplyTask?.cancel()
    activeCaptionApplyTask = nil
    cancelPendingDraftCaptionInput(reason: "active_apply_invalidated")
}
```

Update `resetLiveCaptionPipeline()` after `activeCaptionDocumentSignature = nil`:

```swift
resetDraftCaptionInputThrottleState(reason: "pipeline_reset")
```

Update `clearLiveCaptionTurns()` before clearing turns:

```swift
cancelPendingDraftCaptionInput(reason: "caption_turns_cleared")
```

Update `flushLiveCaptionPipeline(reason:)` before `beginActiveCaptionApply()`:

```swift
cancelPendingDraftCaptionInput(reason: "flush")
```

- [ ] **Step 3: Add delayable draft classification**

Add:

```swift
private func shouldThrottleDraftCaptionInput(
    _ results: [TranscriptSegmentAccumulationResult],
    context: ActiveCaptionApplyContext
) -> Bool {
    guard draftCaptionInputThrottleNanoseconds > 0 else { return false }
    guard isCurrentActiveCaptionApply(context) else { return false }
    guard activeMeetingID != nil else { return false }
    guard let latest = results.last else { return false }
    guard latest.plainTextReplacement == nil else { return false }
    guard !latest.changedSegmentIDs.isEmpty else { return false }
    let changedSegmentIDs = Set(latest.changedSegmentIDs)
    let changedSegments = latest.document.segments.filter { changedSegmentIDs.contains($0.id) }
    guard !changedSegments.isEmpty else { return false }
    return changedSegments.allSatisfy { segment in
        !segment.isFinal && segment.speechFinal != true
    }
}

private func latestChangedSegmentID(in results: [TranscriptSegmentAccumulationResult]) -> String? {
    results.last?.changedSegmentIDs.last
}

private func changedSegmentCount(in results: [TranscriptSegmentAccumulationResult]) -> Int {
    results.last?.changedSegmentIDs.count ?? 0
}
```

This intentionally throttles only true interim drafts. Final and `speechFinal` updates bypass.

- [ ] **Step 4: Add throttle submit and fire methods**

Add:

```swift
private func submitDraftCaptionInput(
    _ results: [TranscriptSegmentAccumulationResult],
    context: ActiveCaptionApplyContext
) {
    guard hasPublishedActiveDraftCaptionInput else {
        hasPublishedActiveDraftCaptionInput = true
        activeCaptionApplyTask = Task { [weak self] in
            guard let self else { return }
            await applyTranscriptAccumulationResultsToLiveCaptions(results, context: context)
            if meetingProgressCoordinator != nil {
                await refreshMeetingProgress()
            }
        }
        return
    }

    let pending = PendingDraftCaptionInput(
        results: results,
        context: context,
        latestChangedSegmentID: latestChangedSegmentID(in: results),
        changedSegmentCount: changedSegmentCount(in: results)
    )
    let hadPending = pendingDraftCaptionInput != nil
    pendingDraftCaptionInput = pending
    pendingDraftCaptionInputGeneration += 1
    let generation = pendingDraftCaptionInputGeneration
    let delay = draftCaptionInputThrottleNanoseconds
    pendingDraftCaptionInputTask?.cancel()
    currentPerformanceEventLogger()?.log(
        hadPending ? "caption_input_throttle_coalesced" : "caption_input_throttle_scheduled",
        segmentID: pending.latestChangedSegmentID,
        metadata: draftCaptionInputThrottleMetadata(for: pending, reason: hadPending ? "replaced_pending" : "scheduled")
    )
    pendingDraftCaptionInputTask = Task { [weak self] in
        try? await Task.sleep(nanoseconds: delay)
        guard !Task.isCancelled else { return }
        await self?.firePendingDraftCaptionInput(generation: generation)
    }
}

private func firePendingDraftCaptionInput(generation: Int) async {
    guard generation == pendingDraftCaptionInputGeneration,
          let pending = pendingDraftCaptionInput
    else {
        return
    }
    pendingDraftCaptionInputTask = nil
    pendingDraftCaptionInput = nil
    currentPerformanceEventLogger()?.log(
        "caption_input_throttle_fired",
        segmentID: pending.latestChangedSegmentID,
        metadata: draftCaptionInputThrottleMetadata(for: pending, reason: "delay_elapsed")
    )
    guard isCurrentActiveCaptionApply(pending.context) else { return }
    activeCaptionApplyTask = Task { [weak self] in
        guard let self else { return }
        await applyTranscriptAccumulationResultsToLiveCaptions(pending.results, context: pending.context)
        if meetingProgressCoordinator != nil {
            await refreshMeetingProgress()
        }
    }
}

private func draftCaptionInputThrottleMetadata(
    for pending: PendingDraftCaptionInput,
    reason: String
) -> [String: String] {
    var metadata: [String: String] = [
        "delayMilliseconds": String(draftCaptionInputThrottleNanoseconds / 1_000_000),
        "changedSegmentCount": String(pending.changedSegmentCount),
        "reason": reason
    ]
    if let latestChangedSegmentID = pending.latestChangedSegmentID {
        metadata["latestChangedSegmentID"] = latestChangedSegmentID
    }
    if let activeMeetingID = pending.context.activeMeetingID {
        metadata["activeMeetingID"] = activeMeetingID.uuidString
    }
    if let selectedMeetingID = pending.context.selectedMeetingID {
        metadata["selectedMeetingID"] = selectedMeetingID.uuidString
    }
    return metadata
}
```

- [ ] **Step 5: Route active transcript updates through the throttler**

In `drainRecordingFrames(endedAt:)`, replace the `else` branch body that always creates `activeCaptionApplyTask` with:

```swift
} else {
    let context = beginActiveCaptionApply()
    activeCaptionApplyTask?.cancel()
    if shouldThrottleDraftCaptionInput(transcriptResults, context: context) {
        submitDraftCaptionInput(transcriptResults, context: context)
    } else {
        cancelPendingDraftCaptionInput(reason: "non_delayable_update")
        activeCaptionApplyTask = Task { [weak self] in
            guard let self else { return }
            await applyTranscriptAccumulationResultsToLiveCaptions(transcriptResults, context: context)
            if meetingProgressCoordinator != nil {
                await refreshMeetingProgress()
            }
        }
    }
}
```

Keep `applyTranscriptAccumulationResultsForTesting(...)` unchanged so existing tests can still exercise pipeline application directly without source throttle.

- [ ] **Step 6: Run source throttle tests**

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testDraftCaptionInputThrottlePublishesFirstDraftImmediately
swift test --filter MeetingAgentViewModelTests/testDraftCaptionInputThrottleCoalescesRapidDraftUpdatesBeforePipeline
swift test --filter MeetingAgentViewModelTests/testFinalTranscriptUpdateBypassesDraftCaptionInputThrottle
swift test --filter MeetingAgentViewModelTests/testStopRecordingCancelsPendingDraftCaptionInputThrottle
swift test --filter MeetingAgentViewModelTests/testDraftCaptionInputThrottleLogsCoalescingTelemetry
```

Expected: all PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/MeetingAgentCore/MeetingAgentViewModel.swift
git commit -m "feat: throttle draft caption input"
```

---

### Task 4: Add Cancellation And Regression Coverage

**Files:**
- Modify: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift` only if a test exposes a missing cancellation path.

- [ ] **Step 1: Add a test that selecting another meeting cancels pending source throttle**

Add:

```swift
func testSelectingAnotherMeetingCancelsPendingDraftCaptionInputThrottle() async throws {
    let fixture = try ViewModelRecorderFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
    let viewModel = MeetingAgentViewModel(
        store: fixture.store,
        recorder: fixture.recorder,
        draftCaptionInputThrottleNanoseconds: 1_000_000_000,
        processTargetsProvider: { [target] }
    )
    try await viewModel.startRecording(for: target)
    let secondMeeting = try fixture.store.createMeeting(name: "Second", startedAt: Date()).record

    fixture.transcriber.emit(.upsert(TranscriptSegment(
        id: "switch-throttle",
        text: "visible draft",
        language: "en-US",
        isFinal: false
    )))
    viewModel.drainRecordingFrames()
    try await waitFor { viewModel.liveCaptionTurns.first?.originalText == "visible draft" }

    fixture.transcriber.emit(.upsert(TranscriptSegment(
        id: "switch-throttle",
        text: "pending draft after switch",
        language: "en-US",
        isFinal: false
    )))
    viewModel.drainRecordingFrames()
    viewModel.selectMeeting(secondMeeting.id)

    try await Task.sleep(nanoseconds: 150_000_000)
    XCTAssertNotEqual(viewModel.liveCaptionTurns.first?.originalText, "pending draft after switch")
}
```

- [ ] **Step 2: Add a test that replay bypasses source throttle**

Add:

```swift
func testReplayBypassesDraftCaptionInputThrottle() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(baseDirectory: root)
    let record = try store.createMeeting(name: "Meet", startedAt: Date()).record
    let writer = try TranscriptFileWriter(url: XCTUnwrap(record.transcriptURL), structuredURL: XCTUnwrap(record.transcriptJSONURL))
    try writer.replace(with: [
        TranscriptSegment(id: "replay-draft", text: "historical draft", language: "en-US", isFinal: false)
    ])
    let viewModel = MeetingAgentViewModel(
        store: store,
        draftCaptionInputThrottleNanoseconds: 1_000_000_000,
        processTargetsProvider: { [] }
    )
    try viewModel.loadMeetings()
    viewModel.selectMeeting(record.id)
    await viewModel.waitForLiveCaptionReplayForTesting()

    XCTAssertEqual(viewModel.liveCaptionTurns.first?.originalText, "historical draft")
}
```

- [ ] **Step 3: Add a test that source throttle can be disabled**

Add:

```swift
func testDraftCaptionInputThrottleCanBeDisabled() async throws {
    let fixture = try ViewModelRecorderFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
    let viewModel = MeetingAgentViewModel(
        store: fixture.store,
        recorder: fixture.recorder,
        draftCaptionInputThrottleNanoseconds: 0,
        processTargetsProvider: { [target] }
    )
    try await viewModel.startRecording(for: target)

    fixture.transcriber.emit(.upsert(TranscriptSegment(
        id: "disabled-throttle",
        text: "first draft",
        language: "en-US",
        isFinal: false
    )))
    viewModel.drainRecordingFrames()
    try await waitFor { viewModel.liveCaptionTurns.first?.originalText == "first draft" }

    fixture.transcriber.emit(.upsert(TranscriptSegment(
        id: "disabled-throttle",
        text: "second draft immediately visible",
        language: "en-US",
        isFinal: false
    )))
    viewModel.drainRecordingFrames()

    XCTAssertEqual(viewModel.liveCaptionTurns.first?.originalText, "second draft immediately visible")
}
```

- [ ] **Step 4: Run regression tests**

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testSelectingAnotherMeetingCancelsPendingDraftCaptionInputThrottle
swift test --filter MeetingAgentViewModelTests/testReplayBypassesDraftCaptionInputThrottle
swift test --filter MeetingAgentViewModelTests/testDraftCaptionInputThrottleCanBeDisabled
swift test --filter MeetingAgentViewModelTests
```

Expected: all PASS.

- [ ] **Step 5: If cancellation tests fail, wire cancellation into the missing path**

If `selectMeeting` or reset tests fail, add `cancelPendingDraftCaptionInput(reason: "meeting_selection_changed")` before or inside the existing reset path. The expected implementation is:

```swift
private func resetLiveCaptionPipeline() {
    liveCaptionReplayTask?.cancel()
    liveCaptionReplayTask = nil
    liveCaptionReplaySequence += 1
    activeCaptionDocumentSignature = nil
    resetDraftCaptionInputThrottleState(reason: "pipeline_reset")
    clearLiveCaptionTurns()
    liveCaptionPipeline = makeLiveCaptionPipeline()
    liveCaptionPipelineUsesCaptionTranslationProvider = false
    liveCaptionPipelineHasTranslationProvider = false
    invalidateActiveCaptionApplyTasks()
}
```

Do not add a separate cancellation in `selectMeeting` if `resetLiveCaptionPipeline()` already covers it.

- [ ] **Step 6: Commit**

```bash
git add Sources/MeetingAgentCore/MeetingAgentViewModel.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift
git commit -m "test: cover draft caption input throttle cancellation"
```

---

### Task 5: Final Verification

**Files:**
- No code changes expected.

- [ ] **Step 1: Run full tests**

Run:

```bash
make test
```

Expected: all tests pass and coverage gate passes.

- [ ] **Step 2: Check git status**

Run:

```bash
git status --short
```

Expected: only intentional untracked user files may remain, such as `.env` and `x.log`; no modified tracked files.

- [ ] **Step 3: Summarize implementation**

Prepare a short summary with:

- default source draft input throttle is 200 ms
- first draft/final/flush/replay bypass behavior
- UI snapshot debounce default is now zero
- tests run and result

Do not claim production performance improvement until a new meeting is recorded with the implemented app and analyzed.
