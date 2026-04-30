# Live Caption Snapshot Debounce Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Debounce draft-only live caption UI snapshot publication while keeping pipeline ingestion and final caption publication immediate.

**Architecture:** `MeetingAgentViewModel` remains the presentation boundary for `@Published liveCaptionTurns`. It stores one pending delayable `LiveCaptionPipelineSnapshot`, schedules a short main-actor task, and cancels that task whenever an immediate snapshot, reset, or selection change happens. The caption pipeline and transcript persistence remain unchanged.

**Tech Stack:** Swift 5.9, Swift concurrency on `@MainActor`, XCTest, existing `PerformanceEventLogger`.

---

### Task 1: Add Focused Failing Tests

**Files:**
- Modify: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] **Step 1: Add draft debounce and immediate final tests**

Add tests near the existing active live caption tests:

```swift
func testDraftCaptionSnapshotsAreDebouncedBeforePublication() async throws {
    let fixture = try ViewModelRecorderFixture()
    let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
    let viewModel = MeetingAgentViewModel(
        store: fixture.store,
        recorder: fixture.recorder,
        liveCaptionSnapshotDebounceNanoseconds: 100_000_000,
        processTargetsProvider: { [target] }
    )
    try await viewModel.startRecording(for: target)
    var accumulator = TranscriptSegmentAccumulator()

    let first = accumulator.apply(.upsert(TranscriptSegment(
        id: "draft-1",
        text: "first draft",
        language: "en-US",
        isFinal: false
    )))
    await viewModel.applyTranscriptAccumulationResultsForTesting([first])
    XCTAssertTrue(viewModel.liveCaptionTurns.isEmpty)

    let second = accumulator.apply(.upsert(TranscriptSegment(
        id: "draft-1",
        text: "second draft",
        language: "en-US",
        isFinal: false
    )))
    await viewModel.applyTranscriptAccumulationResultsForTesting([second])
    XCTAssertTrue(viewModel.liveCaptionTurns.isEmpty)

    try await waitFor {
        viewModel.liveCaptionTurns.first?.originalText == "second draft"
    }
    XCTAssertEqual(viewModel.liveCaptionTurns.count, 1)
}

func testFinalCaptionSnapshotPublishesImmediatelyAndCancelsPendingDraft() async throws {
    let fixture = try ViewModelRecorderFixture()
    let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
    let viewModel = MeetingAgentViewModel(
        store: fixture.store,
        recorder: fixture.recorder,
        liveCaptionSnapshotDebounceNanoseconds: 1_000_000_000,
        processTargetsProvider: { [target] }
    )
    try await viewModel.startRecording(for: target)
    var accumulator = TranscriptSegmentAccumulator()

    let draft = accumulator.apply(.upsert(TranscriptSegment(
        id: "caption-1",
        text: "draft text",
        language: "en-US",
        isFinal: false
    )))
    await viewModel.applyTranscriptAccumulationResultsForTesting([draft])
    XCTAssertTrue(viewModel.liveCaptionTurns.isEmpty)

    let final = accumulator.apply(.upsert(TranscriptSegment(
        id: "caption-1",
        text: "final text",
        language: "en-US",
        isFinal: true,
        speechFinal: true
    )))
    await viewModel.applyTranscriptAccumulationResultsForTesting([final])

    XCTAssertEqual(viewModel.liveCaptionTurns.first?.originalText, "final text")
    XCTAssertEqual(viewModel.liveCaptionTurns.first?.isFinal, true)

    try await Task.sleep(nanoseconds: 150_000_000)
    XCTAssertEqual(viewModel.liveCaptionTurns.first?.originalText, "final text")
}
```

- [ ] **Step 2: Add reset cancellation and coalesced metric tests**

Add tests near the same section:

