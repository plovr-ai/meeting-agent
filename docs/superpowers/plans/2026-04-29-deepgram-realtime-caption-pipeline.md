# Deepgram Realtime Caption Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Align the primary Deepgram realtime caption chain by moving caption assembly and caption translation scheduling out of `MeetingAgentViewModel` into focused, testable core pipeline types.

**Architecture:** Keep provider-specific behavior behind `TranscriptSegmentUpdate`. Add `LiveCaptionPipeline` as the ViewModel-facing coordination boundary, evolve `LiveCaptionChunker` into `CaptionTurnAssembler`, and move caption translation queue state into `CaptionTranslationScheduler`. Preserve current user-visible behavior while making Deepgram interim/final handling explicit.

**Tech Stack:** Swift 5.9, XCTest, Swift Concurrency, SwiftUI `ObservableObject`, existing `MeetingAgentCore` types.

---

## File Structure

- Create `Sources/MeetingAgentCore/LiveCaptionPipeline.swift`
  - Owns `LiveCaptionPipelineSnapshot`, the in-memory `LiveCaptionStore`, `CaptionTurnAssembler`, and `CaptionTranslationScheduler`.
  - Provides `apply`, `replay`, `flush`, and `reset`.
- Create `Sources/MeetingAgentCore/CaptionTurnAssembler.swift`
  - New focused caption assembly unit derived from `LiveCaptionChunker`.
  - Handles interim draft updates, final merging, soft boundaries, hard boundaries, and removals.
- Create `Sources/MeetingAgentCore/CaptionTranslationScheduler.swift`
  - Owns draft/final translation queue state currently stored in `MeetingAgentViewModel`.
  - Controls same-language completion, throttling, cancellation, final-priority scheduling, and health.
- Modify `Sources/MeetingAgentCore/LiveMeetingCockpit.swift`
  - Keep shared caption models.
  - Reduce `LiveCaptionStore` to display-state storage.
- Modify `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
  - Replace private caption chunking and translation scheduling state with one `LiveCaptionPipeline`.
  - Keep recording lifecycle, selected meeting state, and published state.
- Keep `Sources/MeetingAgentCore/LiveCaptionChunker.swift` initially for compatibility, then remove or turn into a compatibility wrapper after `CaptionTurnAssembler` is covered.
- Add `Tests/MeetingAgentCoreTests/LiveCaptionPipelineTests.swift`
- Add `Tests/MeetingAgentCoreTests/CaptionTurnAssemblerTests.swift`
- Add `Tests/MeetingAgentCoreTests/CaptionTranslationSchedulerTests.swift`
- Update existing tests:
  - `Tests/MeetingAgentCoreTests/LiveCaptionChunkerTests.swift`
  - `Tests/MeetingAgentCoreTests/LiveCaptionStoreTests.swift`
  - `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

## Task 1: Add LiveCaptionPipeline Wrapper

**Files:**
- Create: `Sources/MeetingAgentCore/LiveCaptionPipeline.swift`
- Test: `Tests/MeetingAgentCoreTests/LiveCaptionPipelineTests.swift`
- Modify: `Package.swift` only if the package uses explicit source lists. The current package uses directory-based targets, so no change should be needed.

- [ ] **Step 1: Write the failing replay test**

Create `Tests/MeetingAgentCoreTests/LiveCaptionPipelineTests.swift`:

```swift
import XCTest
@testable import MeetingAgentCore

final class LiveCaptionPipelineTests: XCTestCase {
    func testReplayBuildsCaptionTurnsFromFinalTranscriptSegments() async {
        let pipeline = LiveCaptionPipeline(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            translationProvider: nil,
            performanceEventLogger: nil
        )
        let document = TranscriptDocument(segments: [
            TranscriptSegment(
                id: "segment-1",
                speaker: TranscriptSpeaker(identifier: "speaker-1"),
                text: "Hello team.",
                language: "en-US",
                isFinal: true,
                speechFinal: true
            )
        ])

        let snapshot = await pipeline.replay(document)

        XCTAssertEqual(snapshot.turns.count, 1)
        XCTAssertEqual(snapshot.turns[0].originalText, "Hello team.")
        XCTAssertEqual(snapshot.turns[0].sourceSegmentIDs, ["segment-1"])
        XCTAssertEqual(snapshot.turns[0].displayState, .sealed)
        XCTAssertEqual(snapshot.turns[0].boundaryStrength, .hard)
        XCTAssertEqual(snapshot.captionHealth, .live)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
swift test --filter LiveCaptionPipelineTests/testReplayBuildsCaptionTurnsFromFinalTranscriptSegments
```

Expected: compile failure because `LiveCaptionPipeline` does not exist.

- [ ] **Step 3: Add the minimal wrapper implementation**

Create `Sources/MeetingAgentCore/LiveCaptionPipeline.swift`:

```swift
import Foundation

public struct LiveCaptionPipelineSnapshot: Equatable {
    public var turns: [LiveCaptionTurn]
    public var captionHealth: LivePipelineHealth
    public var translationHealth: LivePipelineHealth

    public init(
        turns: [LiveCaptionTurn],
        captionHealth: LivePipelineHealth,
        translationHealth: LivePipelineHealth
    ) {
        self.turns = turns
        self.captionHealth = captionHealth
        self.translationHealth = translationHealth
    }
}

public final class LiveCaptionPipeline {
    private var store: LiveCaptionStore
    private var chunker: LiveCaptionChunker
    private let translationProvider: TextTranslationProvider?
    private let performanceEventLogger: PerformanceEventLogger?

    public init(
        sourceLocale: String,
        targetLocale: String,
        translationProvider: TextTranslationProvider?,
        performanceEventLogger: PerformanceEventLogger?
    ) {
        self.store = LiveCaptionStore(sourceLocale: sourceLocale, targetLocale: targetLocale)
        self.chunker = LiveCaptionChunker(sourceLocale: sourceLocale, targetLocale: targetLocale)
        self.translationProvider = translationProvider
        self.performanceEventLogger = performanceEventLogger
    }

    public func apply(_ result: TranscriptSegmentAccumulationResult) async -> LiveCaptionPipelineSnapshot {
        if result.plainTextReplacement != nil {
            store.reset(sourceLocale: store.sourceLocale, targetLocale: store.targetLocale)
        }
        return await replay(result.document)
    }

    public func replay(_ document: TranscriptDocument) async -> LiveCaptionPipelineSnapshot {
        let sourceLocale = store.sourceLocale
        let targetLocale = store.targetLocale
        store.reset(sourceLocale: sourceLocale, targetLocale: targetLocale)
        chunker = LiveCaptionChunker(sourceLocale: sourceLocale, targetLocale: targetLocale)
        for segment in document.segments where segment.isFinal {
            for update in chunker.append(segment) {
                store.upsert(update.turn)
            }
        }
        let turns = store.turns
        return LiveCaptionPipelineSnapshot(
            turns: turns,
            captionHealth: turns.isEmpty ? .idle : .live,
            translationHealth: .idle
        )
    }

    public func flush(reason: LiveCaptionFreezeReason) async -> LiveCaptionPipelineSnapshot {
        for update in chunker.flushOpenChunk(reason: reason) {
            store.upsert(update.turn)
        }
        let turns = store.turns
        return LiveCaptionPipelineSnapshot(
            turns: turns,
            captionHealth: turns.isEmpty ? .idle : .live,
            translationHealth: .idle
        )
    }

    public func reset(sourceLocale: String, targetLocale: String) {
        store.reset(sourceLocale: sourceLocale, targetLocale: targetLocale)
        chunker = LiveCaptionChunker(sourceLocale: sourceLocale, targetLocale: targetLocale)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run:

```bash
swift test --filter LiveCaptionPipelineTests/testReplayBuildsCaptionTurnsFromFinalTranscriptSegments
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingAgentCore/LiveCaptionPipeline.swift Tests/MeetingAgentCoreTests/LiveCaptionPipelineTests.swift
git commit -m "feat: add live caption pipeline wrapper"
```

## Task 2: Route ViewModel Caption Replay Through LiveCaptionPipeline

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] **Step 1: Write the failing ViewModel cold-replay test**

Add this test to `MeetingAgentViewModelTests` near existing live caption tests:

```swift
func testSelectingMeetingReplaysCaptionsThroughPipeline() throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MeetingAgentViewModelTests-\(UUID().uuidString)", isDirectory: true)
    let store = MeetingStore(baseDirectory: temporaryDirectory)
    let stored = try store.createMeeting(name: "Replay Meeting", startedAt: Date(timeIntervalSince1970: 0))
    let writer = try TranscriptFileWriter(url: stored.record.transcriptURL)
    try writer.replace(with: [
        TranscriptSegment(
            id: "segment-1",
            speaker: TranscriptSpeaker(identifier: "speaker-1"),
            text: "Pipeline replay works.",
            language: "en-US",
            isFinal: true,
            speechFinal: true
        )
    ])

    let viewModel = MeetingAgentViewModel(store: store)
    try viewModel.loadMeetings()
    viewModel.selectMeeting(stored.record.id)

    XCTAssertEqual(viewModel.liveCaptionTurns.map(\.originalText), ["Pipeline replay works."])
    XCTAssertEqual(viewModel.meetingProgressHealth.caption, .live)
}
```

- [ ] **Step 2: Run test before changing ViewModel**

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testSelectingMeetingReplaysCaptionsThroughPipeline
```

Expected: PASS or FAIL depending on current behavior. If it passes, keep it as a regression test for the pipeline route and continue.

- [ ] **Step 3: Add a pipeline property and factory to ViewModel**

In `MeetingAgentViewModel`, add:

```swift
private var liveCaptionPipeline: LiveCaptionPipeline
```

Initialize it at the end of `init` after `speechConfiguration` is resolved:

```swift
self.liveCaptionPipeline = LiveCaptionPipeline(
    sourceLocale: self.speechConfiguration.localeIdentifier,
    targetLocale: self.speechConfiguration.targetLocaleIdentifier,
    translationProvider: self.captionTranslationProviderFactory(self.speechConfiguration),
    performanceEventLogger: nil
)
```

Because Swift requires all stored properties to be initialized before using `self`, if this direct initialization causes an initialization-order error, assign a temporary pipeline before configuration branching:

```swift
self.liveCaptionPipeline = LiveCaptionPipeline(
    sourceLocale: "en-US",
    targetLocale: "zh-CN",
    translationProvider: nil,
    performanceEventLogger: nil
)
```

Then reset it after `speechConfiguration` is assigned:

```swift
self.liveCaptionPipeline = Self.makeLiveCaptionPipeline(
    configuration: self.speechConfiguration,
    translationProviderFactory: self.captionTranslationProviderFactory,
    performanceEventLogger: nil
)
```

Add helper:

```swift
private static func makeLiveCaptionPipeline(
    configuration: SpeechTranscriptionConfiguration,
    translationProviderFactory: (SpeechTranscriptionConfiguration) -> TextTranslationProvider?,
    performanceEventLogger: PerformanceEventLogger?
) -> LiveCaptionPipeline {
    LiveCaptionPipeline(
        sourceLocale: configuration.localeIdentifier,
        targetLocale: configuration.targetLocaleIdentifier,
        translationProvider: translationProviderFactory(configuration),
        performanceEventLogger: performanceEventLogger
    )
}
```

