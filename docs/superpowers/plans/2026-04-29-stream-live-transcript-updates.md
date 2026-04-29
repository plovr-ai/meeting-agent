# Stream Live Transcript Updates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route every transcription provider through one in-memory transcript update pipeline so active live captions no longer depend on polling persisted transcript files.

**Architecture:** Add `TranscriptSegmentUpdate`, `TranscriptSegmentAccumulator`, and a synchronous recording sink that owns canonical transcript state. Providers emit updates into the sink; `TranscriptFileWriter` persists canonical documents but no longer owns STT upsert semantics privately; `MeetingAgentViewModel` consumes recorder-drained updates for active meetings and keeps file reloads for historical/cold paths.

**Tech Stack:** Swift 5.9, Swift Package Manager, XCTest, macOS 14.2+.

---

### Task 1: Shared Transcript Accumulator

**Files:**
- Create: `Sources/MeetingAgentCore/TranscriptSegmentAccumulator.swift`
- Modify: `Sources/MeetingAgentCore/TranscriptFileWriter.swift`
- Test: `Tests/MeetingAgentCoreTests/TranscriptSegmentAccumulatorTests.swift`

- [ ] **Step 1: Write the failing accumulator tests**

Create `Tests/MeetingAgentCoreTests/TranscriptSegmentAccumulatorTests.swift`:

```swift
import XCTest
@testable import MeetingAgentCore

final class TranscriptSegmentAccumulatorTests: XCTestCase {
    func testUpsertReplacesInterimWithFinalSameID() {
        var accumulator = TranscriptSegmentAccumulator()

        let first = accumulator.apply(.upsert(TranscriptSegment(id: "active", text: "hello", isFinal: false)))
        let second = accumulator.apply(.upsert(TranscriptSegment(id: "active", text: "hello world", isFinal: true)))

        XCTAssertEqual(first.document.segments.map(\.text), ["hello"])
        XCTAssertEqual(second.document.segments.map(\.id), ["active"])
        XCTAssertEqual(second.document.segments.map(\.text), ["hello world"])
        XCTAssertEqual(second.document.segments.map(\.isFinal), [true])
    }

    func testUpsertFinalPrunesShiftedDeepgramInterim() {
        var accumulator = TranscriptSegmentAccumulator()

        _ = accumulator.apply(.upsert(TranscriptSegment(
            id: "deepgram-transcribe-stream-7.59",
            startTimeSeconds: 7.59,
            endTimeSeconds: 11.67,
            text: "to give it a like as it really does help the channel",
            sourceProvider: "deepgram-transcribe",
            isFinal: false,
            timingSource: .precise
        )))
        let result = accumulator.apply(.upsert(TranscriptSegment(
            id: "deepgram-transcribe-stream-7.51",
            startTimeSeconds: 7.51,
            endTimeSeconds: 11.75,
            text: "to give it a like as it really does help the channel",
            sourceProvider: "deepgram-transcribe",
            isFinal: true,
            timingSource: .precise
        )))

        XCTAssertEqual(result.document.segments.map(\.id), ["deepgram-transcribe-stream-7.51"])
        XCTAssertEqual(result.document.segments.map(\.isFinal), [true])
    }

    func testReplaceAllReplacesCurrentDocument() {
        var accumulator = TranscriptSegmentAccumulator()
        _ = accumulator.apply(.upsert(TranscriptSegment(id: "old", text: "old text")))

        let result = accumulator.apply(.replaceAll([
            TranscriptSegment(id: "new-1", text: "first"),
            TranscriptSegment(id: "new-2", text: "second")
        ]))

        XCTAssertEqual(result.document.segments.map(\.id), ["new-1", "new-2"])
        XCTAssertEqual(result.document.segments.map(\.text), ["first", "second"])
    }

    func testPreservesTranslationWhenSameTextUpdatesSameSegment() {
        var accumulator = TranscriptSegmentAccumulator(document: TranscriptDocument(segments: [
            TranscriptSegment(
                id: "segment-1",
                text: "Confirm owner.",
                translatedText: "确认负责人。",
                translationTargetLocale: "zh-CN",
                translationIsFinal: true
            )
        ]))

        let result = accumulator.apply(.upsert(TranscriptSegment(id: "segment-1", text: "Confirm owner.")))

        XCTAssertEqual(result.document.segments.first?.translatedText, "确认负责人。")
        XCTAssertEqual(result.document.segments.first?.translationTargetLocale, "zh-CN")
        XCTAssertEqual(result.document.segments.first?.translationIsFinal, true)
    }
}
```