```swift
func testSelectingAnotherMeetingCancelsPendingDraftCaptionSnapshot() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(baseDirectory: root)
    let firstRecord = try store.createMeeting(name: "First", startedAt: Date()).record
    let secondRecord = try store.createMeeting(name: "Second", startedAt: Date()).record
    let viewModel = MeetingAgentViewModel(
        store: store,
        liveCaptionSnapshotDebounceNanoseconds: 1_000_000_000,
        processTargetsProvider: { [] }
    )
    try viewModel.loadMeetings()
    viewModel.selectMeeting(firstRecord.id)
    viewModel.setActiveMeetingForTesting(firstRecord.id)
    var accumulator = TranscriptSegmentAccumulator()

    let draft = accumulator.apply(.upsert(TranscriptSegment(
        id: "stale-draft",
        text: "stale draft",
        language: "en-US",
        isFinal: false
    )))
    await viewModel.applyTranscriptAccumulationResultsForTesting([draft])
    XCTAssertTrue(viewModel.liveCaptionTurns.isEmpty)

    viewModel.selectMeeting(secondRecord.id)
    try await Task.sleep(nanoseconds: 150_000_000)
    XCTAssertTrue(viewModel.liveCaptionTurns.isEmpty)
}

func testCoalescedDraftCaptionSnapshotsLogPerformanceEvent() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(baseDirectory: root)
    let record = try store.createMeeting(name: "Meet", startedAt: Date()).record
    let viewModel = MeetingAgentViewModel(
        store: store,
        liveCaptionSnapshotDebounceNanoseconds: 100_000_000,
        processTargetsProvider: { [] }
    )
    try viewModel.loadMeetings()
    viewModel.selectMeeting(record.id)
    viewModel.setActiveMeetingForTesting(record.id)
    var accumulator = TranscriptSegmentAccumulator()

    let first = accumulator.apply(.upsert(TranscriptSegment(
        id: "metric-draft",
        text: "first",
        language: "en-US",
        isFinal: false
    )))
    await viewModel.applyTranscriptAccumulationResultsForTesting([first])
    let second = accumulator.apply(.upsert(TranscriptSegment(
        id: "metric-draft",
        text: "second",
        language: "en-US",
        isFinal: false
    )))
    await viewModel.applyTranscriptAccumulationResultsForTesting([second])

    try await waitFor {
        ((try? readPerformanceEvents(from: XCTUnwrap(record.performanceEventsURL))) ?? [])
            .contains(where: { $0.event == "caption_snapshot_publication_coalesced" })
    }
}
```

- [ ] **Step 3: Run focused tests and verify they fail**

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testDraftCaptionSnapshotsAreDebouncedBeforePublication
```

Expected: compile failure because `liveCaptionSnapshotDebounceNanoseconds` and `setActiveMeetingForTesting` are not yet implemented, or assertion failure because draft snapshots publish immediately.

### Task 2: Add ViewModel Debounce State and Injection

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`

- [ ] **Step 1: Add stored properties**

Add private state beside existing caption task state:

```swift
private let liveCaptionSnapshotDebounceNanoseconds: UInt64
private var pendingLiveCaptionSnapshot: LiveCaptionPipelineSnapshot?
private var pendingLiveCaptionSnapshotTask: Task<Void, Never>?
private var pendingLiveCaptionSnapshotGeneration = 0
```

- [ ] **Step 2: Add initializer parameter**

Add this parameter before `processTargetsProvider`:

```swift
liveCaptionSnapshotDebounceNanoseconds: UInt64 = 75_000_000,
```

Assign it in `init`:

```swift
self.liveCaptionSnapshotDebounceNanoseconds = liveCaptionSnapshotDebounceNanoseconds
```

- [ ] **Step 3: Run compile check**

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testDraftCaptionSnapshotsAreDebouncedBeforePublication
```

Expected: tests still fail until publication logic exists.

### Task 3: Implement Immediate vs Delayable Publication

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`

- [ ] **Step 1: Add cancellation helper**

Add helper methods near `publishLiveCaptionPipelineSnapshot`:

```swift
private func cancelPendingLiveCaptionSnapshotPublication() {
    pendingLiveCaptionSnapshotGeneration += 1
    pendingLiveCaptionSnapshotTask?.cancel()
    pendingLiveCaptionSnapshotTask = nil
    pendingLiveCaptionSnapshot = nil
}

private func publishLiveCaptionPipelineSnapshotImmediately(_ snapshot: LiveCaptionPipelineSnapshot) {
    liveCaptionTurns = snapshot.turns
    meetingProgressHealth.caption = snapshot.captionHealth
    meetingProgressHealth.translation = snapshot.translationHealth
}
```

- [ ] **Step 2: Add delayability predicate**

Add:

```swift
private func shouldDebounceLiveCaptionSnapshot(_ snapshot: LiveCaptionPipelineSnapshot) -> Bool {
    guard liveCaptionSnapshotDebounceNanoseconds > 0 else { return false }
    guard snapshot.captionHealth == .live, snapshot.translationHealth != .failed else { return false }
    guard !snapshot.turns.isEmpty else { return false }
    let previousTurns = pendingLiveCaptionSnapshot?.turns ?? liveCaptionTurns
    guard !previousTurns.isEmpty else {
        return snapshot.turns.allSatisfy(isDelayableDraftCaptionTurn)
    }
    let previousTurnsByID = Dictionary(uniqueKeysWithValues: previousTurns.map { ($0.id, $0) })
    let snapshotTurnsByID = Dictionary(uniqueKeysWithValues: snapshot.turns.map { ($0.id, $0) })
    let changedSnapshotTurns = snapshot.turns.filter { previousTurnsByID[$0.id] != $0 }
    let removedPreviousTurns = previousTurns.filter { snapshotTurnsByID[$0.id] == nil }
    guard !changedSnapshotTurns.isEmpty || !removedPreviousTurns.isEmpty else {
        return false
    }
    return changedSnapshotTurns.allSatisfy(isDelayableDraftCaptionTurn)
        && removedPreviousTurns.allSatisfy(isDelayableDraftCaptionTurn)
}

private func isDelayableDraftCaptionTurn(_ turn: LiveCaptionTurn) -> Bool {
    turn.displayState == .draft && !turn.isFinal && turn.boundaryStrength != .hard
}
```