- [ ] **Step 4: Use the pipeline in `refreshLiveCaptionTurnsFromSelectedMeeting`**

Replace the body after reading `document` with:

```swift
Task { [weak self, document] in
    guard let self else { return }
    let snapshot = await self.liveCaptionPipeline.replay(document)
    self.liveCaptionTurns = snapshot.turns
    self.meetingProgressHealth.caption = snapshot.captionHealth
    self.meetingProgressHealth.translation = snapshot.translationHealth
}
```

If the method must remain synchronous for tests, use a synchronous `replaySync` method on `LiveCaptionPipeline` instead:

```swift
public func replaySync(_ document: TranscriptDocument) -> LiveCaptionPipelineSnapshot
```

Implement `replay(_:)` as:

```swift
public func replay(_ document: TranscriptDocument) async -> LiveCaptionPipelineSnapshot {
    replaySync(document)
}
```

Then call:

```swift
let snapshot = liveCaptionPipeline.replaySync(document)
liveCaptionTurns = snapshot.turns
meetingProgressHealth.caption = snapshot.captionHealth
meetingProgressHealth.translation = snapshot.translationHealth
```

- [ ] **Step 5: Run ViewModel test**

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testSelectingMeetingReplaysCaptionsThroughPipeline
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/MeetingAgentCore/MeetingAgentViewModel.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift
git commit -m "refactor: route caption replay through pipeline"
```

## Task 3: Introduce CaptionTurnAssembler For Existing Final-Segment Behavior

**Files:**
- Create: `Sources/MeetingAgentCore/CaptionTurnAssembler.swift`
- Test: `Tests/MeetingAgentCoreTests/CaptionTurnAssemblerTests.swift`
- Modify: `Sources/MeetingAgentCore/LiveCaptionPipeline.swift`

- [ ] **Step 1: Write tests matching current final behavior**

Create `Tests/MeetingAgentCoreTests/CaptionTurnAssemblerTests.swift`:

```swift
import XCTest
@testable import MeetingAgentCore

final class CaptionTurnAssemblerTests: XCTestCase {
    func testFinalSpeechFinalSegmentSealsHardBoundary() {
        var assembler = CaptionTurnAssembler(sourceLocale: "en-US", targetLocale: "zh-CN")
        let events = assembler.apply(TranscriptSegment(
            id: "segment-1",
            speaker: TranscriptSpeaker(identifier: "speaker-1"),
            text: "We should decide today.",
            language: "en-US",
            isFinal: true,
            speechFinal: true
        ))

        guard case .draftUpdated(let draft) = events.first else {
            return XCTFail("Expected draft update before seal")
        }
        guard case .sealed(let sealed) = events.last else {
            return XCTFail("Expected sealed event")
        }
        XCTAssertEqual(draft.originalText, "We should decide today.")
        XCTAssertEqual(sealed.originalText, "We should decide today.")
        XCTAssertEqual(sealed.boundaryReason, .speechFinal)
        XCTAssertEqual(sealed.boundaryStrength, .hard)
        XCTAssertEqual(sealed.displayState, .sealed)
    }

    func testSameSpeakerFinalSegmentsMergeUntilHardBoundary() {
        var assembler = CaptionTurnAssembler(sourceLocale: "en-US", targetLocale: "zh-CN")
        _ = assembler.apply(TranscriptSegment(
            id: "segment-1",
            speaker: TranscriptSpeaker(identifier: "speaker-1"),
            text: "First part",
            language: "en-US",
            isFinal: true
        ))
        let events = assembler.apply(TranscriptSegment(
            id: "segment-2",
            speaker: TranscriptSpeaker(identifier: "speaker-1"),
            text: "second part.",
            language: "en-US",
            isFinal: true,
            speechFinal: true
        ))

        guard case .sealed(let sealed) = events.last else {
            return XCTFail("Expected sealed event")
        }
        XCTAssertEqual(sealed.sourceSegmentIDs, ["segment-1", "segment-2"])
        XCTAssertEqual(sealed.originalText, "First part second part.")
    }
}
```

- [ ] **Step 2: Run tests to verify compile failure**

Run:

```bash
swift test --filter CaptionTurnAssemblerTests
```

Expected: compile failure because `CaptionTurnAssembler` does not exist.

- [ ] **Step 3: Implement assembler by porting LiveCaptionChunker behavior**

Create `Sources/MeetingAgentCore/CaptionTurnAssembler.swift`:

```swift
import Foundation

public enum CaptionTurnEvent: Equatable {
    case draftUpdated(LiveCaptionTurn)
    case sealed(LiveCaptionTurn)
    case removed(turnID: String)
}

public struct CaptionTurnAssembler {
    private var chunker: LiveCaptionChunker

    public init(sourceLocale: String, targetLocale: String, policy: LiveCaptionChunkingPolicy = LiveCaptionChunkingPolicy()) {
        self.chunker = LiveCaptionChunker(sourceLocale: sourceLocale, targetLocale: targetLocale, policy: policy)
    }

    public mutating func apply(_ segment: TranscriptSegment) -> [CaptionTurnEvent] {
        if segment.isFinal {
            return chunker.append(segment).map { update in
                update.turn.displayState == .sealed ? .sealed(update.turn) : .draftUpdated(update.turn)
            }
        }
        let draft = LiveCaptionTurn(
            sourceSegmentID: segment.id,
            speaker: segment.speaker,
            originalText: segment.text,
            sourceLocale: segment.language ?? "en-US",
            targetLocale: "zh-CN",
            isFinal: false,
            captionHealth: .live,
            translationHealth: .pending,
            createdAt: segment.createdAt,
            chunkState: .draft,
            translationRevision: 1,
            displayState: .draft,
            translationState: .draft,
            boundaryReason: nil,
            boundaryStrength: nil
        )
        return [.draftUpdated(draft)]
    }

