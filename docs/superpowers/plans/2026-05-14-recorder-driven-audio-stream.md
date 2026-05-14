# Recorder-Driven Audio Stream Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `MeetingRecorder` consume audio as a real async stream, emit recorder events, and remove the 250 ms UI-driven audio drain loop.

**Architecture:** `AudioFrameRingBuffer` gains async wakeup semantics while preserving realtime-safe `push(_:)`. `MeetingRecorder` starts an internal processing task after capture starts, drains audio when frames arrive, writes WAV, feeds STT, and emits `MeetingRecorderEvent` through `AsyncStream`. `MeetingAgentViewModel` listens to recorder events and keeps existing caption/progress logic, while SwiftUI receives in-memory artifact snapshots instead of reading large files in `body`.

**Tech Stack:** Swift 5.9, Swift Concurrency (`Task`, `AsyncStream`), XCTest, Swift Package Manager, existing `make test` coverage gate.

---

## File Structure

- Modify `Sources/MeetingAgentCore/AudioFrameRingBuffer.swift`
  - Add async wakeup, finish semantics, and `batches` stream while keeping `push`, `drain`, `count`, and `droppedFrameCount`.
- Modify `Tests/MeetingAgentCoreTests/AudioFrameRingBufferTests.swift`
  - Add async consumer tests for wakeup, batching, overflow, and finish.
- Modify `Sources/MeetingAgentCore/MeetingRecorder.swift`
  - Add `MeetingRecorderEvent`, `MeetingRecorderStatusSnapshot`, `MeetingRecorderFailure`, recorder event stream, internal processing task, and event emission.
  - Convert existing frame processing into a reusable method that can process an explicit frame batch.
- Modify `Tests/MeetingAgentCoreTests/MeetingRecorderTests.swift`
  - Add tests proving start processes pushed frames without external `drainFrames`, emits transcript updates, flushes on stop, and emits one stopped event.