If `translationHealth` is not Equatable-friendly for `.failed`, use a `switch` over `snapshot.translationHealth`.

- [ ] **Step 3: Replace publication method**

Replace `publishLiveCaptionPipelineSnapshot` with:

```swift
private func publishLiveCaptionPipelineSnapshot(_ snapshot: LiveCaptionPipelineSnapshot) {
    guard shouldDebounceLiveCaptionSnapshot(snapshot) else {
        cancelPendingLiveCaptionSnapshotPublication()
        publishLiveCaptionPipelineSnapshotImmediately(snapshot)
        return
    }

    if let pendingLiveCaptionSnapshot {
        currentPerformanceEventLogger()?.log(
            "caption_snapshot_publication_coalesced",
            metadata: [
                "pendingTurnCount": String(pendingLiveCaptionSnapshot.turns.count),
                "replacementTurnCount": String(snapshot.turns.count),
                "debounceMilliseconds": String(liveCaptionSnapshotDebounceNanoseconds / 1_000_000)
            ]
        )
    }
    pendingLiveCaptionSnapshot = snapshot
    pendingLiveCaptionSnapshotGeneration += 1
    let generation = pendingLiveCaptionSnapshotGeneration
    pendingLiveCaptionSnapshotTask?.cancel()
    pendingLiveCaptionSnapshotTask = Task { [weak self] in
        try? await Task.sleep(nanoseconds: self?.liveCaptionSnapshotDebounceNanoseconds ?? 0)
        await self?.publishPendingLiveCaptionSnapshot(generation: generation)
    }
}

private func publishPendingLiveCaptionSnapshot(generation: Int) {
    guard generation == pendingLiveCaptionSnapshotGeneration,
          let snapshot = pendingLiveCaptionSnapshot
    else {
        return
    }
    pendingLiveCaptionSnapshotTask = nil
    pendingLiveCaptionSnapshot = nil
    publishLiveCaptionPipelineSnapshotImmediately(snapshot)
}
```

- [ ] **Step 4: Cancel pending snapshots on resets**

Call `cancelPendingLiveCaptionSnapshotPublication()` before direct `liveCaptionTurns = []` assignments in reset and no-document paths.

- [ ] **Step 5: Run focused tests**

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testDraftCaptionSnapshotsAreDebouncedBeforePublication
swift test --filter MeetingAgentViewModelTests/testFinalCaptionSnapshotPublishesImmediatelyAndCancelsPendingDraft
swift test --filter MeetingAgentViewModelTests/testSelectingAnotherMeetingCancelsPendingDraftCaptionSnapshot
swift test --filter MeetingAgentViewModelTests/testCoalescedDraftCaptionSnapshotsLogPerformanceEvent
```

Expected: all pass.

### Task 4: Preserve Stop Flush and Existing Behaviors

**Files:**
- Modify: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift` if focused tests reveal an issue

- [ ] **Step 1: Run existing stop flush test**

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testStopRecordingPublishesDelayedFlushedFinalTranslation
```

Expected: PASS because `flushLiveCaptionPipeline` produces frozen/final snapshots that bypass debounce.

- [ ] **Step 2: Run existing active caption tests**

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testActiveRecordingCaptionDoesNotRequireTranscriptFileReload
swift test --filter MeetingAgentViewModelTests/testActiveTranscriptUpdatesAreAppliedThroughPipeline
swift test --filter MeetingAgentViewModelTests/testStaleActiveTranscriptApplyDoesNotOverwriteNewerCaption
```

Expected: update tests only if they intentionally asserted immediate draft UI publication; keep data-pipeline behavior unchanged.

### Task 5: Full Verification and Commit

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Modify: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`
- Already added: `docs/superpowers/specs/2026-04-30-live-caption-snapshot-debounce-design.md`
- Added: `docs/superpowers/plans/2026-04-30-live-caption-snapshot-debounce.md`

- [ ] **Step 1: Run focused suite**

Run:

```bash
swift test --filter MeetingAgentViewModelTests
```

Expected: PASS.

- [ ] **Step 2: Run required coverage gate**

Run:

```bash
make test
```

Expected: PASS.

- [ ] **Step 3: Commit implementation**

Run:

```bash
git add Sources/MeetingAgentCore/MeetingAgentViewModel.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift docs/superpowers/plans/2026-04-30-live-caption-snapshot-debounce.md
git commit -m "feat: debounce live caption snapshot publication (#119)"
```

Expected: commit created.

## Self-Review

- Spec coverage: draft coalescing is Task 1 and Task 3; final/hard-boundary immediate publication is Task 1 and Task 3; reset cancellation is Task 1 and Task 3; stop flush is Task 4; metrics are Task 1 and Task 3.
- Placeholder scan: no placeholder steps remain.
- Type consistency: all new APIs are owned by `MeetingAgentViewModel`; tests use existing transcript accumulator and fixture patterns.