    public mutating func removeSegments(notIn segmentIDs: Set<String>) -> [CaptionTurnEvent] {
        []
    }

    public mutating func flush(reason: LiveCaptionFreezeReason) -> [CaptionTurnEvent] {
        chunker.flushOpenChunk(reason: reason).map { .sealed($0.turn) }
    }
}
```

Then immediately fix the hard-coded fallback locales by storing `sourceLocale` and `targetLocale` as properties and using them in the interim path.

- [ ] **Step 4: Update pipeline to use assembler**

In `LiveCaptionPipeline`, replace `LiveCaptionChunker` with:

```swift
private var assembler: CaptionTurnAssembler
```

Initialize and reset it:

```swift
self.assembler = CaptionTurnAssembler(sourceLocale: sourceLocale, targetLocale: targetLocale)
```

Convert events to store updates:

```swift
private func apply(_ events: [CaptionTurnEvent]) {
    for event in events {
        switch event {
        case .draftUpdated(let turn), .sealed(let turn):
            store.upsert(turn)
        case .removed(let turnID):
            store.remove(turnID: turnID)
        }
    }
}
```

If `LiveCaptionStore` has no `remove(turnID:)`, add:

```swift
public mutating func remove(turnID: String) {
    turns.removeAll { $0.id == turnID }
}
```

- [ ] **Step 5: Run assembler and pipeline tests**

Run:

```bash
swift test --filter CaptionTurnAssemblerTests
swift test --filter LiveCaptionPipelineTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/MeetingAgentCore/CaptionTurnAssembler.swift Sources/MeetingAgentCore/LiveCaptionPipeline.swift Sources/MeetingAgentCore/LiveMeetingCockpit.swift Tests/MeetingAgentCoreTests/CaptionTurnAssemblerTests.swift
git commit -m "refactor: introduce caption turn assembler"
```

## Task 4: Add Deepgram Interim Draft Handling

**Files:**
- Modify: `Sources/MeetingAgentCore/CaptionTurnAssembler.swift`
- Modify: `Sources/MeetingAgentCore/LiveCaptionPipeline.swift`
- Test: `Tests/MeetingAgentCoreTests/CaptionTurnAssemblerTests.swift`
- Test: `Tests/MeetingAgentCoreTests/LiveCaptionPipelineTests.swift`

- [ ] **Step 1: Write interim replacement tests**

Add to `CaptionTurnAssemblerTests`:

```swift
func testInterimUpdatesReplaceDraftForSameSegmentID() {
    var assembler = CaptionTurnAssembler(sourceLocale: "en-US", targetLocale: "zh-CN")
    _ = assembler.apply(TranscriptSegment(
        id: "deepgram-transcribe-stream-0.0",
        speaker: TranscriptSpeaker(identifier: "deepgram-speaker-0"),
        text: "We should",
        language: "en-US",
        sourceProvider: "deepgram-transcribe",
        isFinal: false
    ))

    let events = assembler.apply(TranscriptSegment(
        id: "deepgram-transcribe-stream-0.0",
        speaker: TranscriptSpeaker(identifier: "deepgram-speaker-0"),
        text: "We should decide",
        language: "en-US",
        sourceProvider: "deepgram-transcribe",
        isFinal: false
    ))

    XCTAssertEqual(events.count, 1)
    guard case .draftUpdated(let draft) = events[0] else {
        return XCTFail("Expected draft update")
    }
    XCTAssertEqual(draft.originalText, "We should decide")
    XCTAssertEqual(draft.sourceSegmentIDs, ["deepgram-transcribe-stream-0.0"])
    XCTAssertEqual(draft.displayState, .draft)
}