- Modify `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
  - Replace app-facing `drainRecordingFrames()` orchestration with recorder event listening.
  - Keep existing live caption pipeline and meeting progress logic.
  - Move active target ended handling to a process-monitor command method.
- Modify `Sources/MeetingAgentApp/MeetingAgentApp.swift`
  - Remove the 250 ms drain call.
  - Keep process polling separate.
- Modify `Sources/MeetingAgentApp/MainWindowView.swift`
  - Consume selected-meeting artifact snapshots instead of reading files in view body helpers.
- Create `Sources/MeetingAgentCore/MeetingArtifactSnapshot.swift`
  - Define snapshot and loader for transcript text, summary, latency text, and knowledge segments.
- Modify `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`
  - Add source-level regression tests that the SwiftUI view does not synchronously read transcript, summary, or performance files.
- Modify `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`
  - Update tests from `drainRecordingFrames()` to event-driven recorder behavior.

---

### Task 1: Make AudioFrameRingBuffer Async-Wakeable

**Files:**
- Modify: `Sources/MeetingAgentCore/AudioFrameRingBuffer.swift`
- Modify: `Tests/MeetingAgentCoreTests/AudioFrameRingBufferTests.swift`

- [ ] **Step 1: Add failing test for async wakeup**

Append this test to `Tests/MeetingAgentCoreTests/AudioFrameRingBufferTests.swift`:

```swift
func testPushWakesAsyncBatchConsumer() async throws {
    let buffer = AudioFrameRingBuffer(capacity: 4)
    let frame = AudioFrame(pcm: Data([1]), sampleRate: 16_000, channelCount: 1, timestampNanos: 1)
    var iterator = buffer.batches.makeAsyncIterator()

    buffer.push(frame)

    let batch = await iterator.next()
    XCTAssertEqual(batch, [frame])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
swift test --filter AudioFrameRingBufferTests/testPushWakesAsyncBatchConsumer
```

Expected: FAIL to compile because `AudioFrameRingBuffer` has no `batches` property.

- [ ] **Step 3: Add failing tests for batching, overflow, and finish**

Append these tests to `Tests/MeetingAgentCoreTests/AudioFrameRingBufferTests.swift`:

```swift
func testAsyncBatchConsumerDrainsAllAvailableFramesTogether() async throws {
    let buffer = AudioFrameRingBuffer(capacity: 4)
    let first = AudioFrame(pcm: Data([1]), sampleRate: 16_000, channelCount: 1, timestampNanos: 1)
    let second = AudioFrame(pcm: Data([2]), sampleRate: 16_000, channelCount: 1, timestampNanos: 2)
    var iterator = buffer.batches.makeAsyncIterator()

    buffer.push(first)
    buffer.push(second)

    let batch = await iterator.next()
    XCTAssertEqual(batch, [first, second])
    XCTAssertEqual(buffer.count, 0)
}

func testAsyncBatchConsumerReceivesNewestFramesAfterOverflow() async throws {
    let buffer = AudioFrameRingBuffer(capacity: 2)
    let first = AudioFrame(pcm: Data([1]), sampleRate: 16_000, channelCount: 1, timestampNanos: 1)
    let second = AudioFrame(pcm: Data([2]), sampleRate: 16_000, channelCount: 1, timestampNanos: 2)
    let third = AudioFrame(pcm: Data([3]), sampleRate: 16_000, channelCount: 1, timestampNanos: 3)
    var iterator = buffer.batches.makeAsyncIterator()

    buffer.push(first)
    buffer.push(second)
    buffer.push(third)

    let batch = await iterator.next()
    XCTAssertEqual(batch, [second, third])
    XCTAssertEqual(buffer.droppedFrameCount, 1)
}

func testFinishEndsAsyncBatchConsumer() async throws {
    let buffer = AudioFrameRingBuffer(capacity: 2)
    var iterator = buffer.batches.makeAsyncIterator()

    buffer.finish()

    let batch = await iterator.next()
    XCTAssertNil(batch)
}
```

- [ ] **Step 4: Implement async wakeup in AudioFrameRingBuffer**

Replace `Sources/MeetingAgentCore/AudioFrameRingBuffer.swift` with:

```swift
import Foundation

public final class AudioFrameRingBuffer {
    private let lock = NSLock()
    private let capacity: Int
    private var frames: [AudioFrame] = []
    private var droppedFrames = 0
    private var continuations: [UUID: AsyncStream<[AudioFrame]>.Continuation] = [:]
    private var isFinished = false

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    public func push(_ frame: AudioFrame) {
        let continuationsToNotify: [AsyncStream<[AudioFrame]>.Continuation]
        lock.lock()
        if isFinished {
            lock.unlock()
            return
        }
        frames.append(frame)
        if frames.count > capacity {
            let overflow = frames.count - capacity
            frames.removeFirst(overflow)
            droppedFrames += overflow
        }
        continuationsToNotify = Array(continuations.values)
        lock.unlock()

        for continuation in continuationsToNotify {
            yieldAvailableFrames(to: continuation)
        }
    }

    public func drain() -> [AudioFrame] {
        lock.lock()
        defer { lock.unlock() }

        let drained = frames
        frames.removeAll(keepingCapacity: true)
        return drained
    }

    public func finish() {
        let continuationsToFinish: [AsyncStream<[AudioFrame]>.Continuation]
        lock.lock()
        isFinished = true
        continuationsToFinish = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()

        for continuation in continuationsToFinish {
            yieldAvailableFrames(to: continuation)
            continuation.finish()
        }
    }

    public var batches: AsyncStream<[AudioFrame]> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            if isFinished {
                lock.unlock()
                yieldAvailableFrames(to: continuation)
                continuation.finish()
                return
            }
            continuations[id] = continuation
            lock.unlock()

            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(id)
            }
            yieldAvailableFrames(to: continuation)
        }
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }

        return frames.count
    }

    public var droppedFrameCount: Int {
        lock.lock()
        defer { lock.unlock() }

        return droppedFrames
    }

    private func removeContinuation(_ id: UUID) {
        lock.lock()
        continuations.removeValue(forKey: id)
        lock.unlock()
    }

    private func yieldAvailableFrames(to continuation: AsyncStream<[AudioFrame]>.Continuation) {
        let drained = drain()
        guard !drained.isEmpty else { return }
        continuation.yield(drained)
    }
}
```

- [ ] **Step 5: Run audio buffer tests**

Run:

```bash
swift test --filter AudioFrameRingBufferTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/MeetingAgentCore/AudioFrameRingBuffer.swift Tests/MeetingAgentCoreTests/AudioFrameRingBufferTests.swift
git commit -m "feat: make audio frame buffer async wakeable"
```

---

### Task 2: Make MeetingRecorder Self-Running And Event-Emitting

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingRecorder.swift`
- Modify: `Tests/MeetingAgentCoreTests/MeetingRecorderTests.swift`

- [ ] **Step 1: Add failing recorder event test**

Append this test to `Tests/MeetingAgentCoreTests/MeetingRecorderTests.swift`:

```swift
func testRecorderProcessesPushedFramesWithoutExternalDrain() async throws {
    let fixture = try RecorderFixture()
    let frame = AudioFrame(pcm: Data([64, 0, 65, 0]), sampleRate: 16_000, channelCount: 1, timestampNanos: 9)
    let record = try fixture.recorder.prepareRecord(for: fixture.target, startedAt: Date(timeIntervalSince1970: 100))
    var iterator = fixture.recorder.events.makeAsyncIterator()

    try await fixture.recorder.startRecording(
        target: fixture.target,
        record: record,
        speechProvider: .local,
        localeIdentifier: "zh-CN"
    )
    fixture.session.frameBuffer.push(frame)
    try await waitFor {
        fixture.writer.writtenFrames == [frame] && fixture.transcriber.appendedFrames == [frame]
    }

    var startedEvent: MeetingRecorderEvent?
    for _ in 0..<4 {
        let event = await iterator.next()
        if case .started = event {
            startedEvent = event
            break
        }
    }
    XCTAssertEqual(startedEvent, .started(record.withTranscription(localeIdentifier: "zh-CN", providerID: "local")))
}
```

Before running, add this helper near the bottom of `MeetingRecorderTests.swift`:

```swift
private extension MeetingRecord {
    func withTranscription(localeIdentifier: String, providerID: String) -> MeetingRecord {
        var copy = self
        copy.speechLocaleIdentifier = localeIdentifier
        copy.transcriptionStatus = .transcribing
        copy.transcriptionFailureReason = nil
        copy.transcriptionProviderID = providerID
        return copy
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
swift test --filter MeetingRecorderTests/testRecorderProcessesPushedFramesWithoutExternalDrain
```

