# Realtime Caption Translation Decoupling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make original realtime captions publish without waiting for translation provider work, then apply translated text later as an overlay.

**Architecture:** Keep `LiveCaptionPipeline` as the owner of caption projection and translation application rules, but make realtime `apply(_:)` caption-only. `MeetingAgentViewModel` publishes the caption snapshot immediately and runs a single background translation pump that calls the existing scheduler, validates context, and publishes overlay snapshots.

**Tech Stack:** Swift 5.9, Swift Concurrency, SwiftUI `ObservableObject`, XCTest, existing `CaptionTranslationScheduler`, existing transcript persistence callbacks.

---

## File Structure

- Modify `Sources/MeetingAgentCore/LiveCaptionPipeline.swift`: remove realtime translation scheduling from `apply(_:)`; add UI publication performance events; keep existing replay/final translation scheduling behavior.
- Modify `Sources/MeetingAgentCore/RealtimeCaptionSession.swift`: add a live translation scheduling method and keep caption application as the session boundary.
- Modify `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`: add a background realtime translation pump, generation/context invalidation, and original/overlay publication telemetry.
- Modify `Tests/MeetingAgentCoreTests/LiveCaptionPipelineTests.swift`: update pipeline tests that assumed `apply(_:)` performs provider-backed translation.
- Modify `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`: add decoupling regression tests and adjust tests that assume translation is available immediately after caption apply.

## Task 1: Make `LiveCaptionPipeline.apply(_:)` Caption-Only

**Files:**
- Modify: `Sources/MeetingAgentCore/LiveCaptionPipeline.swift:60-90`
- Test: `Tests/MeetingAgentCoreTests/LiveCaptionPipelineTests.swift`

- [ ] **Step 1: Write a failing pipeline test**

Add this test near the existing translation tests in `Tests/MeetingAgentCoreTests/LiveCaptionPipelineTests.swift`:

```swift
func testRealtimeApplyDoesNotAwaitCaptionTranslationProvider() async throws {
    let provider = PipelineRecordingTranslationProvider(
        translations: ["segment-1": "翻译"],
        delayNanoseconds: 500_000_000
    )
    let pipeline = LiveCaptionPipeline(
        sourceLocale: "en-US",
        targetLocale: "zh-CN",
        translationProvider: provider,
        performanceEventLogger: nil
    )
    let startedAt = Date()

    let snapshot = await pipeline.apply(TranscriptSegmentAccumulationResult(
        document: TranscriptDocument(segments: [
            TranscriptSegment(
                id: "segment-1",
                text: "Caption should publish first.",
                language: "en-US",
                isFinal: false
            )
        ]),
        changedSegmentIDs: ["segment-1"],
        plainTextReplacement: nil
    ))

    XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.2)
    XCTAssertEqual(snapshot.turns.first?.originalText, "Caption should publish first.")
    XCTAssertNil(snapshot.turns.first?.translatedText)
    XCTAssertTrue(provider.requests.isEmpty)
}
```

- [ ] **Step 2: Run the failing test**

Run:

```bash
swift test --filter LiveCaptionPipelineTests/testRealtimeApplyDoesNotAwaitCaptionTranslationProvider
```

Expected before implementation: it fails because `pipeline.apply(_:)` waits on the delayed translation provider or records a provider request.

- [ ] **Step 3: Remove realtime translation scheduling from `apply(_:)`**

In `Sources/MeetingAgentCore/LiveCaptionPipeline.swift`, change `apply(_:)` so the realtime path returns immediately after caption projection:

```swift
public func apply(_ result: TranscriptSegmentAccumulationResult) async -> LiveCaptionPipelineSnapshot {
    if result.plainTextReplacement != nil {
        reset(sourceLocale: sourceLocale, targetLocale: targetLocale)
        return snapshot(
            captionHealth: .failed("Plain text transcript replacements are not supported by live captions."),
            translationHealth: .idle
        )
    }

    let currentSegmentIDs = Set(result.document.segments.map(\.id))
    applyEvents(
        turnAssembler.removeSegments(notIn: currentSegmentIDs),
        currentSegments: result.document.segments
    )

    let changedSegmentIDs = Set(result.changedSegmentIDs)
    for segment in result.document.segments where changedSegmentIDs.contains(segment.id) {
        let receivedAt = Date()
        logSegmentIngestedIfNeeded(segment, path: segment.isFinal ? "final" : "interim")
        applyEvents(
            turnAssembler.apply(segment),
            sourceSegment: segment,
            segmentReceivedAt: receivedAt,
            visibilityPath: .realtime
        )
    }

    return snapshot(
        captionHealth: store.turns.isEmpty ? .idle : .live,
        translationHealth: currentTranslationHealth()
    )
}
```