func testFinalReplacesMatchingInterimDraft() {
    var assembler = CaptionTurnAssembler(sourceLocale: "en-US", targetLocale: "zh-CN")
    _ = assembler.apply(TranscriptSegment(
        id: "deepgram-transcribe-stream-0.0",
        speaker: TranscriptSpeaker(identifier: "deepgram-speaker-0"),
        startTimeSeconds: 0,
        endTimeSeconds: 1,
        text: "We should decide",
        language: "en-US",
        sourceProvider: "deepgram-transcribe",
        isFinal: false,
        timingSource: .precise
    ))

    let events = assembler.apply(TranscriptSegment(
        id: "deepgram-transcribe-stream-0.0",
        speaker: TranscriptSpeaker(identifier: "deepgram-speaker-0"),
        startTimeSeconds: 0,
        endTimeSeconds: 1,
        text: "We should decide today.",
        language: "en-US",
        sourceProvider: "deepgram-transcribe",
        isFinal: true,
        speechFinal: true,
        timingSource: .precise
    ))

    guard case .sealed(let sealed) = events.last else {
        return XCTFail("Expected hard sealed final turn")
    }
    XCTAssertEqual(sealed.originalText, "We should decide today.")
    XCTAssertEqual(sealed.sourceSegmentIDs, ["deepgram-transcribe-stream-0.0"])
    XCTAssertEqual(sealed.boundaryStrength, .hard)
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
swift test --filter CaptionTurnAssemblerTests/testInterimUpdatesReplaceDraftForSameSegmentID
swift test --filter CaptionTurnAssemblerTests/testFinalReplacesMatchingInterimDraft
```

Expected: at least one failure because interim state is not yet preserved and final replacement is incomplete.

- [ ] **Step 3: Implement open draft state**

In `CaptionTurnAssembler`, replace the interim stub with explicit state:

```swift
private var openDraftsBySegmentID: [String: LiveCaptionTurn] = [:]
private var openDraftOrder: [String] = []
private let sourceLocale: String
private let targetLocale: String
```

When applying an interim:

```swift
private mutating func applyInterim(_ segment: TranscriptSegment) -> [CaptionTurnEvent] {
    let previous = openDraftsBySegmentID[segment.id]
    let turn = LiveCaptionTurn(
        id: previous?.id ?? segment.id,
        sourceSegmentID: segment.id,
        sourceSegmentIDs: [segment.id],
        speaker: segment.speaker,
        originalText: segment.text,
        translatedText: previous?.translatedText,
        sourceLocale: segment.language ?? sourceLocale,
        targetLocale: targetLocale,
        isFinal: false,
        captionHealth: .live,
        translationHealth: .pending,
        createdAt: previous?.createdAt ?? segment.createdAt,
        chunkState: .draft,
        translationRevision: (previous?.translationRevision ?? 0) + 1,
        displayState: .draft,
        translationState: .draft,
        boundaryReason: nil,
        boundaryStrength: nil
    )
    if previous == nil {
        openDraftOrder.append(segment.id)
    }
    openDraftsBySegmentID[segment.id] = turn
    return [.draftUpdated(turn)]
}
```

When applying a final segment with the same ID, remove the matching draft before sending to final chunk logic:

```swift
private mutating func applyFinal(_ segment: TranscriptSegment) -> [CaptionTurnEvent] {
    openDraftsBySegmentID.removeValue(forKey: segment.id)
    openDraftOrder.removeAll { $0 == segment.id }
    return chunker.append(segment).map { update in
        update.turn.displayState == .sealed ? .sealed(update.turn) : .draftUpdated(update.turn)
    }
}
```

Dispatch:

```swift
public mutating func apply(_ segment: TranscriptSegment) -> [CaptionTurnEvent] {
    segment.isFinal ? applyFinal(segment) : applyInterim(segment)
}
```

- [ ] **Step 4: Run interim tests**

Run:

```bash
swift test --filter CaptionTurnAssemblerTests/testInterimUpdatesReplaceDraftForSameSegmentID
swift test --filter CaptionTurnAssemblerTests/testFinalReplacesMatchingInterimDraft
```

Expected: PASS.

- [ ] **Step 5: Add pipeline test for applying accumulation result**

Add to `LiveCaptionPipelineTests`:

```swift
func testApplyUsesChangedInterimSegmentsWithoutReloadingFiles() async {
    let pipeline = LiveCaptionPipeline(
        sourceLocale: "en-US",
        targetLocale: "zh-CN",
        translationProvider: nil,
        performanceEventLogger: nil
    )
    let segment = TranscriptSegment(
        id: "deepgram-transcribe-stream-0.0",
        text: "Live interim",
        language: "en-US",
        sourceProvider: "deepgram-transcribe",
        isFinal: false
    )
    let result = TranscriptSegmentAccumulationResult(
        document: TranscriptDocument(segments: [segment]),
        changedSegmentIDs: [segment.id],
        plainTextReplacement: nil
    )

    let snapshot = await pipeline.apply(result)

    XCTAssertEqual(snapshot.turns.count, 1)
    XCTAssertEqual(snapshot.turns[0].originalText, "Live interim")
    XCTAssertEqual(snapshot.turns[0].displayState, .draft)
}
```

- [ ] **Step 6: Implement incremental `apply` in pipeline**

Change `LiveCaptionPipeline.apply(_:)` so it applies only changed segments when possible:

```swift
public func apply(_ result: TranscriptSegmentAccumulationResult) async -> LiveCaptionPipelineSnapshot {
    if result.plainTextReplacement != nil {
        reset(sourceLocale: store.sourceLocale, targetLocale: store.targetLocale)
        return snapshot(captionHealth: .failed(result.plainTextReplacement ?? "Transcription failed"))
    }

    let currentSegmentIDs = Set(result.document.segments.map(\.id))
    applyEvents(assembler.removeSegments(notIn: currentSegmentIDs))

    for segment in result.document.segments where result.changedSegmentIDs.contains(segment.id) {
        applyEvents(assembler.apply(segment))
    }

    return snapshot(captionHealth: store.turns.isEmpty ? .idle : .live)
}
```

Add helper:

```swift
private func snapshot(captionHealth: LivePipelineHealth? = nil) -> LiveCaptionPipelineSnapshot {
    LiveCaptionPipelineSnapshot(
        turns: store.turns,
        captionHealth: captionHealth ?? (store.turns.isEmpty ? .idle : .live),
        translationHealth: .idle
    )
}
```

- [ ] **Step 7: Run tests**

Run:

```bash
swift test --filter CaptionTurnAssemblerTests
swift test --filter LiveCaptionPipelineTests
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/MeetingAgentCore/CaptionTurnAssembler.swift Sources/MeetingAgentCore/LiveCaptionPipeline.swift Tests/MeetingAgentCoreTests/CaptionTurnAssemblerTests.swift Tests/MeetingAgentCoreTests/LiveCaptionPipelineTests.swift
git commit -m "feat: handle deepgram interim caption drafts"
```

## Task 5: Extract CaptionTranslationScheduler

**Files:**
- Create: `Sources/MeetingAgentCore/CaptionTranslationScheduler.swift`
- Modify: `Sources/MeetingAgentCore/LiveCaptionPipeline.swift`
- Modify: `Sources/MeetingAgentCore/LiveMeetingCockpit.swift`
- Test: `Tests/MeetingAgentCoreTests/CaptionTranslationSchedulerTests.swift`

- [ ] **Step 1: Write scheduler tests for same-language and hard-final behavior**

Create `Tests/MeetingAgentCoreTests/CaptionTranslationSchedulerTests.swift`:

```swift
import XCTest
@testable import MeetingAgentCore

final class CaptionTranslationSchedulerTests: XCTestCase {
    func testSameLanguageCompletesWithoutProviderCall() async {
        let provider = RecordingTextTranslationProvider()
        var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "en-US")
        store.upsert(LiveCaptionTurn(
            sourceSegmentID: "segment-1",
            originalText: "Hello",
            sourceLocale: "en-US",
            targetLocale: "en-US",
            isFinal: true,
            chunkState: .frozen,
            displayState: .sealed,
            translationState: .final,
            boundaryReason: .speechFinal,
            boundaryStrength: .hard
        ))
        let scheduler = CaptionTranslationScheduler(provider: provider, performanceEventLogger: nil)

        await scheduler.scheduleTranslations(in: &store)

        XCTAssertEqual(provider.requests.count, 0)
        XCTAssertEqual(store.turns[0].translationHealth, .live)
    }

    func testHardSealedTurnRequestsFinalTranslation() async {
        let provider = RecordingTextTranslationProvider(translations: ["segment-1": "你好"])
        var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        store.upsert(LiveCaptionTurn(
            sourceSegmentID: "segment-1",
            originalText: "Hello",
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            isFinal: true,
            chunkState: .frozen,
            displayState: .sealed,
            translationState: .final,
            boundaryReason: .speechFinal,
            boundaryStrength: .hard
        ))
        let scheduler = CaptionTranslationScheduler(provider: provider, performanceEventLogger: nil)

        await scheduler.scheduleTranslations(in: &store)

        XCTAssertEqual(provider.requests.map(\.segments.first?.text), ["Hello"])
        XCTAssertEqual(store.turns[0].translatedText, "你好")
        XCTAssertEqual(store.turns[0].translationState, .final)
    }
}