- [ ] **Step 2: Run tests to verify RED**

Run:

```bash
swift test --filter TranscriptSegmentAccumulatorTests
```

Expected: compile failure because `TranscriptSegmentAccumulator` and `TranscriptSegmentUpdate` do not exist.

- [ ] **Step 3: Implement the accumulator**

Create `Sources/MeetingAgentCore/TranscriptSegmentAccumulator.swift` with internal/public API:

```swift
import Foundation

public enum TranscriptSegmentUpdate: Equatable {
    case upsert(TranscriptSegment)
    case replaceAll([TranscriptSegment])
    case replaceWithPlainText(String)
}

public struct TranscriptSegmentAccumulationResult: Equatable {
    public let document: TranscriptDocument
    public let changedSegmentIDs: [String]
    public let plainTextReplacement: String?
}

public struct TranscriptSegmentAccumulator {
    private var document: TranscriptDocument

    public init(document: TranscriptDocument = TranscriptDocument()) {
        self.document = document
    }

    public var currentDocument: TranscriptDocument {
        document
    }

    @discardableResult
    public mutating func apply(_ update: TranscriptSegmentUpdate) -> TranscriptSegmentAccumulationResult {
        switch update {
        case .upsert(let segment):
            return applyUpsert(segment)
        case .replaceAll(let segments):
            document = TranscriptDocument(version: document.version, segments: segments)
            return TranscriptSegmentAccumulationResult(
                document: document,
                changedSegmentIDs: segments.map(\.id),
                plainTextReplacement: nil
            )
        case .replaceWithPlainText(let text):
            document = TranscriptDocument(version: document.version, segments: [])
            return TranscriptSegmentAccumulationResult(
                document: document,
                changedSegmentIDs: [],
                plainTextReplacement: text
            )
        }
    }
}
```

Move the private STT helper methods from `TranscriptFileWriter` into this file and make `applyUpsert(_:)` use the exact existing algorithm:

```swift
private mutating func applyUpsert(_ segment: TranscriptSegment) -> TranscriptSegmentAccumulationResult {
    let previousIDs = Set(document.segments.map(\.id))
    if let index = document.segments.firstIndex(where: { $0.id == segment.id }) {
        document.segments[index] = Self.segment(segment, preservingTranslationFrom: document.segments[index])
        document.segments.removeAll {
            $0.id != segment.id && Self.shouldReplaceExistingSegment($0, with: segment)
        }
    } else {
        if document.segments.contains(where: { Self.shouldKeepExistingSegment($0, insteadOf: segment) }) {
            return TranscriptSegmentAccumulationResult(document: document, changedSegmentIDs: [], plainTextReplacement: nil)
        }
        document.segments.removeAll { Self.shouldReplaceExistingSegment($0, with: segment) }
        document.segments.append(segment)
    }
    document.segments = Self.trimmedCoveredInterimPrefixes(document.segments)
    document.segments = Self.prunedCoveredInterimSegments(document.segments)
    let newIDs = Set(document.segments.map(\.id))
    let changed = Array(previousIDs.symmetricDifference(newIDs).union([segment.id])).sorted()
    return TranscriptSegmentAccumulationResult(document: document, changedSegmentIDs: changed, plainTextReplacement: nil)
}
```

- [ ] **Step 4: Refactor `TranscriptFileWriter.upsert` to delegate**

In `TranscriptFileWriter.upsert(_:)`, replace the inline algorithm with:

```swift
public func upsert(_ segment: TranscriptSegment) throws {
    guard !isClosed else { return }
    var accumulator = TranscriptSegmentAccumulator(
        document: try Self.readDocument(from: structuredURL)
    )
    let result = accumulator.apply(.upsert(segment))
    try replace(with: result.document.segments)
}
```

Keep `replace(with text:)`, `replace(with segments:)`, manual edit helpers, read/render helpers, and speaker label assignment in `TranscriptFileWriter`.

