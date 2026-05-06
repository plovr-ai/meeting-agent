# Translation Runtime Finalization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete the new unit-based active-recording translation path and reduce `CaptionTranslationScheduler` to an explicit legacy replay/backfill role.

**Architecture:** Add `TranslationRuntime` as the lifecycle boundary around `TranslationExperiencePipeline`. `MeetingAgentViewModel` feeds transcript documents into the runtime and only attaches returned visible results, while `LiveCaptionPipeline` exposes legacy replay/backfill naming and guards old scheduler usage outside active recording.

**Tech Stack:** Swift 5.9, Swift Concurrency, XCTest, existing `TranslationExperiencePipeline`, `LiveCaptionPipeline`, `PerformanceEventLogger`, and `TranslationResultPersistenceStore`.

---

## File Map

- Create `Sources/MeetingAgentCore/TranslationRuntime.swift`
  - Own active translation lifecycle, generation checks, stop state, dropped preview telemetry, and persistence callback construction.
- Create `Tests/MeetingAgentCoreTests/TranslationRuntimeTests.swift`
  - Cover generation mismatch, stop finalization, late preview drop behavior, and hydration priority.
- Modify `Sources/MeetingAgentCore/TranslationExperiencePipeline.swift`
  - Add injectable schedulers/clock hooks only where tests require them; keep provider-facing public initializer intact.
- Modify `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
  - Replace direct `translationExperiencePipeline` lifecycle management with `TranslationRuntime`.
- Modify `Sources/MeetingAgentCore/LiveCaptionPipeline.swift`
  - Rename active call sites and mode cases so legacy scheduler is visibly replay/backfill only.
- Modify `Sources/MeetingAgentCore/RealtimeCaptionSession.swift`
  - Keep thin forwarding API, adding timestamped attach if runtime needs deterministic tests.
- Modify `scripts/analyze-meeting-performance.swift`
  - Distinguish dropped live previews from published post-stop preview events.
- Modify existing tests:
  - `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`
  - `Tests/MeetingAgentCoreTests/LiveCaptionPipelineTests.swift`
  - `Tests/MeetingAgentCoreTests/MeetingPerformanceAnalysisScriptTests.swift`

---

### Task 1: Add TranslationRuntime Model And Hydration Surface

**Files:**
- Create: `Sources/MeetingAgentCore/TranslationRuntime.swift`
- Test: `Tests/MeetingAgentCoreTests/TranslationRuntimeTests.swift`

- [ ] **Step 1: Write failing tests for runtime start and hydration**

Add this file:

```swift
import XCTest
@testable import MeetingAgentCore

final class TranslationRuntimeTests: XCTestCase {
    func testHydrateReturnsStableResultsFromPersistenceRecords() {
        let meetingID = UUID(uuidString: "00000000-0000-0000-0000-000000000111")!
        let lane = TranslationLaneID(speaker: .default, sourceLocale: "en-US", targetLocale: "zh-CN")
        let record = TranslationResultPersistenceRecord(
            meetingID: meetingID,
            resultID: "stable-1",
            sourceID: "block-1",
            laneID: lane,
            sourceSegmentIDs: ["segment-1"],
            sourceTextHash: "hash",
            sourceText: "We approve the rollout.",
            translatedText: "我们批准上线。",
            displayState: .stableFinal,
            boundaryReason: .providerHardBoundary,
            providerID: "test",
            createdAt: Date(timeIntervalSince1970: 1),
            finalizedAt: Date(timeIntervalSince1970: 2)
        )

        var runtime = TranslationRuntime()
        let hydrated = runtime.hydrate(records: [record])

        XCTAssertEqual(hydrated.map(\.id), ["stable-1"])
        XCTAssertEqual(hydrated.first?.displayState, .stableFinal)
        XCTAssertEqual(hydrated.first?.sourceSegmentIDs, ["segment-1"])
    }