- [ ] **Step 4: Run the focused test**

Run:

```bash
swift test --filter LiveCaptionPipelineTests/testRealtimeApplyDoesNotAwaitCaptionTranslationProvider
```

Expected: PASS.

- [ ] **Step 5: Update pipeline tests that expected `apply(_:)` to translate**

Find tests in `Tests/MeetingAgentCoreTests/LiveCaptionPipelineTests.swift` where a realtime `pipeline.apply(_:)` call expects `translatedText` or provider requests. Update those tests to explicitly call `scheduleLivePendingTranslations()` after asserting the caption-only snapshot. For example:

```swift
let captionSnapshot = await pipeline.apply(result)
XCTAssertEqual(captionSnapshot.turns.first?.originalText, "We should review the rollout plan")
XCTAssertNil(captionSnapshot.turns.first?.translatedText)

let translatedSnapshot = await pipeline.scheduleLivePendingTranslations()
XCTAssertEqual(translatedSnapshot.turns.first?.translatedText, "我们应该审查发布计划")
```

For `testApplyLogsCarriedForwardTranslationWhenDraftTextChanges`, make the first translation explicit before changing the draft:

```swift
_ = await pipeline.apply(firstResult)
_ = await pipeline.scheduleLivePendingTranslations()
_ = await pipeline.apply(secondResult)
```

- [ ] **Step 6: Run pipeline tests**

Run:

```bash
swift test --filter LiveCaptionPipelineTests
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/MeetingAgentCore/LiveCaptionPipeline.swift Tests/MeetingAgentCoreTests/LiveCaptionPipelineTests.swift
git commit -m "fix: make realtime caption apply translation-free"
```

## Task 2: Expose Live Translation Scheduling Through `RealtimeCaptionSession`

**Files:**
- Modify: `Sources/MeetingAgentCore/RealtimeCaptionSession.swift`
- Test: covered through `MeetingAgentViewModelTests` in later tasks

- [ ] **Step 1: Add a session method for live pending translations**

In `Sources/MeetingAgentCore/RealtimeCaptionSession.swift`, add:

```swift
func scheduleLivePendingTranslations() async -> LiveCaptionPipelineSnapshot {
    await pipeline.scheduleLivePendingTranslations()
}
```

The full file should keep the existing methods:

```swift
@MainActor
final class RealtimeCaptionSession {
    private var pipeline: LiveCaptionPipeline

    init(pipeline: LiveCaptionPipeline) {
        self.pipeline = pipeline
    }

    func replacePipeline(_ pipeline: LiveCaptionPipeline) {
        self.pipeline = pipeline
    }

    func apply(_ result: TranscriptSegmentAccumulationResult) async -> LiveCaptionPipelineSnapshot {
        await pipeline.apply(result)
    }

    func flushCaptionsOnly(reason: LiveCaptionFreezeReason) -> LiveCaptionPipelineSnapshot {
        pipeline.flushCaptionsOnly(reason: reason)
    }

    func schedulePendingTranslations() async -> LiveCaptionPipelineSnapshot {
        await pipeline.schedulePendingTranslations()
    }

    func scheduleLivePendingTranslations() async -> LiveCaptionPipelineSnapshot {
        await pipeline.scheduleLivePendingTranslations()
    }
}
```

- [ ] **Step 2: Build**

Run:

```bash
swift build --product MeetingAgentApp
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/MeetingAgentCore/RealtimeCaptionSession.swift
git commit -m "refactor: expose realtime translation scheduling"
```

## Task 3: Add a Background Translation Pump to `MeetingAgentViewModel`

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] **Step 1: Write the core decoupling test**

Add this test near `testEmptyDrainTicksDoNotDuplicateInFlightCaptionTranslation` in `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`:

```swift
func testSlowCaptionTranslationDoesNotBlockOriginalRealtimeCaption() async throws {
    let fixture = try ViewModelRecorderFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let provider = DelayedViewModelFakeTextTranslationProvider()
    let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
    let viewModel = MeetingAgentViewModel(
        store: fixture.store,
        recorder: fixture.recorder,
        speechConfiguration: SpeechTranscriptionConfiguration(
            provider: .whisper,
            localeIdentifier: "en-US",
            targetLocaleIdentifier: "zh-CN",
            whisperBinaryPath: nil,
            whisperModelPath: nil,
            transcriptionExecutionMode: .hosted,
            translationExecutionMode: .hosted,
            hostedTranscriptionProviderID: "deepgram-transcribe",
            hostedTranslationProviderID: "openrouter-translation",
            hostedTranslationModelID: "google/gemini-2.5-flash",
            openRouterAPIKey: "settings-openrouter-key",
            deepgramAPIKey: "settings-deepgram-key"
        ),
        captionTranslationProviderFactory: { _ in provider },
        liveCaptionSnapshotDebounceNanoseconds: 0,
        processTargetsProvider: { [target] }
    )
    try await viewModel.startRecording(for: target)

    fixture.transcriber.emit(.upsert(TranscriptSegment(
        id: "segment-1",
        speaker: TranscriptSpeaker(identifier: "speaker-1", label: "Alex"),
        text: "Alex is the launch owner.",
        language: "en-US",
        isFinal: true,
        speechFinal: true
    )))

    viewModel.drainRecordingFrames()

    try await waitFor {
        viewModel.liveCaptionTurns.first?.originalText == "Alex is the launch owner."
    }
    XCTAssertNil(viewModel.liveCaptionTurns.first?.translatedText)
    try await waitFor { provider.pendingRequestCount == 1 }

    provider.completeRequest(at: 0, targetText: "Alex 是上线负责人。")
    try await waitFor {
        viewModel.liveCaptionTurns.first?.translatedText == "Alex 是上线负责人。"
    }
}
```

- [ ] **Step 2: Run the failing test**

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testSlowCaptionTranslationDoesNotBlockOriginalRealtimeCaption
```

Expected before implementation: the original caption appears after Task 1, but the test times out waiting for `provider.pendingRequestCount == 1` because no background translation pump exists yet.

- [ ] **Step 3: Add translation pump state**

In `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`, near the active caption task properties, add:

```swift
private var activeCaptionTranslationTask: Task<Void, Never>?
private var activeCaptionTranslationGeneration = 0
```

- [ ] **Step 4: Add a realtime translation context and invalidation helper**

Near `ActiveCaptionApplyContext`, add a context that is stable across normal transcript updates for the same active meeting:

```swift
private struct ActiveCaptionTranslationContext: Equatable {
    let activeMeetingID: UUID?
    let selectedMeetingID: UUID?
}
```

Near `isCurrentActiveCaptionApply(_:)`, add:

```swift
private func currentActiveCaptionTranslationContext() -> ActiveCaptionTranslationContext {
    ActiveCaptionTranslationContext(
        activeMeetingID: activeMeetingID,
        selectedMeetingID: selectedMeetingID
    )
}

private func isCurrentActiveCaptionTranslation(_ context: ActiveCaptionTranslationContext) -> Bool {
    context.activeMeetingID == activeMeetingID
        && context.selectedMeetingID == selectedMeetingID
}
```

Near `invalidateActiveCaptionApplyTasks()`, add:

```swift
private func invalidateActiveCaptionTranslationTasks() {
    activeCaptionTranslationGeneration += 1
    activeCaptionTranslationTask?.cancel()
    activeCaptionTranslationTask = nil
}
```

- [ ] **Step 5: Invalidate translation tasks with existing caption invalidation paths**

Update `invalidateActiveCaptionApplyTasks()`:

```swift
private func invalidateActiveCaptionApplyTasks() {
    activeCaptionApplySequence += 1
    activeCaptionApplyTask?.cancel()
    activeCaptionApplyTask = nil
    invalidateActiveCaptionTranslationTasks()
    cancelPendingDraftCaptionInput(reason: "active_apply_invalidated")
}
```

Also call `invalidateActiveCaptionTranslationTasks()` anywhere the realtime pipeline is replaced or reset without going through `invalidateActiveCaptionApplyTasks()`. Specifically inspect and update these methods:

- `resetLiveCaptionPipeline()`
- `bindLiveCaptionTurnsToActiveRecording()`
- `stopRecording(at:)`
- `stopRecordingAndGenerateSummary(at:generatedAt:)`

Do not add it to selected-meeting replay translation tasks unless they use `liveCaptionReplayTask`; replay already has separate sequencing.

- [ ] **Step 6: Publish original snapshot before translation**

In `applyTranscriptAccumulationResultsToLiveCaptions(_:context:)`, replace the current body after `activeCaptionDocumentSignature` assignment with:

```swift
activeCaptionDocumentSignature = Self.captionDocumentSignature(latest.document)
let snapshot = await realtimeCaptionSession.apply(latest)
guard !Task.isCancelled, isCurrentActiveCaptionApply(context) else { return }
publishRealtimeCaptionPipelineSnapshot(snapshot)
startRealtimeCaptionTranslationPumpIfNeeded(context: currentActiveCaptionTranslationContext())
```

- [ ] **Step 7: Add the translation pump**

Add this method near the active caption apply helpers:

```swift
private func startRealtimeCaptionTranslationPumpIfNeeded(context: ActiveCaptionTranslationContext) {
    guard isCurrentActiveCaptionTranslation(context) else { return }
    guard activeCaptionTranslationTask == nil else { return }
    activeCaptionTranslationGeneration += 1
    let generation = activeCaptionTranslationGeneration
    activeCaptionTranslationTask = Task { [weak self] in
        guard let self else { return }
        await runRealtimeCaptionTranslationPump(context: context, generation: generation)
    }
}