- [ ] **Step 5: Run focused tests to verify GREEN**

Run:

```bash
swift test --filter TranscriptSegmentAccumulatorTests
swift test --filter TranscriptFileWriterTests
```

Expected: both pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/MeetingAgentCore/TranscriptSegmentAccumulator.swift Sources/MeetingAgentCore/TranscriptFileWriter.swift Tests/MeetingAgentCoreTests/TranscriptSegmentAccumulatorTests.swift
git commit -m "feat: add shared transcript segment accumulator (#82)"
```

### Task 2: Transcript Update Sink And Recorder Hub

**Files:**
- Modify: `Sources/MeetingAgentCore/SpeechTranscriptionProvider.swift`
- Modify: `Sources/MeetingAgentCore/MeetingRecorder.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingRecorderTests.swift`

- [ ] **Step 1: Write failing recorder tests**

Add tests to `MeetingRecorderTests` before the fixture section:

```swift
func testRecorderDrainsTranscriptUpdatesWithoutReadingTranscriptFile() async throws {
    let fixture = try RecorderFixture()
    defer { try? FileManager.default.removeItem(at: fixture.storeRoot) }
    let record = try fixture.recorder.prepareRecord(for: fixture.target, startedAt: Date(timeIntervalSince1970: 100))
    try await fixture.recorder.startRecording(target: fixture.target, record: record)

    fixture.transcriber.emit(.upsert(TranscriptSegment(
        id: "segment-1",
        text: "hello live",
        language: "en-US",
        sourceProvider: "fake",
        isFinal: true
    )))

    let updates = fixture.recorder.drainTranscriptUpdates()

    XCTAssertEqual(updates.flatMap { $0.document.segments.map(\.text) }, ["hello live"])
}

func testRecorderPersistsCanonicalTranscriptFromUpdates() async throws {
    let fixture = try RecorderFixture()
    defer { try? FileManager.default.removeItem(at: fixture.storeRoot) }
    let record = try fixture.recorder.prepareRecord(for: fixture.target, startedAt: Date(timeIntervalSince1970: 100))
    try await fixture.recorder.startRecording(target: fixture.target, record: record)

    fixture.transcriber.emit(.upsert(TranscriptSegment(
        id: "segment-1",
        text: "persist me",
        language: "en-US",
        sourceProvider: "fake",
        isFinal: true
    )))

    _ = fixture.recorder.drainTranscriptUpdates()

    let document = try TranscriptFileWriter.readDocument(from: XCTUnwrap(record.transcriptJSONURL))
    XCTAssertEqual(document.segments.map(\.text), ["persist me"])
}
```

Extend `FakeAudioFrameTranscriber` with an update sink:

```swift
var transcriptUpdateSink: TranscriptUpdateSink?

func emit(_ update: TranscriptSegmentUpdate) {
    transcriptUpdateSink?.receive(update)
}
```

- [ ] **Step 2: Run tests to verify RED**

Run:

```bash
swift test --filter MeetingRecorderTests/testRecorderDrainsTranscriptUpdatesWithoutReadingTranscriptFile
```

Expected: compile failure because `TranscriptUpdateSink`, recorder draining, and fake factory sink injection do not exist.

- [ ] **Step 3: Add sink protocol and stream context**

In `SpeechTranscriptionProvider.swift`, add:

```swift
public protocol TranscriptUpdateSink: AnyObject {
    func receive(_ update: TranscriptSegmentUpdate)
}
```

Extend `SpeechTranscriptionStreamContext` with:

```swift
public let transcriptUpdateSink: TranscriptUpdateSink?
```

and update the initializer default to `nil`.

Update `StreamingSpeechTranscriberFactory.startTranscriber` to accept a sink parameter and pass it into `SpeechTranscriptionStreamContext`.

- [ ] **Step 4: Add recorder sink**

In `MeetingRecorder`, change `transcriberFactory` signature to include `TranscriptUpdateSink?`:

```swift
private let transcriberFactory: (SpeechTranscriptionConfiguration, URL, Double, Int, PerformanceEventLogger?, TranscriptUpdateSink?) async throws -> AudioFrameTranscriber
```

Add a private sink class in `MeetingRecorder.swift`:

```swift
private final class RecordingTranscriptUpdateSink: TranscriptUpdateSink {
    private let writer: TranscriptFileWriter
    private var accumulator = TranscriptSegmentAccumulator()
    private var pendingResults: [TranscriptSegmentAccumulationResult] = []
    private let lock = NSLock()