    func testApplyWithoutStartedContextReturnsIdleSnapshot() async {
        var runtime = TranslationRuntime()

        let snapshot = await runtime.apply(
            document: TranscriptDocument(segments: [
                TranscriptSegment(id: "segment-1", text: "We approve the rollout today", language: "en-US", isFinal: false)
            ]),
            generation: 1,
            now: Date(timeIntervalSince1970: 1)
        )

        XCTAssertTrue(snapshot.visibleResults.isEmpty)
        XCTAssertTrue(snapshot.droppedResults.isEmpty)
        XCTAssertEqual(snapshot.state, .idle)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
swift test --filter TranslationRuntimeTests
```

Expected: fails because `TranslationRuntime`, `TranslationRuntimeSnapshot`, and runtime state types do not exist.

- [ ] **Step 3: Add minimal runtime types**

Create `Sources/MeetingAgentCore/TranslationRuntime.swift`:

```swift
import Foundation

public enum TranslationRuntimeState: Equatable {
    case idle
    case active
    case stopping
    case stopped
}

public struct TranslationRuntimeContext: Equatable {
    public var meetingID: UUID
    public var sourceLocale: String
    public var targetLocale: String
    public var generation: Int

    public init(
        meetingID: UUID,
        sourceLocale: String,
        targetLocale: String,
        generation: Int
    ) {
        self.meetingID = meetingID
        self.sourceLocale = sourceLocale
        self.targetLocale = targetLocale
        self.generation = generation
    }
}

public struct TranslationRuntimeSnapshot: Equatable {
    public var state: TranslationRuntimeState
    public var liveResults: [TranslationResult]
    public var stableResults: [TranslationResult]
    public var visibleResults: [TranslationResult]
    public var droppedResults: [TranslationResult]

    public init(
        state: TranslationRuntimeState,
        liveResults: [TranslationResult] = [],
        stableResults: [TranslationResult] = [],
        visibleResults: [TranslationResult] = [],
        droppedResults: [TranslationResult] = []
    ) {
        self.state = state
        self.liveResults = liveResults
        self.stableResults = stableResults
        self.visibleResults = visibleResults
        self.droppedResults = droppedResults
    }
}

public struct TranslationRuntime {
    private var context: TranslationRuntimeContext?
    private var state: TranslationRuntimeState = .idle
    private var hydratedStore = TranslationResultStore()

    public init() {}

    public mutating func start(context: TranslationRuntimeContext) {
        self.context = context
        state = .active
    }

    public mutating func apply(
        document: TranscriptDocument,
        generation: Int,
        now: Date = Date()
    ) async -> TranslationRuntimeSnapshot {
        guard context != nil else {
            return TranslationRuntimeSnapshot(state: .idle)
        }
        return TranslationRuntimeSnapshot(state: state)
    }

    public mutating func hydrate(records: [TranslationResultPersistenceRecord]) -> [TranslationResult] {
        hydratedStore.hydrate(from: records)
        return hydratedStore.stableResults()
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run:

```bash
swift test --filter TranslationRuntimeTests
```

Expected: `TranslationRuntimeTests` pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingAgentCore/TranslationRuntime.swift Tests/MeetingAgentCoreTests/TranslationRuntimeTests.swift
git commit -m "feat: add translation runtime boundary"
```

---

### Task 2: Route Runtime Apply Through TranslationExperiencePipeline

**Files:**
- Modify: `Sources/MeetingAgentCore/TranslationRuntime.swift`
- Modify: `Sources/MeetingAgentCore/TranslationExperiencePipeline.swift`
- Test: `Tests/MeetingAgentCoreTests/TranslationRuntimeTests.swift`

- [ ] **Step 1: Add failing apply test**

Append this test to `TranslationRuntimeTests`:

```swift
func testApplyUsesUnitPipelineAndReturnsVisibleLiveResult() async {
    let provider = RuntimeTranslationProvider(translations: ["segment-1-live-1": "我们确认负责人"])
    var persisted: [TranslationResultPersistenceRecord] = []
    var runtime = TranslationRuntime()
    runtime.start(
        context: TranslationRuntimeContext(
            meetingID: UUID(uuidString: "00000000-0000-0000-0000-000000000222")!,
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            generation: 1
        ),
        liveProvider: provider,
        accurateProvider: provider,
        performanceEventLogger: nil,
        persistFinalResult: { persisted.append($0) }
    )

    let snapshot = await runtime.apply(
        document: TranscriptDocument(segments: [
            TranscriptSegment(
                id: "segment-1",
                text: "We should confirm the launch owner today",
                language: "en-US",
                isFinal: false,
                createdAt: Date(timeIntervalSince1970: 1)
            )
        ]),
        generation: 1,
        now: Date(timeIntervalSince1970: 2)
    )

    XCTAssertEqual(snapshot.state, .active)
    XCTAssertEqual(snapshot.liveResults.count, 1)
    XCTAssertEqual(snapshot.visibleResults.first?.translatedText, "我们确认负责人")
    XCTAssertTrue(persisted.isEmpty)
}
```

Add this helper to the same test file:

```swift
private final class RuntimeTranslationProvider: TextTranslationProvider {
    let translations: [String: String]
    private(set) var requestIDs: [String] = []

    init(translations: [String: String]) {
        self.translations = translations
    }

    var descriptor: ProviderDescriptor {
        ProviderDescriptor(
            id: "runtime-test",
            displayName: "Runtime Test",
            capability: .textTranslation,
            executionMode: .hosted,
            supportedSourceLocales: ["*"],
            supportedTargetLocales: ["*"],
            requiresNetwork: false,
            requiresAPIKey: false
        )
    }

    func translate(transcript: TranscriptDocument, options: TranslationOptions) async throws -> TranslatedTranscript {
        let segment = transcript.segments[0]
        requestIDs.append(segment.id)
        return TranslatedTranscript(
            sourceLocale: options.sourceLocale,
            targetLocale: options.targetLocale,
            segments: [
                BilingualSubtitleSegment(
                    id: segment.id,
                    sourceText: segment.text,
                    targetText: translations[segment.id] ?? "translated \(segment.text)"
                )
            ],
            provenance: PipelineProvenance(profileID: "runtime-test", successfulProviders: ["runtime-test"])
        )
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
swift test --filter TranslationRuntimeTests/testApplyUsesUnitPipelineAndReturnsVisibleLiveResult
```

Expected: fails because `TranslationRuntime.start` does not accept providers and `apply` does not run the unit pipeline.

- [ ] **Step 3: Implement provider-backed runtime start/apply**

Update `TranslationRuntime`:

```swift
public struct TranslationRuntime {
    private var context: TranslationRuntimeContext?
    private var state: TranslationRuntimeState = .idle
    private var pipeline: TranslationExperiencePipeline?
    private var hydratedStore = TranslationResultStore()
    private var performanceEventLogger: PerformanceEventLogger?

    public init() {}

    public mutating func start(
        context: TranslationRuntimeContext,
        liveProvider: TextTranslationProvider,
        accurateProvider: TextTranslationProvider,
        performanceEventLogger: PerformanceEventLogger? = nil,
        persistFinalResult: ((TranslationResultPersistenceRecord) -> Void)? = nil
    ) {
        self.context = context
        self.performanceEventLogger = performanceEventLogger
        self.pipeline = TranslationExperiencePipeline(
            meetingID: context.meetingID,
            sourceLocale: context.sourceLocale,
            targetLocale: context.targetLocale,
            liveProvider: liveProvider,
            accurateProvider: accurateProvider,
            performanceEventLogger: performanceEventLogger,
            persistFinalResult: persistFinalResult
        )
        state = .active
    }

    public mutating func start(context: TranslationRuntimeContext) {
        self.context = context
        state = .active
    }

    public mutating func apply(
        document: TranscriptDocument,
        generation: Int,
        now: Date = Date()
    ) async -> TranslationRuntimeSnapshot {
        guard let context, state == .active else {
            return TranslationRuntimeSnapshot(state: state)
        }
        guard context.generation == generation else {
            logSnapshot(path: "stale_generation", liveCount: 0, stableCount: 0, visibleCount: 0, droppedCount: 0)
            return TranslationRuntimeSnapshot(state: state)
        }
        guard var pipeline else {
            return TranslationRuntimeSnapshot(state: state)
        }
        let pipelineSnapshot = await pipeline.apply(segments: document.segments, now: now)
        self.pipeline = pipeline
        let snapshot = TranslationRuntimeSnapshot(
            state: state,
            liveResults: pipelineSnapshot.liveResults,
            stableResults: pipelineSnapshot.stableResults,
            visibleResults: pipelineSnapshot.visibleResults
        )
        logSnapshot(
            path: "realtime",
            liveCount: snapshot.liveResults.count,
            stableCount: snapshot.stableResults.count,
            visibleCount: snapshot.visibleResults.count,
            droppedCount: snapshot.droppedResults.count
        )
        return snapshot
    }

    private func logSnapshot(
        path: String,
        liveCount: Int,
        stableCount: Int,
        visibleCount: Int,
        droppedCount: Int
    ) {
        performanceEventLogger?.log(
            "translation_runtime_snapshot",
            metadata: [
                "path": path,
                "state": "\(state)",
                "liveResultCount": String(liveCount),
                "stableResultCount": String(stableCount),
                "visibleResultCount": String(visibleCount),
                "droppedResultCount": String(droppedCount)
            ]
        )
    }
}
```

- [ ] **Step 4: Run tests**

Run:

```bash
swift test --filter TranslationRuntimeTests
swift test --filter TranslationExperiencePipelineTests
```

Expected: both suites pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingAgentCore/TranslationRuntime.swift Sources/MeetingAgentCore/TranslationExperiencePipeline.swift Tests/MeetingAgentCoreTests/TranslationRuntimeTests.swift
git commit -m "feat: route translation runtime through unit pipeline"
```

---

### Task 3: Add Stop Finalization And Late Preview Drop Semantics

**Files:**
- Modify: `Sources/MeetingAgentCore/TranslationRuntime.swift`
- Modify: `scripts/analyze-meeting-performance.swift`
- Test: `Tests/MeetingAgentCoreTests/TranslationRuntimeTests.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingPerformanceAnalysisScriptTests.swift`

- [ ] **Step 1: Add failing stop finalization test**

Append this test:

```swift
func testStopAndFinalizePublishesOnlyStableFinalAndPersistsIt() async {
    let provider = RuntimeTranslationProvider(translations: ["stable-expected": "我们会复查上线状态。"])
    var persisted: [TranslationResultPersistenceRecord] = []
    var runtime = TranslationRuntime()
    runtime.start(
        context: TranslationRuntimeContext(
            meetingID: UUID(uuidString: "00000000-0000-0000-0000-000000000333")!,
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            generation: 7
        ),
        liveProvider: provider,
        accurateProvider: provider,
        performanceEventLogger: nil,
        persistFinalResult: { persisted.append($0) }
    )
    _ = await runtime.apply(
        document: TranscriptDocument(segments: [
            TranscriptSegment(
                id: "segment-1",
                text: "We should review the rollout status",
                language: "en-US",
                isFinal: true,
                speechFinal: false,
                createdAt: Date(timeIntervalSince1970: 1)
            )
        ]),
        generation: 7,
        now: Date(timeIntervalSince1970: 2)
    )

    let snapshot = await runtime.stopAndFinalize(generation: 7, now: Date(timeIntervalSince1970: 3))

    XCTAssertEqual(snapshot.state, .stopped)
    XCTAssertTrue(snapshot.liveResults.isEmpty)
    XCTAssertEqual(snapshot.stableResults.count, 1)
    XCTAssertEqual(snapshot.visibleResults.first?.displayState, .stableFinal)
    XCTAssertEqual(persisted.count, 1)
    XCTAssertEqual(persisted.first?.sourceSegmentIDs, ["segment-1"])
}
```

- [ ] **Step 2: Add failing late-preview telemetry test**

Append this test:

```swift
func testLatePreviewAfterStopIsDroppedAndLogged() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("translation-runtime-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let logger = PerformanceEventLogger(url: root.appendingPathComponent("performance-events.jsonl"))
    let provider = RuntimeTranslationProvider(translations: ["segment-1-live-1": "我们确认负责人"])
    var runtime = TranslationRuntime()
    runtime.start(
        context: TranslationRuntimeContext(
            meetingID: UUID(uuidString: "00000000-0000-0000-0000-000000000444")!,
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            generation: 3
        ),
        liveProvider: provider,
        accurateProvider: provider,
        performanceEventLogger: logger
    )

    _ = await runtime.stopAndFinalize(generation: 3, now: Date(timeIntervalSince1970: 4))
    let snapshot = await runtime.apply(
        document: TranscriptDocument(segments: [
            TranscriptSegment(id: "segment-1", text: "We should confirm the launch owner today", language: "en-US", isFinal: false)
        ]),
        generation: 3,
        now: Date(timeIntervalSince1970: 5)
    )

    let events = try String(contentsOf: root.appendingPathComponent("performance-events.jsonl"), encoding: .utf8)
        .split(separator: "\n")
        .map { try JSONDecoder.meetingAgent.decode(PerformanceEvent.self, from: Data($0.utf8)) }
    XCTAssertTrue(snapshot.visibleResults.isEmpty)
    XCTAssertTrue(events.contains { $0.event == "translation_unit_live_dropped_after_stop" })
}
```

- [ ] **Step 3: Run tests to verify failure**

Run:

```bash
swift test --filter TranslationRuntimeTests/testStopAndFinalizePublishesOnlyStableFinalAndPersistsIt
swift test --filter TranslationRuntimeTests/testLatePreviewAfterStopIsDroppedAndLogged
```

Expected: fails because `stopAndFinalize` and drop telemetry do not exist.

- [ ] **Step 4: Implement stop and drop behavior**

Add to `TranslationRuntime`:

```swift
public mutating func stopAndFinalize(
    generation: Int,
    now: Date = Date()
) async -> TranslationRuntimeSnapshot {
    guard let context, context.generation == generation else {
        return TranslationRuntimeSnapshot(state: state)
    }
    state = .stopping
    guard var pipeline else {
        state = .stopped
        return TranslationRuntimeSnapshot(state: state)
    }
    let pipelineSnapshot = await pipeline.flushAndFinalize(now: now)
    self.pipeline = pipeline
    state = .stopped
    let visibleFinals = pipelineSnapshot.visibleResults.filter { $0.displayState == .stableFinal }
    let snapshot = TranslationRuntimeSnapshot(
        state: state,
        liveResults: [],
        stableResults: pipelineSnapshot.stableResults,
        visibleResults: visibleFinals
    )
    logSnapshot(
        path: "stop",
        liveCount: 0,
        stableCount: snapshot.stableResults.count,
        visibleCount: snapshot.visibleResults.count,
        droppedCount: 0
    )
    return snapshot
}
```

Update `apply` early guard:

```swift
guard state == .active else {
    let dropped = syntheticDroppedPreviewResults(from: document, now: now)
    for result in dropped {
        logDroppedAfterStop(result)
    }
    return TranslationRuntimeSnapshot(
        state: state,
        visibleResults: [],
        droppedResults: dropped
    )
}
```

Add helpers:

```swift
private func syntheticDroppedPreviewResults(
    from document: TranscriptDocument,
    now: Date
) -> [TranslationResult] {
    document.segments
        .filter { !$0.isFinal }
        .map { segment in
            let lane = TranslationLaneID(
                speaker: segment.speaker,
                sourceLocale: segment.language ?? context?.sourceLocale ?? "",
                targetLocale: context?.targetLocale ?? ""
            )
            return TranslationResult(
                id: "\(segment.id)-dropped-after-stop",
                sourceID: segment.id,
                laneID: lane,
                sourceText: segment.text,
                translatedText: "",
                displayState: .failedRecoverable,
                createdAt: now,
                sourceCreatedAt: segment.createdAt,
                sourceSegmentIDs: [segment.id]
            )
        }
}

private func logDroppedAfterStop(_ result: TranslationResult) {
    performanceEventLogger?.log(
        "translation_unit_live_dropped_after_stop",
        segmentID: result.sourceID,
        isFinal: false,
        textLength: result.sourceText.count,
        metadata: [
            "translationKind": "live",
            "translationState": result.displayState.rawValue,
            "resultID": result.id,
            "sourceSegmentIDs": result.sourceSegmentIDs.joined(separator: ",")
        ]
    )
}
```

- [ ] **Step 5: Update performance analyzer for dropped previews**

In `scripts/analyze-meeting-performance.swift`, update the Unit Translation Pipeline section to include:

```swift
lines.append("Live Unit Dropped After Stop Count: \(allUnitEvents("translation_unit_live_dropped_after_stop").count)")
```

Update `postStopUnitTranslationEvents()` so dropped previews are counted separately from visible post-stop publication:

```swift
private func postStopUnitTranslationEvents() -> [PerformanceEvent] {
    guard let recordingStoppedAt else { return [] }
    return allEvents.filter {
        $0.wallTime > recordingStoppedAt && $0.event.hasPrefix("translation_unit_")
    }
}
```

Extend `testAnalyzeMeetingPerformanceScriptReportsUnitTranslationPipelineMetrics` with expected output:

```swift
XCTAssertTrue(output.stdout.contains("Live Unit Dropped After Stop Count: 1"))
```

- [ ] **Step 6: Run tests**

Run:

```bash
swift test --filter TranslationRuntimeTests
swift test --filter MeetingPerformanceAnalysisScriptTests/testAnalyzeMeetingPerformanceScriptReportsUnitTranslationPipelineMetrics
```

Expected: all selected tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/MeetingAgentCore/TranslationRuntime.swift scripts/analyze-meeting-performance.swift Tests/MeetingAgentCoreTests/TranslationRuntimeTests.swift Tests/MeetingAgentCoreTests/MeetingPerformanceAnalysisScriptTests.swift
git commit -m "feat: finalize translation runtime on stop"
```

---

### Task 4: Move MeetingAgentViewModel Active Translation Lifecycle To Runtime

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Modify: `Sources/MeetingAgentCore/RealtimeCaptionSession.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] **Step 1: Add failing active-recording runtime test**

Add this test to `MeetingAgentViewModelTests` near the existing translation overlay tests:

```swift
func testActiveRecordingUnitTranslationUsesRuntimeAndPublishesOverlay() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("runtime-view-model-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try MeetingStore(rootDirectory: root)
    let provider = ViewModelFakeTextTranslationProvider(translations: [
        "deepgram-transcribe-stream-0.0-live-1": "我们确认负责人"
    ])
    let recorder = FakeMeetingRecorder(store: store)
    let viewModel = MeetingAgentViewModel(
        store: store,
        recorder: recorder,
        speechLocaleIdentifier: "en-US",
        speechProvider: .deepgram,
        speechConfiguration: SpeechTranscriptionConfiguration(
            provider: .deepgram,
            localeIdentifier: "en-US",
            targetLocaleIdentifier: "zh-CN"
        ),
        captionTranslationProviderFactory: { provider },
        liveCaptionSnapshotDebounceNanoseconds: 0,
        draftCaptionInputThrottleNanoseconds: 0,
        liveCaptionPipelineUsesUnitTranslation: true,
        processTargetsProvider: { [] }
    )
    let record = try store.createMeeting(name: "Runtime Meeting", target: AudioCaptureTarget(processID: 42, name: "Zoom"), startedAt: Date())
    recorder.activeRecord = record
    await viewModel.startRecording(for: AudioCaptureTarget(processID: 42, name: "Zoom"))
    recorder.drainResult = RecordingDrainResult(
        transcriptUpdates: [
            TranscriptSegmentAccumulationResult(
                document: TranscriptDocument(segments: [
                    TranscriptSegment(
                        id: "deepgram-transcribe-stream-0.0",
                        text: "We should confirm the launch owner today",
                        language: "en-US",
                        isFinal: false
                    )
                ]),
                changedSegmentIDs: ["deepgram-transcribe-stream-0.0"],
                plainTextReplacement: nil,
                source: .realtime
            )
        ]
    )

    await viewModel.drainRecordingFrames()
    await waitFor {
        viewModel.liveCaptionTurns.first?.translatedText == "我们确认负责人"
    }

    XCTAssertEqual(viewModel.performanceEventCount(named: "translation_runtime_snapshot"), 1)
    XCTAssertEqual(viewModel.liveCaptionTurns.first?.translatedText, "我们确认负责人")
}
```

- [ ] **Step 2: Run test to verify failure**

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testActiveRecordingUnitTranslationUsesRuntimeAndPublishesOverlay
```

Expected: fails because ViewModel still logs `translation_experience_snapshot` directly and does not own `TranslationRuntime`.

- [ ] **Step 3: Replace ViewModel pipeline fields with runtime**

In `MeetingAgentViewModel`, replace:

```swift
private var translationExperiencePipeline: TranslationExperiencePipeline?
private var translationExperiencePipelineMeetingID: UUID?
```

with:

```swift
private var translationRuntime = TranslationRuntime()
private var translationRuntimeMeetingID: UUID?
private var translationRuntimeGeneration = 0
```

Replace `makeOrReuseTranslationExperiencePipeline(document:)` with `startOrReuseTranslationRuntime(document:)`:

```swift
private func startOrReuseTranslationRuntime(document: TranscriptDocument) -> Bool {
    guard let meetingID = activeMeetingID ?? selectedMeetingID,
          let provider = captionTranslationProviderForCurrentConfiguration(document: document)
    else {
        return false
    }
    if translationRuntimeMeetingID == meetingID {
        return true
    }
    let directoryURL = selectedMeeting?.transcriptJSONURL?.deletingLastPathComponent()
        ?? selectedMeeting?.transcriptURL?.deletingLastPathComponent()
    if let directoryURL {
        translationResultPersistenceStore = TranslationResultPersistenceStore(directoryURL: directoryURL)
    }
    translationRuntimeGeneration += 1
    translationRuntimeMeetingID = meetingID
    translationRuntime.start(
        context: TranslationRuntimeContext(
            meetingID: meetingID,
            sourceLocale: speechConfiguration.localeIdentifier,
            targetLocale: speechConfiguration.targetLocaleIdentifier,
            generation: translationRuntimeGeneration
        ),
        liveProvider: provider,
        accurateProvider: provider,
        performanceEventLogger: currentPerformanceEventLogger(),
        persistFinalResult: { [weak self] record in
            try? self?.translationResultPersistenceStore?.append(record)
        }
    )
    return true
}
```

Update `applyTranslationExperience`:

```swift
guard isCurrentActiveCaptionApply(context),
      startOrReuseTranslationRuntime(document: document)
else {
    return
}
let generation = translationRuntimeGeneration
let snapshot = await translationRuntime.apply(document: document, generation: generation)
guard isCurrentActiveCaptionApply(context) else { return }
attachRuntimeTranslationSnapshot(snapshot, path: "realtime")
```

Add helper:

```swift
private func attachRuntimeTranslationSnapshot(
    _ snapshot: TranslationRuntimeSnapshot,
    path: String
) {
    let visibleResults = snapshot.visibleResults.filter {
        $0.displayState == .liveFresh || $0.displayState == .stableFinal
    }
    guard !visibleResults.isEmpty else { return }
    let overlaySnapshot = realtimeCaptionSession.attachTranslationResults(visibleResults)
    publishRealtimeCaptionPipelineSnapshot(overlaySnapshot)
    logCaptionSnapshotPublication(.translationOverlay, snapshot: overlaySnapshot, path: path)
}
```

- [ ] **Step 4: Update stop finalization path**

Replace `finalizeTranslationExperienceAfterStop()` body with:

```swift
private func finalizeTranslationExperienceAfterStop() async {
    guard liveCaptionPipelineUsesUnitTranslation else { return }
    let generation = translationRuntimeGeneration
    let snapshot = await translationRuntime.stopAndFinalize(generation: generation)
    attachRuntimeTranslationSnapshot(snapshot, path: "stop")
}
```

Delete `logTranslationExperienceSnapshot` and `translationExperienceResultMetadata` only after no callers remain.

- [ ] **Step 5: Run tests**

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testActiveRecordingUnitTranslationUsesRuntimeAndPublishesOverlay
swift test --filter MeetingAgentViewModelTests/testRealtimeCaptionAndTranslationOverlayPublishSeparatePerformanceEvents
swift test --filter MeetingAgentViewModelTests/testStopRecordingPublishesDelayedFlushedFinalTranslation
```

Expected: selected tests pass after updating event assertions from `translation_experience_snapshot` to `translation_runtime_snapshot` where applicable.

- [ ] **Step 6: Commit**

```bash
git add Sources/MeetingAgentCore/MeetingAgentViewModel.swift Sources/MeetingAgentCore/RealtimeCaptionSession.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift
git commit -m "refactor: move active translation lifecycle to runtime"
```

---

### Task 5: Make Legacy CaptionTranslationScheduler Role Explicit

**Files:**
- Modify: `Sources/MeetingAgentCore/LiveCaptionPipeline.swift`
- Modify: `Tests/MeetingAgentCoreTests/LiveCaptionPipelineTests.swift`
- Modify: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] **Step 1: Add failing legacy mode naming test**

In `LiveCaptionPipelineTests`, add:

```swift
func testUnitPipelineModeDoesNotScheduleLegacyReplayBackfillTranslations() async {
    let provider = SlowCaptionTranslationProvider()
    let pipeline = LiveCaptionPipeline(
        sourceLocale: "en-US",
        targetLocale: "zh-CN",
        translationProvider: provider,
        performanceEventLogger: nil,
        translationMode: .unitPipelineActiveRecording
    )
    _ = await pipeline.apply(TranscriptSegmentAccumulationResult(
        document: TranscriptDocument(segments: [
            TranscriptSegment(id: "segment-1", text: "We approve the launch.", language: "en-US", isFinal: true, speechFinal: true)
        ]),
        changedSegmentIDs: ["segment-1"],
        plainTextReplacement: nil
    ))

    let snapshot = await pipeline.scheduleLegacyReplayBackfillTranslations()

    XCTAssertEqual(provider.requests.count, 0)
    XCTAssertEqual(snapshot.translationHealth, .pending)
}
```

- [ ] **Step 2: Run test to verify failure**

Run:

```bash
swift test --filter LiveCaptionPipelineTests/testUnitPipelineModeDoesNotScheduleLegacyReplayBackfillTranslations
```

Expected: fails because `scheduleLegacyReplayBackfillTranslations()` does not exist.

- [ ] **Step 3: Rename mode and call surface**

Update enum:

```swift
public enum LiveCaptionTranslationMode: Equatable {
    case legacyReplayBackfill
    case unitPipelineActiveRecording
}
```

Update initializer default:

```swift
translationMode: LiveCaptionTranslationMode = .legacyReplayBackfill
```

Rename `schedulePendingTranslations()` to:

```swift
public func scheduleLegacyReplayBackfillTranslations() async -> LiveCaptionPipelineSnapshot {
    await scheduleFinalTranslationsOnly()
    return snapshot(
        captionHealth: store.turns.isEmpty ? .idle : .live,
        translationHealth: currentTranslationHealth()
    )
}
```

Keep a compatibility wrapper if many tests still call the old name:

```swift
public func schedulePendingTranslations() async -> LiveCaptionPipelineSnapshot {
    await scheduleLegacyReplayBackfillTranslations()
}
```

Update guards:

```swift
private func scheduleLiveTranslations() async {
    guard translationMode == .legacyReplayBackfill else { return }
    ...
}

private func scheduleFinalTranslationsOnly() async {
    guard translationMode == .legacyReplayBackfill else { return }
    ...
}
```

Update all `.legacyCaptionScheduler` references to `.legacyReplayBackfill`.

- [ ] **Step 4: Update RealtimeCaptionSession wrapper**

In `RealtimeCaptionSession`, rename the method:

```swift
func scheduleLegacyReplayBackfillTranslations() async -> LiveCaptionPipelineSnapshot {
    await pipeline.scheduleLegacyReplayBackfillTranslations()
}
```

Keep old wrapper only if existing tests still need it:

```swift
func schedulePendingTranslations() async -> LiveCaptionPipelineSnapshot {
    await pipeline.scheduleLegacyReplayBackfillTranslations()
}
```

- [ ] **Step 5: Run tests**

Run:

```bash
swift test --filter LiveCaptionPipelineTests
swift test --filter MeetingAgentViewModelTests/testSelectedMeetingReplayPublishesPipelineDegradedTranslationHealth
```

Expected: tests pass and active recording unit mode still does not call legacy scheduler.

- [ ] **Step 6: Commit**

```bash
git add Sources/MeetingAgentCore/LiveCaptionPipeline.swift Sources/MeetingAgentCore/RealtimeCaptionSession.swift Tests/MeetingAgentCoreTests/LiveCaptionPipelineTests.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift
git commit -m "refactor: mark caption translation scheduler as legacy backfill"
```

---

### Task 6: Hydrate Stable Unit Results Before Legacy Replay Backfill

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Modify: `Sources/MeetingAgentCore/LiveCaptionPipeline.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] **Step 1: Add failing replay hydration priority test**

Add this test to `MeetingAgentViewModelTests`:

```swift
func testReplayHydratesUnitStableResultBeforeLegacyBackfill() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("unit-hydrate-priority-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try MeetingStore(rootDirectory: root)
    let meeting = try store.createMeeting(name: "Hydrate Priority", target: AudioCaptureTarget(processID: 1, name: "Zoom"), startedAt: Date())
    let transcriptURL = root.appendingPathComponent(meeting.id.uuidString).appendingPathComponent("transcript.json")
    let document = TranscriptDocument(segments: [
        TranscriptSegment(id: "segment-1", text: "We approve the launch.", language: "en-US", isFinal: true, speechFinal: true)
    ])
    try store.updateMeeting(meeting.id) { record in
        record.transcriptJSONURL = transcriptURL
    }
    try JSONEncoder.meetingAgent.encode(document).write(to: transcriptURL)
    let resultStore = TranslationResultPersistenceStore(directoryURL: transcriptURL.deletingLastPathComponent())
    try resultStore.append(TranslationResultPersistenceRecord(
        meetingID: meeting.id,
        resultID: "stable-1",
        sourceID: "block-1",
        laneID: TranslationLaneID(speaker: .default, sourceLocale: "en-US", targetLocale: "zh-CN"),
        sourceSegmentIDs: ["segment-1"],
        sourceTextHash: StableTranslationBlock.stableHash("We approve the launch."),
        sourceText: "We approve the launch.",
        translatedText: "我们批准上线。",
        displayState: .stableFinal,
        boundaryReason: .providerHardBoundary,
        providerID: "test",
        createdAt: Date(timeIntervalSince1970: 1),
        finalizedAt: Date(timeIntervalSince1970: 2)
    ))
    let provider = ViewModelFakeTextTranslationProvider(translations: ["segment-1": "旧链路翻译"])
    let viewModel = MeetingAgentViewModel(
        store: store,
        recorder: nil,
        speechLocaleIdentifier: "en-US",
        captionTranslationProviderFactory: { provider },
        liveCaptionPipelineUsesUnitTranslation: true,
        processTargetsProvider: { [] }
    )

    viewModel.selectMeeting(meeting.id)
    await waitFor {
        viewModel.liveCaptionTurns.first?.translatedText == "我们批准上线。"
    }

    XCTAssertTrue(provider.requests.isEmpty)
    XCTAssertEqual(viewModel.liveCaptionTurns.first?.translationState, .final)
}
```

- [ ] **Step 2: Run test to verify failure**

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testReplayHydratesUnitStableResultBeforeLegacyBackfill
```

Expected: fails if replay schedules legacy translation before unit hydration or if provider requests are made.

- [ ] **Step 3: Implement replay hydration before backfill**

In `MeetingAgentViewModel.selectedTranscriptDocument()` or the replay path that handles selected meetings, load unit records:

```swift
private func stableUnitTranslationResults(for record: MeetingRecord) -> [TranslationResult] {
    guard let directoryURL = record.transcriptJSONURL?.deletingLastPathComponent()
        ?? record.transcriptURL?.deletingLastPathComponent()
    else {
        return []
    }
    let store = TranslationResultPersistenceStore(directoryURL: directoryURL)
    let records = (try? store.readAll()) ?? []
    var resultStore = TranslationResultStore()
    resultStore.hydrate(from: records)
    return resultStore.stableResults()
}
```

After caption replay and before legacy backfill:

```swift
let stableResults = stableUnitTranslationResults(for: meeting)
if !stableResults.isEmpty {
    let overlaySnapshot = realtimeCaptionSession.attachTranslationResults(stableResults)
    publishRealtimeCaptionPipelineSnapshot(overlaySnapshot)
}
if stableResults.isEmpty {
    let snapshot = await realtimeCaptionSession.scheduleLegacyReplayBackfillTranslations()
    publishRealtimeCaptionPipelineSnapshot(snapshot)
}
```

Use the actual local variable names from the selected-meeting replay method; keep the ordering exactly as above.

- [ ] **Step 4: Run tests**

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testReplayHydratesUnitStableResultBeforeLegacyBackfill
swift test --filter MeetingAgentViewModelTests/testSelectingMeetingHydratesStableUnitTranslationResultsThroughPipeline
```

Expected: both pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingAgentCore/MeetingAgentViewModel.swift Sources/MeetingAgentCore/LiveCaptionPipeline.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift
git commit -m "feat: hydrate unit translations before legacy replay backfill"
```

---

### Task 7: Tighten Telemetry And Performance Analysis

**Files:**
- Modify: `Sources/MeetingAgentCore/TranslationRuntime.swift`
- Modify: `scripts/analyze-meeting-performance.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingPerformanceAnalysisScriptTests.swift`

- [ ] **Step 1: Add failing performance script assertions**

Update `testAnalyzeMeetingPerformanceScriptReportsUnitTranslationPipelineMetrics` event fixture with:

```swift
event("translation_unit_live_dropped_after_stop", wallTime: "2026-05-06T00:00:06Z", segmentID: "unit-4", isFinal: false, textLength: 18, metadata: [
    "translationKind": "live"
]),
event("translation_runtime_snapshot", wallTime: "2026-05-06T00:00:07Z", metadata: [
    "path": "stop",
    "state": "stopped",
    "liveResultCount": "0",
    "stableResultCount": "1",
    "visibleResultCount": "1",
    "droppedResultCount": "1"
])
```

Add assertions:

```swift
XCTAssertTrue(output.stdout.contains("Live Unit Dropped After Stop Count: 1"))
XCTAssertTrue(output.stdout.contains("Runtime Snapshot Count: 1"))
XCTAssertTrue(output.stdout.contains("Runtime Dropped Result Count: 1"))
```

- [ ] **Step 2: Run test to verify failure**

Run:

```bash
swift test --filter MeetingPerformanceAnalysisScriptTests/testAnalyzeMeetingPerformanceScriptReportsUnitTranslationPipelineMetrics
```

Expected: fails because analyzer does not report runtime snapshot count or dropped-result totals.

- [ ] **Step 3: Implement analyzer metrics**

In `scripts/analyze-meeting-performance.swift`, extend the Unit Translation Pipeline section:

```swift
let runtimeSnapshots = unitEvents("translation_runtime_snapshot")
let runtimeDroppedCount = runtimeSnapshots.reduce(0) { partial, event in
    partial + (Int(event.metadata["droppedResultCount"] ?? "0") ?? 0)
}
lines.append("Runtime Snapshot Count: \(runtimeSnapshots.count)")
lines.append("Runtime Dropped Result Count: \(runtimeDroppedCount)")
```

Keep `translation_runtime_snapshot` in `unitEvents` by updating helper:

```swift
private func unitEvents(_ name: String) -> [PerformanceEvent] {
    events.filter { $0.event == name }
}
```

No special prefix logic is needed for runtime snapshot because the section calls it by exact name.

- [ ] **Step 4: Run tests**

Run:

```bash
swift test --filter MeetingPerformanceAnalysisScriptTests
```

Expected: all performance script tests pass.

- [ ] **Step 5: Commit**

```bash
git add scripts/analyze-meeting-performance.swift Tests/MeetingAgentCoreTests/MeetingPerformanceAnalysisScriptTests.swift Sources/MeetingAgentCore/TranslationRuntime.swift
git commit -m "feat: report translation runtime performance metrics"
```

---

### Task 8: Full Verification And Latest Meeting Comparison

**Files:**
- No code changes expected.
- Use: `scripts/analyze-deepgram-reconciliation-performance.swift`
- Use: `scripts/analyze-meeting-performance.swift`

- [ ] **Step 1: Run focused translation suites**

Run:

```bash
swift test --filter TranslationRuntimeTests
swift test --filter TranslationExperiencePipelineTests
swift test --filter LiveTranslationSchedulerTests
swift test --filter TranslationUnitBuilderTests
swift test --filter LiveCaptionPipelineTests
swift test --filter MeetingAgentViewModelTests
```

Expected: all selected suites pass.

- [ ] **Step 2: Run full project gate**

Run:

```bash
make test
```

Expected:

- all tests pass;
- unit coverage line >= 95%;
- unit coverage method >= 95%;
- coverage gate passed.

- [ ] **Step 3: Run Deepgram regression performance fixture**

Run:

```bash
swift scripts/analyze-deepgram-reconciliation-performance.swift Tests/MeetingAgentCoreTests/Fixtures/latest-meeting-deepgram-x.log Tests/MeetingAgentCoreTests/Fixtures/latest-source-caption-regression.wav
```

Expected:

- command exits 0;
- `persisted_interim_segment_count=0`;
- `non_overlapping_repeated_text_count=0`.

- [ ] **Step 4: Analyze latest local meeting before new recording**

Run:

```bash
ls -t /Users/allan/Library/Application\ Support/MeetingAgent/Meetings/*/performance-events.jsonl | head -1
swift scripts/analyze-meeting-performance.swift "<path printed by ls>"
```

Expected old-link baseline may still show:

- `Post-Stop Translation Events` greater than 0;
- `Live Unit Scheduled Count: 0` if the meeting was recorded before runtime finalization;
- `Unit Translation Pipeline` metrics available in the report.

- [ ] **Step 5: Record a new meeting with the built app**

Run the app locally:

```bash
swift run MeetingAgentApp
```

Record a short meeting with translatable speech, stop recording, then close the app after finalization completes.

If `swift run MeetingAgentApp` is not usable in the current environment, use the packaged app flow:

```bash
make package-app
```

Then launch `dist/MeetingAgent.app` manually.

- [ ] **Step 6: Analyze the new meeting**

Run:

```bash
ls -t /Users/allan/Library/Application\ Support/MeetingAgent/Meetings/*/performance-events.jsonl | head -1
swift scripts/analyze-meeting-performance.swift "<newest performance-events.jsonl>"
```

Expected acceptance:

- `Preview Published After Stop Count: 0`;
- `Live Unit Scheduled Count` greater than 0 for speech long enough to preview;
- `Stable Unit Persisted Count` greater than 0 after stop finalization;
- `Runtime Snapshot Count` greater than 0;
- caption p95 does not materially regress against the pre-change latest local meeting.

- [ ] **Step 7: Commit verification-only doc updates if any**

If no files changed, do not commit. If the plan or docs were updated with measured results, run:

```bash
git add docs/superpowers/plans/2026-05-06-translation-runtime-finalization.md
git commit -m "docs: record translation runtime verification results"
```

---

## Completion Criteria

- Active recording translation goes through `TranslationRuntime` and `TranslationExperiencePipeline`.
- `CaptionTranslationScheduler` is explicitly named and guarded as legacy replay/backfill.
- Stop finalization publishes stable final results only.
- Late live preview after stop is logged as dropped and not attached to UI.
- Replay hydrates `translation-results.jsonl` before legacy backfill.
- Performance script reports runtime and unit metrics separately from legacy caption translation metrics.
- `make test` passes with coverage gate.
- Latest new meeting analysis shows zero visible post-stop preview publication.