private func runRealtimeCaptionTranslationPump(
    context: ActiveCaptionTranslationContext,
    generation: Int
) async {
    while !Task.isCancelled {
        guard generation == activeCaptionTranslationGeneration,
              isCurrentActiveCaptionTranslation(context)
        else {
            break
        }

        let snapshot = await realtimeCaptionSession.scheduleLivePendingTranslations()

        guard !Task.isCancelled,
              generation == activeCaptionTranslationGeneration,
              isCurrentActiveCaptionTranslation(context)
        else {
            break
        }

        publishRealtimeCaptionPipelineSnapshot(snapshot)

        guard snapshot.turns.contains(where: { $0.translationHealth == .pending }) else {
            break
        }

        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    if generation == activeCaptionTranslationGeneration {
        activeCaptionTranslationTask = nil
    }
}
```

This creates one active pump per active meeting/selection context. It does not cancel and restart on every transcript update, so in-flight provider calls can complete and the scheduler can apply stale checks. The pump sleeps briefly before retrying pending translations to avoid a tight loop when work is still in flight or skipped by scheduler policy.

- [ ] **Step 8: Run the focused test**

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testSlowCaptionTranslationDoesNotBlockOriginalRealtimeCaption
```

Expected: PASS.

- [ ] **Step 9: Run nearby translation tests**

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testEmptyDrainTicksDoNotDuplicateInFlightCaptionTranslation
swift test --filter MeetingAgentViewModelTests/testReopenedMeetingHydratesPersistedCaptionTranslationWithoutProviderRequest
```

Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add Sources/MeetingAgentCore/MeetingAgentViewModel.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift
git commit -m "fix: decouple realtime captions from translation overlay"
```

## Task 4: Add Stale Overlay and Stop/Switch Regression Tests

**Files:**
- Modify: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift` only if the new tests expose an overlay validation gap

- [ ] **Step 1: Write stale source revision test**

Add this test near the new decoupling test:

```swift
func testDelayedCaptionTranslationDoesNotOverwriteNewerRealtimeCaptionText() async throws {
    let fixture = try ViewModelRecorderFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let provider = DelayedViewModelFakeTextTranslationProvider()
    let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
    let viewModel = MeetingAgentViewModel(
        store: fixture.store,
        recorder: fixture.recorder,
        captionTranslationProviderFactory: { _ in provider },
        liveCaptionSnapshotDebounceNanoseconds: 0,
        draftCaptionInputThrottleNanoseconds: 0,
        processTargetsProvider: { [target] }
    )
    try await viewModel.startRecording(for: target)

    fixture.transcriber.emit(.upsert(TranscriptSegment(
        id: "segment-1",
        text: "first draft text",
        language: "en-US",
        isFinal: false
    )))
    viewModel.drainRecordingFrames()
    try await waitFor { provider.pendingRequestCount == 1 }

    fixture.transcriber.emit(.upsert(TranscriptSegment(
        id: "segment-1",
        text: "first draft text with newer words",
        language: "en-US",
        isFinal: false
    )))
    viewModel.drainRecordingFrames()
    try await waitFor {
        viewModel.liveCaptionTurns.first?.originalText == "first draft text with newer words"
    }

    provider.completeRequest(at: 0, targetText: "旧翻译")
    try await Task.sleep(nanoseconds: 50_000_000)

    XCTAssertEqual(viewModel.liveCaptionTurns.first?.originalText, "first draft text with newer words")
    XCTAssertNotEqual(viewModel.liveCaptionTurns.first?.translatedText, "旧翻译")
}
```

- [ ] **Step 2: Write stop invalidation test**

Add:

```swift
func testDelayedCaptionTranslationDoesNotPublishAfterRecordingStops() async throws {
    let fixture = try ViewModelRecorderFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let provider = DelayedViewModelFakeTextTranslationProvider()
    let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
    let viewModel = MeetingAgentViewModel(
        store: fixture.store,
        recorder: fixture.recorder,
        captionTranslationProviderFactory: { _ in provider },
        liveCaptionSnapshotDebounceNanoseconds: 0,
        processTargetsProvider: { [target] }
    )
    try await viewModel.startRecording(for: target)

    fixture.transcriber.emit(.upsert(TranscriptSegment(
        id: "segment-1",
        text: "caption before stop",
        language: "en-US",
        isFinal: false
    )))
    viewModel.drainRecordingFrames()
    try await waitFor { provider.pendingRequestCount == 1 }

    viewModel.stopRecording(at: Date(timeIntervalSince1970: 200))
    provider.completeRequest(at: 0, targetText: "停止后的翻译")
    try await Task.sleep(nanoseconds: 50_000_000)

    XCTAssertNotEqual(viewModel.liveCaptionTurns.first?.translatedText, "停止后的翻译")
}
```

- [ ] **Step 3: Write selected meeting switch invalidation test**

Add:

```swift
func testDelayedCaptionTranslationDoesNotPublishAfterSelectingAnotherMeeting() async throws {
    let fixture = try ViewModelRecorderFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let provider = DelayedViewModelFakeTextTranslationProvider()
    let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
    let viewModel = MeetingAgentViewModel(
        store: fixture.store,
        recorder: fixture.recorder,
        captionTranslationProviderFactory: { _ in provider },
        liveCaptionSnapshotDebounceNanoseconds: 0,
        processTargetsProvider: { [target] }
    )
    try await viewModel.startRecording(for: target)
    let secondMeeting = try fixture.store.createMeeting(name: "Second", startedAt: Date()).record

    fixture.transcriber.emit(.upsert(TranscriptSegment(
        id: "segment-1",
        text: "caption before switch",
        language: "en-US",
        isFinal: false
    )))
    viewModel.drainRecordingFrames()
    try await waitFor { provider.pendingRequestCount == 1 }

    viewModel.selectMeeting(secondMeeting.id)
    provider.completeRequest(at: 0, targetText: "切换后的翻译")
    try await Task.sleep(nanoseconds: 50_000_000)

    XCTAssertFalse(viewModel.liveCaptionTurns.contains { $0.translatedText == "切换后的翻译" })
}
```

- [ ] **Step 4: Run the new tests**

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testDelayedCaptionTranslationDoesNotOverwriteNewerRealtimeCaptionText
swift test --filter MeetingAgentViewModelTests/testDelayedCaptionTranslationDoesNotPublishAfterRecordingStops
swift test --filter MeetingAgentViewModelTests/testDelayedCaptionTranslationDoesNotPublishAfterSelectingAnotherMeeting
```

Expected: PASS. If a test fails because stale approximate attach accepts the translation, tighten the source text/revision validation in the ViewModel pump or the pipeline overlay entry point so old-source draft results cannot publish over a newer visible turn.

- [ ] **Step 5: Run existing delayed translation tests**

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testSupersededDraftCaptionTranslationIsCancelledBeforeCompletion
swift test --filter MeetingAgentViewModelTests/testStopRecordingPublishesDelayedFlushedFinalTranslation
```

Expected: PASS. If stop behavior conflicts, preserve the explicit flush final translation behavior while keeping normal live draft overlays invalidated after stop.

- [ ] **Step 6: Commit**

```bash
git add Sources/MeetingAgentCore/MeetingAgentViewModel.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift
git commit -m "test: cover stale realtime translation overlays"
```

## Task 5: Add Original and Translation Overlay Performance Events

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Modify: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] **Step 1: Write performance event test**

Add this test near `testCaptionTranslationPerformanceEventsShareRequestID`:

```swift
func testRealtimeCaptionAndTranslationOverlayPublishSeparatePerformanceEvents() async throws {
    let fixture = try ViewModelRecorderFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let provider = DelayedViewModelFakeTextTranslationProvider()
    let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
    let viewModel = MeetingAgentViewModel(
        store: fixture.store,
        recorder: fixture.recorder,
        captionTranslationProviderFactory: { _ in provider },
        liveCaptionSnapshotDebounceNanoseconds: 0,
        processTargetsProvider: { [target] }
    )
    try await viewModel.startRecording(for: target)
    let record = try XCTUnwrap(viewModel.selectedMeeting)

    fixture.transcriber.emit(.upsert(TranscriptSegment(
        id: "segment-1",
        text: "Caption first.",
        language: "en-US",
        isFinal: true,
        speechFinal: true
    )))
    viewModel.drainRecordingFrames()

    try await waitFor {
        ((try? readPerformanceEvents(from: XCTUnwrap(record.performanceEventsURL))) ?? [])
            .contains { $0.event == "caption_original_snapshot_published" }
    }
    provider.completeRequest(at: 0, targetText: "先显示字幕。")
    try await waitFor {
        ((try? readPerformanceEvents(from: XCTUnwrap(record.performanceEventsURL))) ?? [])
            .contains { $0.event == "caption_translation_overlay_published" }
    }

    let events = try readPerformanceEvents(from: XCTUnwrap(record.performanceEventsURL))
    XCTAssertTrue(events.contains {
        $0.event == "caption_original_snapshot_published"
            && $0.metadata["path"] == "realtime"
    })
    XCTAssertTrue(events.contains {
        $0.event == "caption_translation_overlay_published"
            && $0.metadata["path"] == "realtime"
    })
}
```

- [ ] **Step 2: Run the failing test**

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testRealtimeCaptionAndTranslationOverlayPublishSeparatePerformanceEvents
```

Expected before implementation: FAIL because the new performance events are not emitted.

- [ ] **Step 3: Add a publication event helper**

In `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`, add:

```swift
private enum CaptionSnapshotPublicationKind: String {
    case original = "caption_original_snapshot_published"
    case translationOverlay = "caption_translation_overlay_published"
}

private func logCaptionSnapshotPublication(
    _ kind: CaptionSnapshotPublicationKind,
    snapshot: LiveCaptionPipelineSnapshot,
    path: String
) {
    currentPerformanceEventLogger()?.log(
        kind.rawValue,
        metadata: [
            "path": path,
            "turnCount": String(snapshot.turns.count),
            "captionHealth": String(describing: snapshot.captionHealth),
            "translationHealth": String(describing: snapshot.translationHealth)
        ]
    )
}
```

Place the enum near other private ViewModel helper types, and the method near `publishLiveCaptionPipelineSnapshotImmediately(_:)`.

- [ ] **Step 4: Log original publication**

In `applyTranscriptAccumulationResultsToLiveCaptions(_:context:)`, after `publishRealtimeCaptionPipelineSnapshot(snapshot)`, add:

```swift
logCaptionSnapshotPublication(.original, snapshot: snapshot, path: "realtime")
```

- [ ] **Step 5: Log translation overlay publication**

In `runRealtimeCaptionTranslationPump(context:generation:)`, after publishing a snapshot returned by `scheduleLivePendingTranslations()`, add:

```swift
logCaptionSnapshotPublication(.translationOverlay, snapshot: snapshot, path: "realtime")
```

Only log when the snapshot is actually published after generation/context validation.

- [ ] **Step 6: Run the focused test**

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testRealtimeCaptionAndTranslationOverlayPublishSeparatePerformanceEvents
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/MeetingAgentCore/MeetingAgentViewModel.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift
git commit -m "feat: separate caption and translation latency events"
```

## Task 6: Full Verification

**Files:**
- No planned edits

- [ ] **Step 1: Run focused test groups**

Run:

```bash
swift test --filter LiveCaptionPipelineTests
swift test --filter CaptionTranslationSchedulerTests
swift test --filter MeetingAgentViewModelTests
```

Expected: all pass.

- [ ] **Step 2: Run required project test entrypoint**

Run:

```bash
make test
```

Expected: all tests pass and coverage gate passes.

- [ ] **Step 3: Inspect performance-sensitive diff**

Run:

```bash
git diff --stat HEAD~4..HEAD
git diff HEAD~4..HEAD -- Sources/MeetingAgentCore/LiveCaptionPipeline.swift Sources/MeetingAgentCore/RealtimeCaptionSession.swift Sources/MeetingAgentCore/MeetingAgentViewModel.swift
```

Expected: changes are limited to caption/translation decoupling, task invalidation, and telemetry.

- [ ] **Step 4: Final status**

Run:

```bash
git status --short
```

Expected: no unintended tracked changes. Existing unrelated untracked files, such as `.env`, should remain untracked and uncommitted.