    init(transcriptURL: URL) throws {
        self.writer = try TranscriptFileWriter(url: transcriptURL)
    }

    func receive(_ update: TranscriptSegmentUpdate) {
        lock.lock()
        defer { lock.unlock() }
        let result = accumulator.apply(update)
        pendingResults.append(result)
        persist(result)
    }

    func drainResults() -> [TranscriptSegmentAccumulationResult] {
        lock.lock()
        defer { lock.unlock() }
        let results = pendingResults
        pendingResults.removeAll()
        return results
    }

    func close() {
        try? writer.close()
    }

    private func persist(_ result: TranscriptSegmentAccumulationResult) {
        if let text = result.plainTextReplacement {
            try? writer.replace(with: text)
        } else {
            try? writer.replace(with: result.document.segments)
        }
    }
}
```

Add recorder state:

```swift
private var transcriptUpdateSink: RecordingTranscriptUpdateSink?
```

When starting recording and `transcriptURL` exists, create the sink once and pass it into the transcriber factory. Add:

```swift
public func drainTranscriptUpdates() -> [TranscriptSegmentAccumulationResult] {
    transcriptUpdateSink?.drainResults() ?? []
}
```

On stop, close and clear the sink.

- [ ] **Step 5: Update test fakes**

Update `FakeRecorderTranscriberFactory.startTranscriber` to accept `transcriptUpdateSink` and assign it to the fake transcriber:

```swift
transcriber.transcriptUpdateSink = transcriptUpdateSink
```

Update every test fake transcriber factory in `MeetingAgentViewModelTests`, `SpeechTranscriptionProviderTests`, and other compile errors to accept the new parameter.

- [ ] **Step 6: Run focused recorder tests**

Run:

```bash
swift test --filter MeetingRecorderTests
```

Expected: pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/MeetingAgentCore/SpeechTranscriptionProvider.swift Sources/MeetingAgentCore/MeetingRecorder.swift Tests/MeetingAgentCoreTests/MeetingRecorderTests.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift Tests/MeetingAgentCoreTests/SpeechTranscriptionProviderTests.swift
git commit -m "feat: stream transcript updates through recorder (#82)"
```

### Task 3: Providers Emit Unified Updates

**Files:**
- Modify: `Sources/MeetingAgentCore/DeepgramTranscriptionProvider.swift`
- Modify: `Sources/MeetingAgentCore/OpenAIRealtimeTranscriptionProvider.swift`
- Modify: `Sources/MeetingAgentCore/WhisperTranscriptionProvider.swift`
- Test: `Tests/MeetingAgentCoreTests/DeepgramStreamingTranscriptionProviderTests.swift`
- Test: `Tests/MeetingAgentCoreTests/OpenAIRealtimeTranscriptionProviderTests.swift`
- Test: `Tests/MeetingAgentCoreTests/WhisperTranscriptionProviderTests.swift`

- [ ] **Step 1: Write failing provider assertions**

In `DeepgramStreamingTranscriptionProviderTests.testStreamingProviderSendsAudioFramesAndWritesIncomingTranscriptSegments`, add a recording sink and pass it into context:

```swift
let updateSink = RecordingTranscriptUpdateSinkForTests()
...
transcriptUpdateSink: updateSink
```

Assert:

```swift
XCTAssertEqual(updateSink.updates, [
    .upsert(TranscriptSegment(
        id: "dg-1",
        startTimeSeconds: 0.1,
        endTimeSeconds: 0.5,
        text: "hello live",
        language: "en-US",
        sourceProvider: "deepgram-transcribe",
        confidence: 0.92,
        timingSource: .precise
    ))
])
```

Add the same test helper to this file:

```swift
private final class RecordingTranscriptUpdateSinkForTests: TranscriptUpdateSink {
    private(set) var updates: [TranscriptSegmentUpdate] = []
    func receive(_ update: TranscriptSegmentUpdate) {
        updates.append(update)
    }
}
```