Expected: FAIL to compile because `MeetingRecorder` has no `events` property and `MeetingRecorderEvent` is undefined.

- [ ] **Step 3: Add recorder event types**

Add these public types near the top of `Sources/MeetingAgentCore/MeetingRecorder.swift`, after `MeetingRecorderState`:

```swift
public struct MeetingRecorderStatusSnapshot: Equatable {
    public let meetingID: UUID
    public let status: CaptureStatus
    public let sourceDisplayName: String

    public init(meetingID: UUID, status: CaptureStatus, sourceDisplayName: String) {
        self.meetingID = meetingID
        self.status = status
        self.sourceDisplayName = sourceDisplayName
    }
}

public struct MeetingRecorderFailure: Error, Equatable, CustomStringConvertible {
    public let meetingID: UUID?
    public let message: String

    public init(meetingID: UUID?, message: String) {
        self.meetingID = meetingID
        self.message = message
    }

    public var description: String { message }
}

public enum MeetingRecorderEvent: Equatable {
    case prepared(MeetingRecord)
    case started(MeetingRecord)
    case captureStatusChanged(MeetingRecorderStatusSnapshot)
    case transcriptUpdates([TranscriptSegmentAccumulationResult])
    case stopped(MeetingRecord, reason: CaptureEndedReason)
    case failed(MeetingRecorderFailure)
}
```

- [ ] **Step 4: Add event stream storage to MeetingRecorder**

Add these properties inside `MeetingRecorder`:

```swift
private let eventStream: AsyncStream<MeetingRecorderEvent>
private let eventContinuation: AsyncStream<MeetingRecorderEvent>.Continuation
private var processingTask: Task<Void, Never>?
private var lastPublishedCaptureStatus: CaptureStatus?
private var activeSource: AudioCaptureSource?

public var events: AsyncStream<MeetingRecorderEvent> {
    eventStream
}
```

Then add this initialization code to the designated `init(...)` before existing stored properties are assigned:

```swift
var continuation: AsyncStream<MeetingRecorderEvent>.Continuation!
self.eventStream = AsyncStream { streamContinuation in
    continuation = streamContinuation
}
self.eventContinuation = continuation
```

Keep the existing property assignments after this block.

- [ ] **Step 5: Emit prepared and started events**

In both `prepareRecord` methods, after `state = .prepared(...)`, add:

```swift
eventContinuation.yield(.prepared(stored.record))
```

For the overload that prepares an existing record, use:

```swift
eventContinuation.yield(.prepared(record))
```

In `startRecording(source:record:...)`, set the source before `state = .recording(record.id)`:

```swift
activeSource = source
```

After `performanceEventLogger?.log("recording_started")`, add:

```swift
eventContinuation.yield(.started(updatedRecord))
startProcessingCapturedAudio()
publishCaptureStatusIfChanged()
```

- [ ] **Step 6: Extract frame batch processing**

Replace `drainFrames()` body with:

```swift
public func drainFrames() throws {
    guard let session = captureSession else { return }
    let bufferBacklog = session.frameBuffer.count
    let droppedFrameCount = session.frameBuffer.droppedFrameCount
    let frames = session.frameBuffer.drain()
    try process(frames: frames, bufferBacklog: bufferBacklog, droppedFrameCount: droppedFrameCount)
}
```

Add this private method below `drainFrames()`:

```swift
private func process(
    frames: [AudioFrame],
    bufferBacklog: Int,
    droppedFrameCount: Int
) throws {
    if let first = frames.first, let last = frames.last {
        performanceEventLogger?.log(
            "audio_frames_drained",
            audioTimeSeconds: TimeInterval(last.timestampNanos) / 1_000_000_000,
            metadata: [
                "frameCount": String(frames.count),
                "firstFrameTimestampNanos": String(first.timestampNanos),
                "lastFrameTimestampNanos": String(last.timestampNanos),
                "bufferBacklog": String(bufferBacklog),
                "droppedFrameCount": String(droppedFrameCount)
            ]
        )
    }
    diagnosticsTracker?.record(
        frames: frames,
        bufferBacklog: bufferBacklog,
        droppedFrameCount: droppedFrameCount
    )
    speakerAudioEvidenceStore.append(frames)
    for frame in frames {
        try writer?.append(frame)
        if transcriber != nil {
            try appendFrameToTranscriber(frame)
        } else if isStartingTranscriber {
            bufferPendingTranscriptionFrame(frame)
        }
    }
}
```

- [ ] **Step 7: Add internal processing task**

Add this private method to `MeetingRecorder`:

```swift
private func startProcessingCapturedAudio() {
    processingTask?.cancel()
    guard let session = captureSession else { return }
    processingTask = Task { [weak self, session] in
        for await frames in session.frameBuffer.batches {
            guard !Task.isCancelled else { return }
            await self?.processCapturedBatch(frames, session: session)
        }
    }
}
```

Add this `@MainActor`-free helper as a regular private method:

```swift
private func processCapturedBatch(_ frames: [AudioFrame], session: AudioCaptureSessionManaging) async {
    do {
        try process(
            frames: frames,
            bufferBacklog: session.frameBuffer.count,
            droppedFrameCount: session.frameBuffer.droppedFrameCount
        )
        publishTranscriptUpdatesIfNeeded()
        publishCaptureStatusIfChanged()
    } catch {
        let failure = MeetingRecorderFailure(
            meetingID: activeRecord?.id,
            message: "Recording processing failed: \(error)"
        )
        eventContinuation.yield(.failed(failure))
    }
}
```

Add these private event helpers:

```swift
private func publishTranscriptUpdatesIfNeeded() {
    let updates = drainTranscriptUpdates()
    guard !updates.isEmpty else { return }
    eventContinuation.yield(.transcriptUpdates(updates))
}

private func publishCaptureStatusIfChanged() {
    guard let record = activeRecord,
          let status = currentCaptureStatus,
          status != lastPublishedCaptureStatus
    else {
        return
    }
    lastPublishedCaptureStatus = status
    eventContinuation.yield(.captureStatusChanged(MeetingRecorderStatusSnapshot(
        meetingID: record.id,
        status: status,
        sourceDisplayName: activeSource?.displayName ?? record.name
    )))
}
```

- [ ] **Step 8: Finish processing task on stop**

At the start of `stopRecording(at:endedReason:)`, before closing writer, add:

```swift
captureSession?.frameBuffer.finish()
processingTask?.cancel()
processingTask = nil
try drainFrames()
publishTranscriptUpdatesIfNeeded()
```

After `let stopped = try markStopped(...)`, emit stopped:

```swift
let stopped = try markStopped(at: endedAt, endedReason: endedReason)
if let stopped {
    eventContinuation.yield(.stopped(stopped, reason: endedReason))
}
return stopped
```

Replace the existing direct `return try markStopped(...)` with the code above.

In `markStopped`, before `state = .idle`, add:

```swift
activeSource = nil
lastPublishedCaptureStatus = nil
```

- [ ] **Step 9: Run recorder test**

Run:

```bash
swift test --filter MeetingRecorderTests/testRecorderProcessesPushedFramesWithoutExternalDrain
```

Expected: PASS.

- [ ] **Step 10: Add transcript event test**

Append this test to `MeetingRecorderTests.swift`:

```swift
func testRecorderEmitsTranscriptUpdatesFromTranscriberWithoutViewModelDrain() async throws {
    let fixture = try RecorderFixture()
    let record = try fixture.recorder.prepareRecord(for: fixture.target, startedAt: Date(timeIntervalSince1970: 100))
    var iterator = fixture.recorder.events.makeAsyncIterator()

    try await fixture.recorder.startRecording(target: fixture.target, record: record)
    fixture.transcriber.emit(.upsert(TranscriptSegment(
        id: "segment-1",
        startTimeSeconds: 0,
        endTimeSeconds: 1,
        text: "hello",
        language: "en-US",
        isFinal: true
    )))
    fixture.session.frameBuffer.push(AudioFrame(pcm: Data([64, 0]), sampleRate: 16_000, channelCount: 1, timestampNanos: 1))

    var transcriptEvent: MeetingRecorderEvent?
    for _ in 0..<5 {
        let event = await iterator.next()
        if case .transcriptUpdates = event {
            transcriptEvent = event
            break
        }
    }

    guard case .transcriptUpdates(let updates) = transcriptEvent else {
        return XCTFail("Expected transcript update event")
    }
    XCTAssertEqual(updates.last?.document.segments.map(\.text), ["hello"])
}
```

The current `RecorderFixture` fake transcriber already has `emit(_:)`. If a worker is applying this plan after that helper was renamed, restore this exact method on the fake transcriber:

```swift
func emit(_ update: TranscriptSegmentUpdate) {
    transcriptUpdateSink?.receive(update)
}
```

- [ ] **Step 11: Run focused recorder tests**

Run:

```bash
swift test --filter MeetingRecorderTests
```

Expected: PASS. Existing tests that manually call `drainFrames()` continue to pass because compatibility remains.

- [ ] **Step 12: Commit**

```bash
git add Sources/MeetingAgentCore/MeetingRecorder.swift Tests/MeetingAgentCoreTests/MeetingRecorderTests.swift
git commit -m "feat: make meeting recorder emit stream events"
```

---