private final class RecordingTextTranslationProvider: TextTranslationProvider {
    struct Request {
        let segments: [TranscriptSegment]
        let options: TranslationOptions
    }

    let descriptor = ProviderDescriptor(
        id: "recording-translation",
        displayName: "Recording Translation",
        capability: .textTranslation,
        executionMode: .hosted,
        supportedSourceLocales: ["*"],
        supportedTargetLocales: ["*"],
        requiresNetwork: false,
        requiresAPIKey: false
    )
    private(set) var requests: [Request] = []
    private let translations: [String: String]

    init(translations: [String: String] = [:]) {
        self.translations = translations
    }

    func translate(transcript: TranscriptDocument, options: TranslationOptions) async throws -> TranslatedTranscript {
        requests.append(Request(segments: transcript.segments, options: options))
        return TranslatedTranscript(
            sourceLocale: options.sourceLocale,
            targetLocale: options.targetLocale,
            segments: transcript.segments.map {
                BilingualSubtitleSegment(
                    id: $0.id,
                    sourceText: $0.text,
                    targetText: translations[$0.id] ?? "",
                    status: .translated
                )
            },
            provenance: PipelineProvenance(profileID: "test")
        )
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
swift test --filter CaptionTranslationSchedulerTests
```

Expected: compile failure because `CaptionTranslationScheduler` does not exist.

- [ ] **Step 3: Implement minimal scheduler**

Create `Sources/MeetingAgentCore/CaptionTranslationScheduler.swift`:

```swift
import Foundation

public final class CaptionTranslationScheduler {
    private let provider: TextTranslationProvider?
    private let performanceEventLogger: PerformanceEventLogger?
    private var finalTranslationKeysByTurnID: [String: String] = [:]

    public init(provider: TextTranslationProvider?, performanceEventLogger: PerformanceEventLogger?) {
        self.provider = provider
        self.performanceEventLogger = performanceEventLogger
    }

    public func scheduleTranslations(in store: inout LiveCaptionStore) async {
        for turn in store.turns {
            let options = TranslationOptions(sourceLocale: turn.sourceLocale, targetLocale: turn.targetLocale)
            if options.isSameLanguage {
                store.markTranslationCompleteWithoutText(forTurnID: turn.id)
                continue
            }
            guard turn.displayState == .sealed,
                  turn.boundaryStrength == .hard,
                  turn.translationHealth == .pending
            else {
                continue
            }
            let key = "\(turn.originalText)\u{1F}\(turn.sourceLocale)\u{1F}\(turn.targetLocale)"
            guard finalTranslationKeysByTurnID[turn.id] != key else { continue }
            finalTranslationKeysByTurnID[turn.id] = key
            await translateFinal(turn, in: &store)
        }
    }

    private func translateFinal(_ turn: LiveCaptionTurn, in store: inout LiveCaptionStore) async {
        guard let provider else { return }
        let segment = TranscriptSegment(
            id: turn.sourceSegmentID,
            speaker: turn.speaker,
            text: turn.originalText,
            language: turn.sourceLocale,
            isFinal: turn.isFinal,
            createdAt: turn.createdAt
        )
        do {
            let translated = try await provider.translate(
                transcript: TranscriptDocument(segments: [segment]),
                options: TranslationOptions(sourceLocale: turn.sourceLocale, targetLocale: turn.targetLocale)
            )
            let translatedText = translated.segments.first { $0.id == turn.sourceSegmentID }?.targetText ?? ""
            store.attachTranslation(translatedText, toTurnID: turn.id)
            store.markTranslationFinal(forTurnID: turn.id)
        } catch {
            let nsError = error as NSError
            store.markTranslationFailed(forTurnID: turn.id, message: "\(nsError.domain) error \(nsError.code)")
        }
    }
}
```

- [ ] **Step 4: Run scheduler tests**

Run:

```bash
swift test --filter CaptionTranslationSchedulerTests
```

Expected: PASS.

- [ ] **Step 5: Wire scheduler into LiveCaptionPipeline**

In `LiveCaptionPipeline`, add:

```swift
private let translationScheduler: CaptionTranslationScheduler
```

Initialize:

```swift
self.translationScheduler = CaptionTranslationScheduler(
    provider: translationProvider,
    performanceEventLogger: performanceEventLogger
)
```

After applying caption events in `apply`, `replay`, and `flush`, call:

```swift
await translationScheduler.scheduleTranslations(in: &store)
```

Set snapshot translation health:

```swift
private func translationHealth() -> LivePipelineHealth {
    if store.turns.isEmpty { return .idle }
    if store.turns.contains(where: {
        if case .failed = $0.translationHealth { return true }
        return false
    }) {
        return .degraded("Some caption translations failed")
    }
    if store.turns.contains(where: { $0.translationHealth == .live }) {
        return .live
    }
    if store.turns.contains(where: { $0.translationHealth == .pending }) {
        return .pending
    }
    return .idle
}
```

- [ ] **Step 6: Run pipeline and scheduler tests**

Run:

```bash
swift test --filter CaptionTranslationSchedulerTests
swift test --filter LiveCaptionPipelineTests
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/MeetingAgentCore/CaptionTranslationScheduler.swift Sources/MeetingAgentCore/LiveCaptionPipeline.swift Tests/MeetingAgentCoreTests/CaptionTranslationSchedulerTests.swift
git commit -m "refactor: extract caption translation scheduler"
```

## Task 6: Move Active Recording Caption Updates To Pipeline

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] **Step 1: Add ViewModel test for active update path**

Add a test using existing recorder fakes if present. If no suitable fake exists, add a focused test around the private path by exposing an internal test-only helper:

```swift
func testActiveTranscriptUpdatesAreAppliedThroughPipeline() async throws {
    let viewModel = MeetingAgentViewModel(
        speechConfiguration: SpeechTranscriptionConfiguration.default
    )
    let segment = TranscriptSegment(
        id: "deepgram-transcribe-stream-0.0",
        text: "Active update",
        language: "en-US",
        sourceProvider: "deepgram-transcribe",
        isFinal: false
    )
    let result = TranscriptSegmentAccumulationResult(
        document: TranscriptDocument(segments: [segment]),
        changedSegmentIDs: [segment.id],
        plainTextReplacement: nil
    )

    await viewModel.applyTranscriptAccumulationResultsForTesting([result])

    XCTAssertEqual(viewModel.liveCaptionTurns.map(\.originalText), ["Active update"])
    XCTAssertEqual(viewModel.liveCaptionTurns.first?.displayState, .draft)
}
```

Add the helper under `#if DEBUG` or as `internal` if the test target uses `@testable`:

```swift
func applyTranscriptAccumulationResultsForTesting(_ results: [TranscriptSegmentAccumulationResult]) async {
    await applyTranscriptAccumulationResultsToLiveCaptions(results)
}
```

If exposing this helper is undesirable, use existing recorder test utilities and call `drainRecordingFrames()`.

- [ ] **Step 2: Run test to verify failure or current mismatch**

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testActiveTranscriptUpdatesAreAppliedThroughPipeline
```

Expected: FAIL until ViewModel active path awaits pipeline output.

- [ ] **Step 3: Convert `applyTranscriptAccumulationResultsToLiveCaptions` to pipeline**

Change the ViewModel helper to async:

```swift
private func applyTranscriptAccumulationResultsToLiveCaptions(
    _ results: [TranscriptSegmentAccumulationResult]
) async {
    guard let latest = results.last else { return }
    let snapshot = await liveCaptionPipeline.apply(latest)
    liveCaptionTurns = snapshot.turns
    meetingProgressHealth.caption = snapshot.captionHealth
    meetingProgressHealth.translation = snapshot.translationHealth
}
```

Update `drainRecordingFrames()` where it calls the helper:

```swift
let transcriptResults = recorder.drainTranscriptUpdates()
if transcriptResults.isEmpty {
    refreshLiveCaptionTurnsFromSelectedMeeting()
} else {
    Task { [weak self, transcriptResults] in
        await self?.applyTranscriptAccumulationResultsToLiveCaptions(transcriptResults)
    }
}
```

If async scheduling causes tests to race, use `Task { @MainActor ... }` and update tests to await the helper directly.

- [ ] **Step 4: Remove duplicate scheduling call from ViewModel active path**

Delete this call from `applyTranscriptDocumentToLiveCaptions` after it is no longer used for active incremental updates:

```swift
scheduleCaptionTextTranslationIfNeeded()
```

Keep it only until the scheduler is fully wired into `LiveCaptionPipeline`. After Task 5, the pipeline owns translation scheduling.

- [ ] **Step 5: Run active path tests**

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testActiveTranscriptUpdatesAreAppliedThroughPipeline
swift test --filter LiveCaptionPipelineTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/MeetingAgentCore/MeetingAgentViewModel.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift
git commit -m "refactor: apply active captions through pipeline"
```

## Task 7: Remove Migrated ViewModel Caption State

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Modify: `Sources/MeetingAgentCore/LiveCaptionPipeline.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`
- Test: `Tests/MeetingAgentCoreTests/LiveCaptionPipelineTests.swift`

- [ ] **Step 1: Confirm no tests depend on private ViewModel translation helpers**

Run:

```bash
rg -n "scheduleCaptionTextTranslationIfNeeded|draftTranslation|captionTranslationTasks|LiveCaptionChunker|processedLiveCaptionSegmentSignaturesByID" Tests Sources/MeetingAgentCore
```

Expected: references remain in `MeetingAgentViewModel.swift` before cleanup and should be absent from tests, except tests that intentionally verify old behavior.

- [ ] **Step 2: Delete migrated ViewModel properties**

Remove these properties from `MeetingAgentViewModel` after their behavior is covered by `LiveCaptionPipeline` and `CaptionTranslationScheduler`:

```swift
private var liveCaptionStore = LiveCaptionStore()
private var liveCaptionChunker = LiveCaptionChunker(sourceLocale: "en-US", targetLocale: "zh-CN")
private var processedLiveCaptionSegmentSignaturesByID: [String: String] = [:]
private var draftTranslationKeysByTurnID: [String: String] = [:]
private var draftTranslationInFlightByTurnID: [String: Int] = [:]
private var draftTranslationTasksByTurnID: [String: Task<Void, Never>] = [:]
private var captionTranslationTasksByRequestID: [String: Task<Void, Never>] = [:]
private var pendingDraftTranslationRequestsByTurnID: [String: CaptionTranslationRequest] = [:]
private var pendingFinalTranslationRequestsByTurnID: [String: CaptionTranslationRequest] = [:]
private var activeCaptionTranslationRequestIDs = Set<String>()
private var activeDraftTranslationRequestIDs = Set<String>()
private var activeDraftTranslationRequestIDsByTurnID: [String: String] = [:]
private var activeDraftTranslationRequestsByTurnID: [String: CaptionTranslationRequest] = [:]
private var draftTranslationCharacterCountsByTurnID: [String: Int] = [:]
private var draftTranslationAttemptDatesByTurnID: [String: Date] = [:]
private var finalTranslationKeysByTurnID: [String: String] = [:]
private var finalTranslationInFlightTurnIDs = Set<String>()
private let minDraftTranslationCharacterDelta = 80
private let minDraftTranslationInterval: TimeInterval = 2
private let maxConcurrentCaptionTranslations = 2
private let maxConcurrentDraftCaptionTranslations = 1
```

Remove `CaptionTranslationRequest` from `MeetingAgentViewModel.swift` if it moved into `CaptionTranslationScheduler.swift`.

- [ ] **Step 3: Delete migrated ViewModel methods**

Remove private methods once equivalent behavior exists in pipeline/scheduler:

```swift
applyTranscriptDocumentToLiveCaptions(_:)
applyFinalLiveCaptionSegment(_:)
applyInterimLiveCaptionSegment(_:)
markProcessedLiveCaptionSegmentIfNeeded(_:)
freezeOpenLiveCaptionChunk(reason:)
logCaptionTurnUpdate(_:metadata:)
scheduleCaptionTextTranslationIfNeeded()
completeSameLanguageCaptionTranslationsIfNeeded()
shouldScheduleDraftTranslation(for:)
shouldTranslateDraftCaption(_:now:)
isDraftTranslationSupersededByHardFinal(_:finalCandidates:)
pumpCaptionTranslationQueue(using:)
nextPendingFinalTranslationRequest()
nextPendingDraftTranslationRequest()
startCaptionTranslationRequest(_:using:)
translateCaptionTurn(_:using:)
```

Keep `currentPerformanceEventLogger()` if the pipeline factory uses it.

- [ ] **Step 4: Rebuild and fix compile errors by moving missing helpers**

Run:

```bash
swift build --product MeetingAgentApp
```

Expected: compile errors for helpers not yet moved. Move required generic helpers into `CaptionTranslationScheduler` or `LiveCaptionPipeline`, preserving names where tests already reference behavior.

- [ ] **Step 5: Run focused tests**

Run:

```bash
swift test --filter LiveCaptionPipelineTests
swift test --filter CaptionTranslationSchedulerTests
swift test --filter MeetingAgentViewModelTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/MeetingAgentCore/MeetingAgentViewModel.swift Sources/MeetingAgentCore/LiveCaptionPipeline.swift Sources/MeetingAgentCore/CaptionTranslationScheduler.swift Tests/MeetingAgentCoreTests
git commit -m "refactor: remove viewmodel caption pipeline state"
```

## Task 8: Full Verification

**Files:**
- No planned source edits unless verification finds a defect.

- [ ] **Step 1: Run the required unit test entrypoint**

Run:

```bash
make test
```

Expected: PASS.

- [ ] **Step 2: Build the app product**

Run:

```bash
swift build --product MeetingAgentApp
```

Expected: PASS.

- [ ] **Step 3: Check working tree**

Run:

```bash
git status --short
```

Expected: only intentional source/test/doc changes are present. The pre-existing untracked `.env` may remain and must not be committed.

- [ ] **Step 4: Commit verification fixes if needed**

If verification required code fixes:

```bash
git add Sources/MeetingAgentCore Tests/MeetingAgentCoreTests
git commit -m "fix: stabilize deepgram caption pipeline"
```

If no fixes were needed, do not create an empty commit.

## Self-Review

- Spec coverage: Tasks cover `LiveCaptionPipeline`, `CaptionTurnAssembler`, `CaptionTranslationScheduler`, Deepgram interim/final handling, ViewModel cleanup, active in-memory updates, historical replay, and provider boundary preservation.
- Scope: The plan does not tune Whisper or OpenAI Realtime. They remain provider adapters behind `TranscriptSegmentUpdate`.
- Placeholder scan: The plan contains concrete file paths, test commands, expected outcomes, and code snippets for each new type.
- Type consistency: The plan uses existing project types where possible: `LiveCaptionTurn`, `LiveCaptionStore`, `LivePipelineHealth`, `LiveCaptionFreezeReason`, `TranscriptSegmentAccumulationResult`, `TextTranslationProvider`, and `TranslationOptions`.