In `OpenAIRealtimeTranscriptionProviderTests`, pass a sink and assert completed events emit `.upsert`.

For Whisper, add a focused test around the existing fake CLI path that asserts completed batch transcription emits `.replaceAll(segments)` into the sink.

- [ ] **Step 2: Run provider tests to verify RED**

Run:

```bash
swift test --filter DeepgramStreamingTranscriptionProviderTests/testStreamingProviderSendsAudioFramesAndWritesIncomingTranscriptSegments
swift test --filter OpenAIRealtimeTranscriptionProviderTests/testProviderStartsSessionSendsConfigurationAndWritesCompletedSegments
```

Expected: assertion failures because providers still write directly without emitting sink updates.

- [ ] **Step 3: Update Deepgram streaming provider**

In `DeepgramStreamingSpeechTranscriptionProvider.start(context:)`, stop constructing a private writer for sink-enabled paths. Pass `context.transcriptUpdateSink` into `DeepgramStreamingTranscriber`.

In `DeepgramStreamingTranscriber.write(_:)`, after `stableFallbackSegment`, emit:

```swift
transcriptUpdateSink?.receive(.upsert(segment))
```

Keep direct writer fallback only if `context.transcriptUpdateSink == nil`, so existing direct provider tests still persist when no recorder sink is present.

- [ ] **Step 4: Update OpenAI realtime transcription**

In `OpenAIRealtimeTranscriptionProvider.start(context:)`, pass `context.transcriptUpdateSink` into `OpenAIRealtimeTranscriptionTranscriber`.

When handling `.completed`, create the `TranscriptSegment` once and:

```swift
if let transcriptUpdateSink {
    transcriptUpdateSink.receive(.upsert(segment))
} else {
    try writer.append(segment)
}
```

For `.failed`, emit `.replaceWithPlainText("OpenAI Realtime transcription failed: \(message)")` when a sink exists, otherwise keep `writer.replace`.

- [ ] **Step 5: Update Whisper/local batch paths**

For any batch transcription path that currently calls `TranscriptFileWriter(url: transcriptURL).replace(with: transcriptSegments)`, route through `.replaceAll(transcriptSegments)` when `SpeechTranscriptionStreamContext` or retry flow provides a sink. Where the provider API is file-only, keep writer behavior and add a small adapter in caller code later in Task 4.

- [ ] **Step 6: Run provider tests**

Run:

```bash
swift test --filter DeepgramStreamingTranscriptionProviderTests
swift test --filter OpenAIRealtimeTranscriptionProviderTests
swift test --filter WhisperTranscriptionProviderTests
```