### Task 3: Move ViewModel From Drain Driver To Recorder Event Listener

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Modify: `Sources/MeetingAgentApp/MeetingAgentApp.swift`
- Modify: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`
- Modify: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

- [ ] **Step 1: Add source-level failing test that app no longer drains recorder**

Append to `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`:

```swift
func testAppTaskDoesNotDriveRecorderDrainLoop() throws {
    let source = try appSource(named: "MeetingAgentApp.swift")

    XCTAssertFalse(source.contains("drainRecordingFrames"))
    XCTAssertFalse(source.contains("250_000_000"))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
swift test --filter MainWindowViewLayoutTests/testAppTaskDoesNotDriveRecorderDrainLoop
```

Expected: FAIL because `MeetingAgentApp.swift` still contains `viewModel.drainRecordingFrames()` and `250_000_000`.

- [ ] **Step 3: Add recorder event listener to ViewModel**

Add this property to `MeetingAgentViewModel`:

```swift
private var recorderEventTask: Task<Void, Never>?
```

In `init(...)`, after `refreshPrimaryChainPreflightResult()`, add:

```swift
startRecorderEventListener()
```

Add this method:

```swift
private func startRecorderEventListener() {
    recorderEventTask?.cancel()
    recorderEventTask = Task { [weak self] in
        guard let self else { return }
        for await event in recorder.events {
            await handleRecorderEvent(event)
        }
    }
}
```

Add this method:

```swift
private func handleRecorderEvent(_ event: MeetingRecorderEvent) async {
    switch event {
    case .prepared(let record), .started(let record):
        upsertMeeting(record)
    case .captureStatusChanged(let snapshot):
        applyCaptureStatus(snapshot)
    case .transcriptUpdates(let results):
        applyRecorderTranscriptUpdates(results)
    case .stopped(let record, _):
        applyStoppedRecord(record)
    case .failed(let failure):
        statusText = "Recording failed: \(failure.message)"
    }
}
```

Add these helper methods:

```swift
private func upsertMeeting(_ record: MeetingRecord) {
    if let index = meetings.firstIndex(where: { $0.id == record.id }) {
        meetings[index] = record
    } else {
        meetings.insert(record, at: 0)
    }
}

private func applyCaptureStatus(_ snapshot: MeetingRecorderStatusSnapshot) {
    switch snapshot.status {
    case .preparingCapture:
        statusText = "Preparing capture for \(snapshot.sourceDisplayName)"
    case .recording:
        statusText = "Recording \(snapshot.sourceDisplayName)"
    case .recordingNoAudioDetected:
        statusText = "Recording \(snapshot.sourceDisplayName), but no audio detected"
    case .recordingSilentAudio:
        statusText = "Recording silent audio from \(snapshot.sourceDisplayName)"
    case .targetProcessEnded:
        statusText = "Target process ended: \(snapshot.sourceDisplayName)"
    case .captureFailed:
        statusText = "Capture failed: \(snapshot.sourceDisplayName)"
    case .recordingSaved:
        statusText = "Recording saved: \(snapshot.sourceDisplayName)"
    }
}

private func applyStoppedRecord(_ record: MeetingRecord) {
    upsertMeeting(record)
    recentlyStoppedLiveMeetingID = record.id
    invalidateActiveCaptionApplyTasks(cancelTranslationExperience: false)
    flushLiveCaptionPipeline(reason: .manualStop)
    stopRealtimeSpeakerIdentificationRuntime()
    allowActiveTargetReprompt()
    activeSource = nil
    activeMeetingID = nil
    statusText = "Idle"
}

private func applyRecorderTranscriptUpdates(_ transcriptResults: [TranscriptSegmentAccumulationResult]) {
    guard !transcriptResults.isEmpty else { return }
    let currentContext = currentActiveCaptionApplyContext()
    if shouldThrottleDraftCaptionInput(transcriptResults, context: currentContext) {
        submitDraftCaptionInput(transcriptResults, context: currentContext)
    } else {
        let context = beginActiveCaptionApply()
        activeCaptionApplyTask?.cancel()
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

- [ ] **Step 4: Simplify stop methods to command recorder**

Replace `stopRecording(at:)` with:

```swift
public func stopRecording(at endedAt: Date = Date()) {
    _ = try? recorder.stopRecording(at: endedAt)
}
```

Replace the stop section at the start of `stopRecordingAndGenerateSummary(at:generatedAt:)` with:

```swift
let stopped = try recorder.stopRecording(at: endedAt)
guard let stoppedID = stopped?.id else {
    statusText = "Idle"
    return
}
applyStoppedRecord(stopped!)
```

Keep the existing `try await generateSummary(for: stoppedID, generatedAt: generatedAt)` after the guard.

- [ ] **Step 5: Remove app-facing drain loop**

In `Sources/MeetingAgentApp/MeetingAgentApp.swift`, replace:

```swift
viewModel.drainRecordingFrames()
try? await Task.sleep(nanoseconds: 250_000_000)
```

with:

```swift
try? await Task.sleep(nanoseconds: 1_000_000_000)
```

The 1-second sleep is only for process polling loop cadence; process candidate notification still gates actual polling at 3 seconds.

- [ ] **Step 6: Remove or quarantine drainRecordingFrames**

Rename `drainRecordingFrames(endedAt:)` to an internal test helper so it is no longer app-facing:

```swift
func drainRecordingFramesForTesting(endedAt: Date = Date()) {
    try? recorder.drainFrames()
    let transcriptResults = recorder.drainTranscriptUpdates()
    applyRecorderTranscriptUpdates(transcriptResults)
}
```

Update tests that still need manual compatibility to call `drainRecordingFramesForTesting()`.

- [ ] **Step 7: Run app source test**

Run:

```bash
swift test --filter MainWindowViewLayoutTests/testAppTaskDoesNotDriveRecorderDrainLoop
```

Expected: PASS.

- [ ] **Step 8: Run ViewModel tests and update names**

Run:

```bash
swift test --filter MeetingAgentViewModelTests
```

Expected: Some tests fail where they call `drainRecordingFrames()`. Replace those calls with either:

```swift
viewModel.drainRecordingFramesForTesting()
```

for tests intentionally exercising old drain compatibility, or with recorder event waits:

```swift
try await waitFor {
    !viewModel.liveCaptionTurns.isEmpty
}
```

Expected after replacements: PASS.

- [ ] **Step 9: Commit**

```bash
git add Sources/MeetingAgentCore/MeetingAgentViewModel.swift Sources/MeetingAgentApp/MeetingAgentApp.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift
git commit -m "refactor: let view model consume recorder events"
```

---

### Task 4: Move Process-Ended Stop Out Of Audio Drain

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Modify: `Sources/MeetingAgentApp/MeetingAgentApp.swift`
- Modify: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] **Step 1: Add failing test for process-ended command path**

Append to `MeetingAgentViewModelTests.swift`:

```swift
func testProcessPollStopsActiveProcessRecordingWithoutDrainLoop() async throws {
    let fixture = try ViewModelRecorderFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    var targets = [
        AudioCaptureTarget(
            processID: 10,
            displayName: "zoom.us",
            bundleIdentifier: "us.zoom.xos",
            isAudioOutputActive: true
        )
    ]
    let viewModel = MeetingAgentViewModel(
        store: fixture.store,
        recorder: fixture.recorder,
        processTargetsProvider: { targets }
    )

    XCTAssertEqual(viewModel.pollForMeetingCandidates(), targets[0])
    try await viewModel.startRecordingForPendingCandidate()

    targets = []
    viewModel.pollForActiveRecordingProcessEnd(endedAt: Date(timeIntervalSince1970: 200))

    try await waitFor {
        viewModel.isRecording == false
    }
    let stopped = try XCTUnwrap(viewModel.meetings.first)
    XCTAssertEqual(stopped.endedAt, Date(timeIntervalSince1970: 200))
    let data = try Data(contentsOf: XCTUnwrap(stopped.diagnosticsURL))
    let diagnostics = try JSONDecoder.meetingAgent.decode(CaptureDiagnostics.self, from: data)
    XCTAssertEqual(diagnostics.endedReason, .targetProcessEnded)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testProcessPollStopsActiveProcessRecordingWithoutDrainLoop
```

Expected: FAIL to compile because `pollForActiveRecordingProcessEnd` does not exist.

- [ ] **Step 3: Implement explicit process-ended polling method**

Add to `MeetingAgentViewModel`:

```swift
public func pollForActiveRecordingProcessEnd(endedAt: Date = Date()) {
    guard let activeSource, case .process(let activeTarget) = activeSource else { return }
    let targets = processTargetsProvider()
    processMonitor.reconcileRunningProcessIDs(Set(targets.map(\.processID)))
    guard processMonitor.hasProcessEnded(processID: activeTarget.processID, in: targets) else {
        return
    }
    if let stopped = try? recorder.stopRecording(at: endedAt, endedReason: .targetProcessEnded) {
        applyStoppedRecord(stopped)
        statusText = "Target process ended: \(activeTarget.displayName)"
    }
}
```

Remove `stopRecordingIfTargetProcessEnded(at:)` from the old drain path if it is now unused.

- [ ] **Step 4: Call process-ended polling from app loop**

In `MeetingAgentApp.swift`, inside the `.task` loop after candidate polling, add:

```swift
viewModel.pollForActiveRecordingProcessEnd()
```

Keep the loop sleep at 1 second from Task 3.

- [ ] **Step 5: Run focused process-ended tests**

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testProcessPollStopsActiveProcessRecordingWithoutDrainLoop
swift test --filter MeetingAgentViewModelTests/testProcessEndedPollingDoesNotStopMicrophoneRecording
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/MeetingAgentCore/MeetingAgentViewModel.swift Sources/MeetingAgentApp/MeetingAgentApp.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift
git commit -m "refactor: stop ended process recordings outside audio drain"
```

---

### Task 5: Move Detail Artifact File Reads Out Of SwiftUI Body

**Files:**
- Create: `Sources/MeetingAgentCore/MeetingArtifactSnapshot.swift`
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift`
- Modify: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`
- Add or modify: `Tests/MeetingAgentCoreTests/MeetingArtifactSnapshotTests.swift`

- [ ] **Step 1: Add source-level failing test for body-time file reads**

Append to `MainWindowViewLayoutTests.swift`:

```swift
func testMeetingWorkspaceDoesNotReadArtifactsFromViewBody() throws {
    let source = try appSource(named: "MainWindowView.swift")

    XCTAssertFalse(source.contains("TranscriptFileWriter.readDocument"))
    XCTAssertFalse(source.contains("TranscriptFileWriter.renderedTranscript"))
    XCTAssertFalse(source.contains("MeetingSummaryWriter.read"))
    XCTAssertFalse(source.contains("String(contentsOf: url"))
    XCTAssertFalse(source.contains("PerformanceEvent.self"))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
swift test --filter MainWindowViewLayoutTests/testMeetingWorkspaceDoesNotReadArtifactsFromViewBody
```

Expected: FAIL because `MainWindowView.swift` currently reads transcript, summary, and performance files.

- [ ] **Step 3: Create MeetingArtifactSnapshot**

Create `Sources/MeetingAgentCore/MeetingArtifactSnapshot.swift`:

```swift
import Foundation

public struct MeetingArtifactSnapshot: Equatable {
    public let meetingID: UUID
    public let transcriptText: String
    public let summary: MeetingSummary?
    public let transcriptLatencyText: String
    public let knowledgeSegments: [TranscriptSegment]
    public let actualTranscriptionSourceText: String

    public init(
        meetingID: UUID,
        transcriptText: String,
        summary: MeetingSummary?,
        transcriptLatencyText: String,
        knowledgeSegments: [TranscriptSegment],
        actualTranscriptionSourceText: String
    ) {
        self.meetingID = meetingID
        self.transcriptText = transcriptText
        self.summary = summary
        self.transcriptLatencyText = transcriptLatencyText
        self.knowledgeSegments = knowledgeSegments
        self.actualTranscriptionSourceText = actualTranscriptionSourceText
    }
}

public struct MeetingArtifactFileSignature: Equatable {
    public let transcriptPath: String?
    public let transcriptModifiedAt: TimeInterval?
    public let transcriptSize: UInt64?
    public let summaryPath: String?
    public let summaryModifiedAt: TimeInterval?
    public let summarySize: UInt64?
    public let performancePath: String?
    public let performanceModifiedAt: TimeInterval?
    public let performanceSize: UInt64?
}

public struct MeetingArtifactSnapshotLoader {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func signature(for meeting: MeetingRecord) -> MeetingArtifactFileSignature {
        MeetingArtifactFileSignature(
            transcriptPath: meeting.transcriptJSONURL?.path,
            transcriptModifiedAt: modifiedAt(meeting.transcriptJSONURL),
            transcriptSize: size(meeting.transcriptJSONURL),
            summaryPath: meeting.summaryJSONURL?.path,
            summaryModifiedAt: modifiedAt(meeting.summaryJSONURL),
            summarySize: size(meeting.summaryJSONURL),
            performancePath: meeting.performanceEventsURL?.path,
            performanceModifiedAt: modifiedAt(meeting.performanceEventsURL),
            performanceSize: size(meeting.performanceEventsURL)
        )
    }

    public func load(for meeting: MeetingRecord) -> MeetingArtifactSnapshot {
        let document = meeting.transcriptJSONURL.flatMap { try? TranscriptFileWriter.readDocument(from: $0) }
        let transcriptText = TranscriptFileWriter.renderedTranscript(
            textURL: meeting.transcriptURL,
            structuredURL: meeting.transcriptJSONURL
        ) ?? "Transcript will appear here while recording."
        let summary = meeting.summaryJSONURL.flatMap { try? MeetingSummaryWriter.read(from: $0) }
        let providers = Array(Set((document?.segments ?? []).map(\.sourceProvider))).sorted()
        return MeetingArtifactSnapshot(
            meetingID: meeting.id,
            transcriptText: transcriptText,
            summary: summary,
            transcriptLatencyText: transcriptLatencyText(for: meeting),
            knowledgeSegments: document?.segments ?? [],
            actualTranscriptionSourceText: providers.isEmpty ? meeting.transcriptionProviderID : providers.joined(separator: ", ")
        )
    }

    private func modifiedAt(_ url: URL?) -> TimeInterval? {
        guard let url,
              let date = try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        else {
            return nil
        }
        return date.timeIntervalSince1970
    }

    private func size(_ url: URL?) -> UInt64? {
        guard let url,
              let value = try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        else {
            return nil
        }
        return value.uint64Value
    }

    private func transcriptLatencyText(for meeting: MeetingRecord) -> String {
        guard let event = performanceEvents(for: meeting).last(where: { $0.event == "transcript_segment_written" && $0.audioTimeSeconds != nil })
                ?? performanceEvents(for: meeting).last(where: { $0.event == "stt_segment_received" && $0.audioTimeSeconds != nil }),
              let audioTimeSeconds = event.audioTimeSeconds
        else {
            return "unavailable"
        }
        let expectedWallTime = meeting.startedAt.addingTimeInterval(audioTimeSeconds)
        let latency = max(0, event.wallTime.timeIntervalSince(expectedWallTime))
        if latency < 1 {
            return "\(Int((latency * 1_000).rounded())) ms"
        }
        return String(format: "%.1f s", latency)
    }

    private func performanceEvents(for meeting: MeetingRecord) -> [PerformanceEvent] {
        guard let url = meeting.performanceEventsURL,
              let content = try? String(contentsOf: url, encoding: .utf8)
        else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return content
            .split(whereSeparator: \.isNewline)
            .compactMap { line in try? decoder.decode(PerformanceEvent.self, from: Data(line.utf8)) }
    }
}
```

- [ ] **Step 4: Add loader cache to ViewModel**

Add properties:

```swift
@Published public private(set) var selectedMeetingArtifacts: MeetingArtifactSnapshot?
private let artifactSnapshotLoader = MeetingArtifactSnapshotLoader()
private var selectedMeetingArtifactSignature: MeetingArtifactFileSignature?
```

Add method:

```swift
private func refreshSelectedMeetingArtifactsIfNeeded() {
    guard let meeting = selectedMeeting else {
        selectedMeetingArtifacts = nil
        selectedMeetingArtifactSignature = nil
        return
    }
    let signature = artifactSnapshotLoader.signature(for: meeting)
    guard selectedMeetingArtifacts?.meetingID != meeting.id || selectedMeetingArtifactSignature != signature else {
        return
    }
    selectedMeetingArtifactSignature = signature
    selectedMeetingArtifacts = artifactSnapshotLoader.load(for: meeting)
}
```

Call `refreshSelectedMeetingArtifactsIfNeeded()` after `loadMeetings()`, `selectMeeting(_:)`, `applyStoppedRecord(_:)`, `generateSummary(for:)`, `updateSpeakerLabel`, `updateTranscriptSegmentText`, and `retryTranscription`.

- [ ] **Step 5: Pass snapshot into detail view**

In `MainWindowView`, pass:

```swift
artifacts: viewModel.selectedMeetingArtifacts
```

to `MeetingDetailView`.

Add `let artifacts: MeetingArtifactSnapshot?` to `MeetingDetailView` and `MeetingCommandCenterView`.

Replace calls:

```swift
actualTranscriptionSourceText: actualTranscriptionSourceText(for: meeting)
transcriptText: transcriptText(for: meeting)
summary: summary(for: meeting)
```

with:

```swift
actualTranscriptionSourceText: artifacts?.actualTranscriptionSourceText ?? meeting.transcriptionProviderID
transcriptText: artifacts?.transcriptText ?? "Transcript will appear here while recording."
summary: artifacts?.summary
```

Remove the helper methods `actualTranscriptionSourceText(for:)`, `transcriptText(for:)`, and `summary(for:)` from `MeetingDetailView`.

- [ ] **Step 6: Replace PipelineLatencySummary and knowledge file reads**

Pass `transcriptLatencyText: artifacts?.transcriptLatencyText ?? "unavailable"` into `TranscriptPaneView`.

Remove `PipelineLatencySummary` from `MainWindowView.swift`.

Add `knowledgeSegments: artifacts?.knowledgeSegments ?? []` to `InsightPaneView`, and replace:

```swift
MeetingKnowledgeExtractor.fromSummary(summary, segments: transcriptSegments)
```

with:

```swift
MeetingKnowledgeExtractor.fromSummary(summary, segments: knowledgeSegments)
```

Remove `transcriptSegments` from `InsightPaneView`.

- [ ] **Step 7: Run UI source test**

Run:

```bash
swift test --filter MainWindowViewLayoutTests/testMeetingWorkspaceDoesNotReadArtifactsFromViewBody
```

Expected: PASS.

- [ ] **Step 8: Run ViewModel and layout tests**

Run:

```bash
swift test --filter MeetingAgentViewModelTests
swift test --filter MainWindowViewLayoutTests
```

Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add Sources/MeetingAgentCore/MeetingArtifactSnapshot.swift Sources/MeetingAgentCore/MeetingAgentViewModel.swift Sources/MeetingAgentApp/MainWindowView.swift Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift
git commit -m "refactor: load meeting artifacts outside SwiftUI body"
```

---

### Task 6: Final Verification And Cleanup

**Files:**
- Modify only files left with obsolete drain APIs or stale tests.

- [ ] **Step 1: Search for forbidden app-path drain usage**

Run:

```bash
rg -n "drainRecordingFrames\\(|250_000_000|TranscriptFileWriter\\.readDocument|TranscriptFileWriter\\.renderedTranscript|MeetingSummaryWriter\\.read|String\\(contentsOf: url|PerformanceEvent\\.self" Sources/MeetingAgentApp Sources/MeetingAgentCore/MeetingAgentViewModel.swift Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift
```

Expected allowed matches:

- `drainRecordingFramesForTesting` may appear only in tests and as an internal test helper.
- artifact file readers may appear in `MeetingArtifactSnapshot.swift`, not in `MainWindowView.swift`.
- `PerformanceEvent.self` may appear in `MeetingArtifactSnapshot.swift`, not in `MainWindowView.swift`.

- [ ] **Step 2: Remove obsolete helper after tests are migrated**

Delete `drainRecordingFramesForTesting` from `MeetingAgentViewModel.swift` after all tests that used it have been migrated to recorder events.

Run:

```bash
rg -n "drainRecordingFramesForTesting" Sources Tests
```

Expected after deletion: no matches.

- [ ] **Step 3: Run full test suite**

Run:

```bash
make test
```

Expected: PASS with coverage gate passed.

- [ ] **Step 4: Inspect final diff**

Run:

```bash
git status --short
git diff --stat
```

Expected: only files related to recorder-driven audio stream and artifact loading are modified.

- [ ] **Step 5: Commit final cleanup**

```bash
git add Sources Tests
git commit -m "test: verify recorder-driven audio stream"
```

## Self-Review Notes

- Spec coverage: Tasks 1-2 cover event-driven audio consumption and recorder events. Tasks 3-4 cover UI command/listen boundaries and process-ended stop. Task 5 covers artifact snapshots and body-time file read removal. Task 6 covers final deletion of old drain usage and full verification.
- Scope check: The plan does not introduce `RecordingRuntime`, does not rewrite the caption reducer, and keeps process discovery outside `MeetingRecorder`.
- Type consistency: Public event types use `MeetingRecorderEvent`, `MeetingRecorderStatusSnapshot`, and `MeetingRecorderFailure` consistently. The view model consumes recorder events and still passes `TranscriptSegmentAccumulationResult` to the existing caption pipeline.