Expected: pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/MeetingAgentCore/DeepgramTranscriptionProvider.swift Sources/MeetingAgentCore/OpenAIRealtimeTranscriptionProvider.swift Sources/MeetingAgentCore/WhisperTranscriptionProvider.swift Tests/MeetingAgentCoreTests/DeepgramStreamingTranscriptionProviderTests.swift Tests/MeetingAgentCoreTests/OpenAIRealtimeTranscriptionProviderTests.swift Tests/MeetingAgentCoreTests/WhisperTranscriptionProviderTests.swift
git commit -m "feat: emit transcript updates from providers (#82)"
```

### Task 4: ViewModel Uses Recorder Updates For Active Captions

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] **Step 1: Write failing active-recording ViewModel tests**

Add to `MeetingAgentViewModelTests` near existing live caption refresh tests:

```swift
func testDrainRecordingFramesUsesRecorderTranscriptUpdatesForLiveCaptions() async throws {
    let fixture = try ViewModelRecorderFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let target = AudioCaptureTarget(processID: 42, displayName: "Google Meet", bundleIdentifier: "com.google.Chrome")
    let viewModel = MeetingAgentViewModel(store: fixture.store, recorder: fixture.recorder, processTargetsProvider: { [target] })

    try await viewModel.startRecording(for: target)
    fixture.transcriber.emit(.upsert(TranscriptSegment(
        id: "segment-1",
        text: "hello from memory",
        language: "en-US",
        sourceProvider: "fake",
        isFinal: true
    )))

    viewModel.drainRecordingFrames()

    XCTAssertEqual(viewModel.liveCaptionTurns.map(\.originalText), ["hello from memory"])
}
```

Add a second test proving the active path does not need file reload:

```swift
func testActiveRecordingCaptionDoesNotRequireTranscriptFileReload() async throws {
    let fixture = try ViewModelRecorderFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let target = AudioCaptureTarget(processID: 42, displayName: "Google Meet", bundleIdentifier: "com.google.Chrome")
    let viewModel = MeetingAgentViewModel(store: fixture.store, recorder: fixture.recorder, processTargetsProvider: { [target] })

    try await viewModel.startRecording(for: target)
    let transcriptJSONURL = try XCTUnwrap(viewModel.selectedMeeting?.transcriptJSONURL)
    try? FileManager.default.removeItem(at: transcriptJSONURL)
    fixture.transcriber.emit(.upsert(TranscriptSegment(
        id: "segment-1",
        text: "caption without file",
        language: "en-US",
        sourceProvider: "fake",
        isFinal: true
    )))

    viewModel.drainRecordingFrames()

    XCTAssertEqual(viewModel.liveCaptionTurns.map(\.originalText), ["caption without file"])
}
```

Extend `ViewModelFakeAudioFrameTranscriber` the same way as recorder fake:

```swift
var transcriptUpdateSink: TranscriptUpdateSink?
func emit(_ update: TranscriptSegmentUpdate) {
    transcriptUpdateSink?.receive(update)
}
```

- [ ] **Step 2: Run tests to verify RED**

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testDrainRecordingFramesUsesRecorderTranscriptUpdatesForLiveCaptions
swift test --filter MeetingAgentViewModelTests/testActiveRecordingCaptionDoesNotRequireTranscriptFileReload
```

Expected: fail because `drainRecordingFrames()` still relies on file-backed refresh.

- [ ] **Step 3: Add active update application**

In `MeetingAgentViewModel.drainRecordingFrames()`, replace the unconditional hot-path call:

```swift
refreshLiveCaptionTurnsFromSelectedMeeting()
```

with:

```swift
let transcriptResults = recorder.drainTranscriptUpdates()
if transcriptResults.isEmpty {
    if !isRecording {
        refreshLiveCaptionTurnsFromSelectedMeeting()
    }
} else {
    applyTranscriptAccumulationResultsToLiveCaptions(transcriptResults)
}
```

Add helper:

```swift
private func applyTranscriptAccumulationResultsToLiveCaptions(_ results: [TranscriptSegmentAccumulationResult]) {
    for result in results {
        for segment in result.document.segments {
            applyLiveCaptionSegment(segment)
        }
    }
    liveCaptionTurns = liveCaptionStore.turns
    meetingProgressHealth.caption = liveCaptionTurns.isEmpty ? .idle : .live
    scheduleCaptionTextTranslationIfNeeded()
}
```

Extract duplicated segment ingestion logic from `refreshLiveCaptionTurnsFromSelectedMeeting()` into:

```swift
private func applyLiveCaptionSegment(_ segment: TranscriptSegment) {
    guard markProcessedLiveCaptionSegmentIfNeeded(segment) else { return }
    currentPerformanceEventLogger()?.logSegment(
        "caption_segment_ingested",
        segment: segment,
        metadata: ["path": segment.isFinal ? "final" : "interim"]
    )
    if segment.isFinal {
        for update in liveCaptionChunker.append(segment) {
            liveCaptionStore.upsert(update.turn)
            hydrateCachedTranslation(from: segment, toTurnID: update.turn.id)
            logCaptionTurnUpdate(update.turn)
        }
    } else {
        _ = liveCaptionStore.append(segment)
        hydrateCachedTranslation(from: segment, toTurnID: segment.id)
    }
}
```

Keep `refreshLiveCaptionTurnsFromSelectedMeeting()` for selected historical/cold reloads, but have it call the same helper.

- [ ] **Step 4: Preserve historical file-backed behavior**

Run existing tests that select/reopen meetings and edit transcripts:

```bash
swift test --filter MeetingAgentViewModelTests/testReopenedMeetingHydratesPersistedCaptionTranslationWithoutProviderRequest
swift test --filter MeetingAgentViewModelTests/testUpdateSpeakerLabelRefreshesTranscriptArtifactsAndLiveCaptions
swift test --filter MeetingAgentViewModelTests/testUpdateTranscriptSegmentTextRefreshesLiveCaptionsAndInvalidatesDownstreamArtifacts
```

Expected: pass.

- [ ] **Step 5: Run focused ViewModel tests**

Run:

```bash
swift test --filter MeetingAgentViewModelTests
```

Expected: pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/MeetingAgentCore/MeetingAgentViewModel.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift
git commit -m "feat: render active captions from transcript updates (#82)"
```

### Task 5: Retry And Batch Transcription Unification

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Modify: `Sources/MeetingAgentCore/WhisperTranscriptionProvider.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`
- Test: `Tests/MeetingAgentCoreTests/WhisperTranscriptionProviderTests.swift`

- [ ] **Step 1: Write failing retry/batch tests**

Add a ViewModel retry test that uses Deepgram batch retry and asserts the transcript artifact comes from `.replaceAll` canonical behavior:

```swift
func testRetryTranscriptionReplacesTranscriptThroughUnifiedPipeline() async throws {
    let fixture = try ViewModelRecorderFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    var configuration = SpeechTranscriptionConfiguration.default
    configuration.transcriptionExecutionMode = .hosted
    configuration.hostedTranscriptionProviderID = SpeechTranscriptionConfiguration.defaultDeepgramTranscriptionProviderID
    configuration.deepgramAPIKey = "key"
    let viewModel = MeetingAgentViewModel(store: fixture.store, speechConfiguration: configuration, processTargetsProvider: { [] })
    let stored = try fixture.store.createMeeting(name: "Recorded", startedAt: Date(timeIntervalSince1970: 100))
    try Data([1, 2, 3]).write(to: XCTUnwrap(stored.record.audioURL))
    try TranscriptFileWriter(url: XCTUnwrap(stored.record.transcriptURL)).replace(with: [
        TranscriptSegment(id: "old", text: "old")
    ])
    try viewModel.loadMeetings()

    await viewModel.retryTranscription(for: stored.record.id)

    let document = try TranscriptFileWriter.readDocument(from: XCTUnwrap(stored.record.transcriptJSONURL))
    XCTAssertFalse(document.segments.map(\.id).contains("old"))
}
```

Use an injectable batch provider if needed; if current code hard-codes Deepgram, first add the smallest provider factory injection needed for a deterministic test.

- [ ] **Step 2: Run test to verify RED**

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testRetryTranscriptionReplacesTranscriptThroughUnifiedPipeline
```

Expected: fail until retry path is routed through the shared update pipeline.

- [ ] **Step 3: Add a small file-backed transcript sink adapter**

Create or add near transcript pipeline types:

```swift
public final class FileBackedTranscriptUpdateSink: TranscriptUpdateSink {
    private let writer: TranscriptFileWriter
    private var accumulator: TranscriptSegmentAccumulator

    public init(transcriptURL: URL, initialDocument: TranscriptDocument = TranscriptDocument()) throws {
        self.writer = try TranscriptFileWriter(url: transcriptURL)
        self.accumulator = TranscriptSegmentAccumulator(document: initialDocument)
    }

    public func receive(_ update: TranscriptSegmentUpdate) {
        let result = accumulator.apply(update)
        if let text = result.plainTextReplacement {
            try? writer.replace(with: text)
        } else {
            try? writer.replace(with: result.document.segments)
        }
    }
}
```

Use it from retry/batch flows so they also enter the same update model.

- [ ] **Step 4: Route batch outputs through `replaceAll`**

In `MeetingAgentViewModel.retryTranscription`, when a batch provider returns `TranscriptDocument`, replace direct writer calls with:

```swift
let sink = try FileBackedTranscriptUpdateSink(transcriptURL: transcriptURL)
sink.receive(.replaceAll(document.segments))
```

For Whisper existing audio transcription code paths, route final segment arrays through `replaceAll` inside `WhisperTranscriptionProvider` where the complete segment list is available.

- [ ] **Step 5: Run focused tests**

Run:

```bash
swift test --filter WhisperTranscriptionProviderTests
swift test --filter MeetingAgentViewModelTests/testRetryTranscriptionReplacesTranscriptThroughUnifiedPipeline
```

Expected: pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/MeetingAgentCore/MeetingAgentViewModel.swift Sources/MeetingAgentCore/WhisperTranscriptionProvider.swift Sources/MeetingAgentCore/TranscriptSegmentAccumulator.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift Tests/MeetingAgentCoreTests/WhisperTranscriptionProviderTests.swift
git commit -m "feat: route batch transcripts through unified pipeline (#82)"
```

### Task 6: Performance Events And Final Verification

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingRecorder.swift`
- Modify: `Sources/MeetingAgentCore/PerformanceEventLogger.swift` if helper methods are useful
- Test: `Tests/MeetingAgentCoreTests/MeetingRecorderTests.swift`

- [ ] **Step 1: Write failing event test**

Add to `MeetingRecorderTests`:

```swift
func testTranscriptUpdatePipelineLogsEmittedAndRenderedEvents() async throws {
    let fixture = try RecorderFixture()
    defer { try? FileManager.default.removeItem(at: fixture.storeRoot) }
    let record = try fixture.recorder.prepareRecord(for: fixture.target, startedAt: Date(timeIntervalSince1970: 100))
    try await fixture.recorder.startRecording(target: fixture.target, record: record)

    fixture.transcriber.emit(.upsert(TranscriptSegment(
        id: "segment-1",
        text: "hello",
        sourceProvider: "fake",
        isFinal: true
    )))
    _ = fixture.recorder.drainTranscriptUpdates()

    let events = try String(contentsOf: XCTUnwrap(record.performanceEventsURL), encoding: .utf8)
    XCTAssertTrue(events.contains("transcript_segment_emitted"))
    XCTAssertTrue(events.contains("transcript_segment_persisted"))
}
```

- [ ] **Step 2: Run test to verify RED**

Run:

```bash
swift test --filter MeetingRecorderTests/testTranscriptUpdatePipelineLogsEmittedAndRenderedEvents
```

Expected: fail because the new events are not logged.

- [ ] **Step 3: Log transcript pipeline events**

In `RecordingTranscriptUpdateSink.receive(_:)`, log:

- `transcript_segment_emitted` before accumulation for `.upsert`
- `transcript_segment_persisted` after successful writer replace

Use `PerformanceEventLogger.logSegment` for segment-bearing events.

- [ ] **Step 4: Run local verification**

Run:

```bash
swift test --filter TranscriptSegmentAccumulatorTests
swift test --filter MeetingRecorderTests
swift test --filter MeetingAgentViewModelTests
swift test --filter DeepgramStreamingTranscriptionProviderTests
swift test --filter OpenAIRealtimeTranscriptionProviderTests
swift test --filter WhisperTranscriptionProviderTests
make test
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingAgentCore/MeetingRecorder.swift Sources/MeetingAgentCore/PerformanceEventLogger.swift Tests/MeetingAgentCoreTests/MeetingRecorderTests.swift
git commit -m "feat: log transcript update pipeline events (#82)"
```

### Task 7: Review, Lessons, And Ship Readiness

**Files:**
- Possibly modify: `MISTAKES.md` only if a reusable mistake occurred

- [ ] **Step 1: Inspect final diff**

Run:

```bash
git status --short
git diff origin/main...HEAD --stat
git diff origin/main...HEAD
```

Expected: only issue #82 files and docs changed.

- [ ] **Step 2: Run code review**

Run the available code review workflow or manually review for:

- no duplicate STT dedupe rules left private in `TranscriptFileWriter`
- no active recording file reload hot path
- no actor-isolated state passed across `await`
- no public API expansion beyond intentional transcript pipeline types
- all fake transcriber factories updated consistently

- [ ] **Step 3: Record lessons only if needed**

If a reusable mistake occurred, append to `MISTAKES.md` and commit:

```bash
git add MISTAKES.md
git commit -m "docs: record lessons learned from #82"
```

If no reusable mistake occurred, skip this commit and record `intentionally_skipped` in the final workflow ledger.

- [ ] **Step 4: Final report facts**

Collect:

```bash
git log --oneline origin/main..HEAD
git status --short
```

Expected: clean working tree and commits ready for PR.
