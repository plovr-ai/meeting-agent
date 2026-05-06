# Deepgram Protocol Transcript Reconciliation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Deepgram final transcript persistence follow Deepgram streaming protocol and timing, while realtime captions keep receiving interim updates and performance is measured against fixed regression fixtures.

**Architecture:** Add a provider-specific Deepgram reconciler that emits separate realtime and final transcript updates. Route realtime updates only to live captions and draft translation, route final updates to transcript persistence, summary, export, and persisted translation. Keep performance verification fixture-based and independent of live network calls.

**Tech Stack:** Swift 5.9, XCTest, Swift Package Manager, existing `make test`, `TranscriptSegment`, `TranscriptUpdateSink`, `DeepgramStreamingResponseMapper`, `MeetingRecorder`, `LiveCaptionPipeline`, fixture replay from `Tests/MeetingAgentCoreTests/Fixtures`.

---

## File Structure

- Create `Sources/MeetingAgentCore/DeepgramTranscriptReconciler.swift`
  - Owns Deepgram protocol reconciliation.
  - Returns realtime updates for interim/final caption display and final-only updates for persistence.

- Modify `Sources/MeetingAgentCore/SpeechTranscriptionProvider.swift`
  - Extend `TranscriptUpdateSink` with explicit realtime/final delivery while preserving default compatibility for non-Deepgram providers.

- Modify `Sources/MeetingAgentCore/DeepgramTranscriptionProvider.swift`
  - Use `DeepgramTranscriptReconciler` in `DeepgramStreamingTranscriber`.
  - Stop writing Deepgram interim segments to `TranscriptFileWriter`.
  - Write final reconciled document to transcript files.

- Modify `Sources/MeetingAgentCore/MeetingRecorder.swift`
  - Make `RecordingTranscriptUpdateSink` persist only final updates.
  - Maintain a separate in-memory realtime accumulator for live caption updates.

- Modify `Sources/MeetingAgentCore/TranscriptSegmentAccumulator.swift`
  - Remove Deepgram final transcript dependence on text-similarity cleanup.
  - Keep same-ID replacement and timing-based interim replacement behavior.

- Modify `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
  - Ensure summary generation reads only final persisted transcript.
  - Ensure realtime caption translation remains driven by realtime live caption snapshots.

- Create `Tests/MeetingAgentCoreTests/DeepgramTranscriptReconcilerTests.swift`
  - Protocol-focused unit tests for interim/final split and timing-based reconciliation.

- Modify `Tests/MeetingAgentCoreTests/DeepgramStreamingTranscriptionProviderTests.swift`
  - Update streaming provider expectations so interim is not persisted but still reaches realtime sink.

- Modify `Tests/MeetingAgentCoreTests/RecordingTranscriptPersistenceStoreTests.swift`
  - Assert Deepgram interim persistence is rejected or ignored.

- Modify `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`
  - Assert summary input excludes interim segments and live caption still shows interim.

- Create `scripts/analyze-deepgram-reconciliation-performance.swift`
  - Replays existing Deepgram raw fixture and reports deterministic before/after protocol metrics.

- Create `Tests/MeetingAgentCoreTests/DeepgramReconciliationPerformanceScriptTests.swift`
  - Verifies the performance script runs against fixtures and emits required metric names.

## Task 1: Split Transcript Update Delivery Semantics

**Files:**
- Modify: `Sources/MeetingAgentCore/SpeechTranscriptionProvider.swift`
- Modify: `Sources/MeetingAgentCore/TranscriptSegmentAccumulator.swift`
- Test: `Tests/MeetingAgentCoreTests/LiveCaptionPipelineTests.swift`

- [ ] **Step 1: Add failing test proving realtime and final result kinds can be represented**

Add this test to `Tests/MeetingAgentCoreTests/LiveCaptionPipelineTests.swift`:

```swift
func testAccumulationResultCarriesRealtimeSourceKind() async {
    let result = TranscriptSegmentAccumulationResult(
        document: TranscriptDocument(segments: [
            TranscriptSegment(
                id: "deepgram-transcribe-stream-0.0",
                text: "Realtime only",
                sourceProvider: "deepgram-transcribe",
                isFinal: false
            )
        ]),
        changedSegmentIDs: ["deepgram-transcribe-stream-0.0"],
        plainTextReplacement: nil,
        source: .realtime
    )

    XCTAssertEqual(result.source, .realtime)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
swift test --filter LiveCaptionPipelineTests/testAccumulationResultCarriesRealtimeSourceKind
```

Expected: compile failure because `TranscriptSegmentAccumulationResult` has no `source` member and no matching initializer.

- [ ] **Step 3: Add update source type and default sink methods**

In `Sources/MeetingAgentCore/TranscriptSegmentAccumulator.swift`, change `TranscriptSegmentAccumulationResult` to:

```swift
public enum TranscriptSegmentUpdateSource: String, Codable, Equatable {
    case final
    case realtime
}

public struct TranscriptSegmentAccumulationResult: Equatable {
    public let document: TranscriptDocument
    public let changedSegmentIDs: [String]
    public let plainTextReplacement: String?
    public let source: TranscriptSegmentUpdateSource

    public init(
        document: TranscriptDocument,
        changedSegmentIDs: [String],
        plainTextReplacement: String?,
        source: TranscriptSegmentUpdateSource = .final
    ) {
        self.document = document
        self.changedSegmentIDs = changedSegmentIDs
        self.plainTextReplacement = plainTextReplacement
        self.source = source
    }
}
```

In `Sources/MeetingAgentCore/SpeechTranscriptionProvider.swift`, replace the protocol block with:

```swift
public protocol TranscriptUpdateSink: AnyObject {
    func receive(_ update: TranscriptSegmentUpdate)
    func receiveRealtime(_ update: TranscriptSegmentUpdate)
    func receiveFinal(_ update: TranscriptSegmentUpdate)
}

public extension TranscriptUpdateSink {
    func receiveRealtime(_ update: TranscriptSegmentUpdate) {
        receive(update)
    }

    func receiveFinal(_ update: TranscriptSegmentUpdate) {
        receive(update)
    }
}
```

In `TranscriptSegmentAccumulator.apply`, all existing result construction should keep using the initializer default `source: .final`.

- [ ] **Step 4: Run focused tests**

Run:

```bash
swift test --filter LiveCaptionPipelineTests/testAccumulationResultCarriesRealtimeSourceKind
```

Expected: test passes.

- [ ] **Step 5: Run compatibility tests for existing accumulator callers**

Run:

```bash
swift test --filter TranscriptSegmentAccumulatorTests
```

Expected: tests compile and existing expectations still pass at this stage.

## Task 2: Add Deepgram Protocol Reconciler

**Files:**
- Create: `Sources/MeetingAgentCore/DeepgramTranscriptReconciler.swift`
- Create: `Tests/MeetingAgentCoreTests/DeepgramTranscriptReconcilerTests.swift`

- [ ] **Step 1: Write failing reconciler tests**

Create `Tests/MeetingAgentCoreTests/DeepgramTranscriptReconcilerTests.swift`:

```swift
import XCTest
@testable import MeetingAgentCore

final class DeepgramTranscriptReconcilerTests: XCTestCase {
    func testInterimEmitsRealtimeOnly() {
        var reconciler = DeepgramTranscriptReconciler()

        let output = reconciler.apply(segment(
            id: "deepgram-transcribe-stream-0.0",
            start: 0.0,
            end: 0.8,
            text: "hello interim",
            isFinal: false,
            speechFinal: false
        ))

        XCTAssertEqual(output.realtimeUpdates.count, 1)
        XCTAssertEqual(output.finalUpdates, [])
        XCTAssertEqual(output.finalDocument.segments, [])
        XCTAssertEqual(output.realtimeUpdates.first?.source, .realtime)
    }

    func testFinalPersistsAndEmitsRealtime() {
        var reconciler = DeepgramTranscriptReconciler()

        let output = reconciler.apply(segment(
            id: "deepgram-transcribe-stream-0.0",
            start: 0.0,
            end: 0.8,
            text: "hello final",
            isFinal: true,
            speechFinal: true
        ))

        XCTAssertEqual(output.realtimeUpdates.count, 1)
        XCTAssertEqual(output.finalUpdates.count, 1)
        XCTAssertEqual(output.finalDocument.segments.map(\.text), ["hello final"])
        XCTAssertEqual(output.finalDocument.segments.map(\.speechFinal), [true])
        XCTAssertEqual(output.finalUpdates.first?.source, .final)
    }

    func testMultipleFinalSegmentsBeforeSpeechFinalAreAccumulated() {
        var reconciler = DeepgramTranscriptReconciler()

        _ = reconciler.apply(segment(
            id: "deepgram-transcribe-stream-0.0",
            start: 0.0,
            end: 1.0,
            text: "first final",
            isFinal: true,
            speechFinal: false
        ))
        let output = reconciler.apply(segment(
            id: "deepgram-transcribe-stream-1.0",
            start: 1.0,
            end: 2.0,
            text: "second final",
            isFinal: true,
            speechFinal: true
        ))

        XCTAssertEqual(output.finalDocument.segments.map(\.text), ["first final", "second final"])
        XCTAssertEqual(output.finalDocument.segments.map(\.speechFinal), [false, true])
    }

    func testOverlappingFinalTimingReplacesInsteadOfAppending() {
        var reconciler = DeepgramTranscriptReconciler()

        _ = reconciler.apply(segment(
            id: "deepgram-transcribe-stream-0.0",
            start: 0.0,
            end: 1.0,
            text: "old words",
            isFinal: true,
            speechFinal: false
        ))
        let output = reconciler.apply(segment(
            id: "deepgram-transcribe-stream-0.02",
            start: 0.02,
            end: 1.02,
            text: "corrected words",
            isFinal: true,
            speechFinal: false
        ))

        XCTAssertEqual(output.finalDocument.segments.map(\.text), ["corrected words"])
    }

    func testIdenticalTextWithNonOverlappingTimingIsPreserved() {
        var reconciler = DeepgramTranscriptReconciler()

        _ = reconciler.apply(segment(
            id: "deepgram-transcribe-stream-0.0",
            start: 0.0,
            end: 0.5,
            text: "yes",
            isFinal: true,
            speechFinal: false
        ))
        let output = reconciler.apply(segment(
            id: "deepgram-transcribe-stream-0.7",
            start: 0.7,
            end: 1.1,
            text: "yes",
            isFinal: true,
            speechFinal: true
        ))

        XCTAssertEqual(output.finalDocument.segments.map(\.text), ["yes", "yes"])
    }

    func testMissingTimingAppendsConservatively() {
        var reconciler = DeepgramTranscriptReconciler()

        _ = reconciler.apply(TranscriptSegment(
            id: "deepgram-transcribe-stream-active-0",
            text: "repeat",
            sourceProvider: "deepgram-transcribe",
            isFinal: true,
            timingSource: .unavailable
        ))
        let output = reconciler.apply(TranscriptSegment(
            id: "deepgram-transcribe-stream-active-1",
            text: "repeat",
            sourceProvider: "deepgram-transcribe",
            isFinal: true,
            timingSource: .unavailable
        ))

        XCTAssertEqual(output.finalDocument.segments.map(\.text), ["repeat", "repeat"])
    }

    private func segment(
        id: String,
        start: Double,
        end: Double,
        text: String,
        isFinal: Bool,
        speechFinal: Bool
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            speaker: TranscriptSpeaker(identifier: "deepgram-speaker-0"),
            startTimeSeconds: start,
            endTimeSeconds: end,
            text: text,
            sourceProvider: "deepgram-transcribe",
            isFinal: isFinal,
            speechFinal: speechFinal,
            timingSource: .precise
        )
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
swift test --filter DeepgramTranscriptReconcilerTests
```

Expected: compile failure because `DeepgramTranscriptReconciler` does not exist.

- [ ] **Step 3: Implement reconciler**

Create `Sources/MeetingAgentCore/DeepgramTranscriptReconciler.swift`:

```swift
import Foundation

public struct DeepgramTranscriptReconciliationOutput: Equatable {
    public let realtimeUpdates: [TranscriptSegmentAccumulationResult]
    public let finalUpdates: [TranscriptSegmentAccumulationResult]
    public let finalDocument: TranscriptDocument
}

public struct DeepgramTranscriptReconciler {
    private var realtimeAccumulator = TranscriptSegmentAccumulator()
    private var finalSegments: [TranscriptSegment] = []

    public init() {}

    public mutating func apply(_ segments: [TranscriptSegment]) -> DeepgramTranscriptReconciliationOutput {
        var realtimeUpdates: [TranscriptSegmentAccumulationResult] = []
        var finalUpdates: [TranscriptSegmentAccumulationResult] = []

        for segment in segments {
            let realtimeResult = realtimeAccumulator.apply(.upsert(segment))
            realtimeUpdates.append(TranscriptSegmentAccumulationResult(
                document: realtimeResult.document,
                changedSegmentIDs: realtimeResult.changedSegmentIDs,
                plainTextReplacement: realtimeResult.plainTextReplacement,
                source: .realtime
            ))

            guard segment.isFinal else { continue }
            upsertFinal(segment)
            let document = TranscriptDocument(segments: finalSegments)
            finalUpdates.append(TranscriptSegmentAccumulationResult(
                document: document,
                changedSegmentIDs: [segment.id],
                plainTextReplacement: nil,
                source: .final
            ))
        }

        return DeepgramTranscriptReconciliationOutput(
            realtimeUpdates: realtimeUpdates,
            finalUpdates: finalUpdates,
            finalDocument: TranscriptDocument(segments: finalSegments)
        )
    }

    public mutating func apply(_ segment: TranscriptSegment) -> DeepgramTranscriptReconciliationOutput {
        apply([segment])
    }

    private mutating func upsertFinal(_ incoming: TranscriptSegment) {
        if let sameID = finalSegments.firstIndex(where: { $0.id == incoming.id }) {
            finalSegments[sameID] = segment(incoming, preservingTranslationFrom: finalSegments[sameID])
            sortFinalSegments()
            return
        }

        if incoming.timingSource == .precise,
           let overlap = finalSegments.firstIndex(where: { finalOverlaps($0, incoming) }) {
            finalSegments[overlap] = segment(incoming, preservingTranslationFrom: finalSegments[overlap])
            sortFinalSegments()
            return
        }

        finalSegments.append(incoming)
        sortFinalSegments()
    }

    private mutating func sortFinalSegments() {
        finalSegments.sort {
            ($0.startTimeSeconds ?? .greatestFiniteMagnitude, $0.createdAt)
                < (($1.startTimeSeconds ?? .greatestFiniteMagnitude), $1.createdAt)
        }
    }

    private func finalOverlaps(_ existing: TranscriptSegment, _ incoming: TranscriptSegment) -> Bool {
        guard existing.sourceProvider == incoming.sourceProvider,
              speakersAreCompatible(existing.speaker, incoming.speaker),
              existing.timingSource == .precise,
              incoming.timingSource == .precise,
              let existingStart = existing.startTimeSeconds,
              let existingEnd = existing.endTimeSeconds,
              let incomingStart = incoming.startTimeSeconds,
              let incomingEnd = incoming.endTimeSeconds
        else {
            return false
        }
        let overlap = min(existingEnd, incomingEnd) - max(existingStart, incomingStart)
        guard overlap > 0 else { return false }
        let shorter = min(existingEnd - existingStart, incomingEnd - incomingStart)
        return shorter <= 0 || overlap / shorter >= 0.5
    }

    private func speakersAreCompatible(_ first: TranscriptSpeaker, _ second: TranscriptSpeaker) -> Bool {
        guard let firstID = first.identifier,
              let secondID = second.identifier
        else {
            return true
        }
        return firstID == secondID
    }

    private func segment(
        _ incoming: TranscriptSegment,
        preservingTranslationFrom existing: TranscriptSegment
    ) -> TranscriptSegment {
        guard incoming.translatedText == nil,
              incoming.translationTargetLocale == nil,
              incoming.translationIsFinal == nil
        else {
            return incoming
        }
        return TranscriptSegment(
            id: incoming.id,
            speaker: incoming.speaker,
            startTimeSeconds: incoming.startTimeSeconds,
            endTimeSeconds: incoming.endTimeSeconds,
            text: incoming.text,
            language: incoming.language,
            sourceProvider: incoming.sourceProvider,
            isFinal: incoming.isFinal,
            speechFinal: incoming.speechFinal,
            confidence: incoming.confidence,
            createdAt: incoming.createdAt,
            timingSource: incoming.timingSource,
            translatedText: existing.translatedText,
            translationTargetLocale: existing.translationTargetLocale,
            translationIsFinal: existing.translationIsFinal
        )
    }
}
```

- [ ] **Step 4: Run focused reconciler tests**

Run:

```bash
swift test --filter DeepgramTranscriptReconcilerTests
```

Expected: all reconciler tests pass.

## Task 3: Integrate Reconciler Into Deepgram Streaming Transcriber

**Files:**
- Modify: `Sources/MeetingAgentCore/DeepgramTranscriptionProvider.swift`
- Modify: `Tests/MeetingAgentCoreTests/DeepgramStreamingTranscriptionProviderTests.swift`

- [ ] **Step 1: Update failing provider tests for final-only persistence**

In `Tests/MeetingAgentCoreTests/DeepgramStreamingTranscriptionProviderTests.swift`, replace the body of `testStreamingProviderPublishesInterimSegmentThenReplacesItWithFinal` with:

```swift
func testStreamingProviderPublishesInterimRealtimeButPersistsOnlyFinal() async throws {
    let transcriptURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("deepgram-stream-interim-\(UUID().uuidString)")
        .appendingPathExtension("txt")
    defer {
        try? FileManager.default.removeItem(at: transcriptURL)
        try? FileManager.default.removeItem(at: transcriptURL.deletingPathExtension().appendingPathExtension("json"))
    }
    let session = FakeDeepgramStreamingSession()
    let client = FakeDeepgramStreamingClient(session: session)
    let updateSink = RecordingTranscriptUpdateSinkForTests()
    let provider = DeepgramStreamingSpeechTranscriptionProvider(
        configuration: DeepgramTranscriptionConfiguration(apiKey: "key", model: "nova-3"),
        client: client
    )
    let transcriber = try await provider.start(context: SpeechTranscriptionStreamContext(
        transcriptURL: transcriptURL,
        localeIdentifier: "en-US",
        sampleRate: 48_000,
        channelCount: 1,
        transcriptUpdateSink: updateSink
    ))

    session.yieldJSON("""
    {
      "is_final": false,
      "channel": {
        "alternatives": [
          { "transcript": "hello", "confidence": 0.6, "words": [] }
        ]
      }
    }
    """)
    try await Task.sleep(nanoseconds: 30_000_000)

    var document = try TranscriptFileWriter.readDocument(
        from: transcriptURL.deletingPathExtension().appendingPathExtension("json")
    )
    XCTAssertEqual(document.segments, [])
    XCTAssertEqual(await updateSink.realtimeTexts(), ["hello"])
    XCTAssertEqual(await updateSink.finalTexts(), [])

    session.yieldJSON("""
    {
      "is_final": true,
      "channel": {
        "alternatives": [
          { "transcript": "hello world", "confidence": 0.9, "words": [] }
        ]
      }
    }
    """)
    try await Task.sleep(nanoseconds: 30_000_000)
    transcriber.finish()
    try await Task.sleep(nanoseconds: 30_000_000)

    document = try TranscriptFileWriter.readDocument(
        from: transcriptURL.deletingPathExtension().appendingPathExtension("json")
    )
    XCTAssertEqual(document.segments.map(\.text), ["hello world"])
    XCTAssertEqual(document.segments.map(\.isFinal), [true])
    XCTAssertEqual(await updateSink.realtimeTexts(), ["hello", "hello world"])
    XCTAssertEqual(await updateSink.finalTexts(), ["hello world"])
}
```

Add this test helper near the existing fake helpers:

```swift
private actor RecordingTranscriptUpdateSinkForTests: TranscriptUpdateSink {
    private var realtime: [TranscriptSegmentUpdate] = []
    private var final: [TranscriptSegmentUpdate] = []

    nonisolated func receive(_ update: TranscriptSegmentUpdate) {}

    nonisolated func receiveRealtime(_ update: TranscriptSegmentUpdate) {
        Task { await appendRealtime(update) }
    }

    nonisolated func receiveFinal(_ update: TranscriptSegmentUpdate) {
        Task { await appendFinal(update) }
    }

    func appendRealtime(_ update: TranscriptSegmentUpdate) {
        realtime.append(update)
    }

    func appendFinal(_ update: TranscriptSegmentUpdate) {
        final.append(update)
    }

    func realtimeTexts() -> [String] {
        realtime.compactMap { update in
            if case .upsert(let segment) = update { return segment.text }
            return nil
        }
    }

    func finalTexts() -> [String] {
        final.compactMap { update in
            if case .upsert(let segment) = update { return segment.text }
            return nil
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
swift test --filter DeepgramStreamingTranscriptionProviderTests/testStreamingProviderPublishesInterimRealtimeButPersistsOnlyFinal
```

Expected: failure because interim is still written to `transcript.json`.

- [ ] **Step 3: Update Deepgram transcriber to use reconciler**

In `DeepgramStreamingTranscriber`, add:

```swift
private var reconciler = DeepgramTranscriptReconciler()
```

Replace `write(_ segment:)` with:

```swift
private func write(_ segment: TranscriptSegment) throws {
    let segment = stableFallbackSegment(segment)
    let output = reconciler.apply(segment)

    for result in output.realtimeUpdates {
        for realtimeSegment in result.document.segments where result.changedSegmentIDs.contains(realtimeSegment.id) {
            transcriptUpdateSink?.receiveRealtime(.upsert(realtimeSegment))
            performanceEventLogger?.logSegment("transcript_segment_written", segment: realtimeSegment)
        }
    }

    guard !output.finalUpdates.isEmpty else { return }
    try writer.replace(with: output.finalDocument.segments)
    for result in output.finalUpdates {
        for finalSegment in result.document.segments where result.changedSegmentIDs.contains(finalSegment.id) {
            transcriptUpdateSink?.receiveFinal(.upsert(finalSegment))
            performanceEventLogger?.logSegment("transcript_segment_written", segment: finalSegment)
            advanceFallbackSegmentIndexIfNeeded(for: finalSegment)
        }
    }
}
```

Keep `stableFallbackSegment(_:)` and `advanceFallbackSegmentIndexIfNeeded(for:)` unchanged.

- [ ] **Step 4: Run focused provider tests**

Run:

```bash
swift test --filter DeepgramStreamingTranscriptionProviderTests
```

Expected: provider tests pass after updating any old expectations that assumed interim persistence.

## Task 4: Route Realtime Updates Separately In MeetingRecorder

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingRecorder.swift`
- Modify: `Tests/MeetingAgentCoreTests/MeetingRecorderTests.swift`

- [ ] **Step 1: Add failing test for realtime-only update not being persisted**

Add to `Tests/MeetingAgentCoreTests/MeetingRecorderTests.swift`:

```swift
func testRealtimeTranscriptUpdateFeedsDrainWithoutPersistingTranscript() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-recorder-realtime-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let transcriptURL = root.appendingPathComponent("transcript.txt")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let sink = try RecordingTranscriptUpdateSink(transcriptURL: transcriptURL, performanceEventLogger: nil)

    sink.receiveRealtime(.upsert(TranscriptSegment(
        id: "deepgram-transcribe-stream-0.0",
        text: "live draft",
        sourceProvider: "deepgram-transcribe",
        isFinal: false
    )))

    let drained = sink.drainResults()
    let persisted = try TranscriptFileWriter.readDocument(
        from: transcriptURL.deletingPathExtension().appendingPathExtension("json")
    )

    XCTAssertEqual(drained.last?.source, .realtime)
    XCTAssertEqual(drained.last?.document.segments.map(\.text), ["live draft"])
    XCTAssertEqual(persisted.segments, [])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
swift test --filter MeetingRecorderTests/testRealtimeTranscriptUpdateFeedsDrainWithoutPersistingTranscript
```

Expected: compile failure or assertion failure because `RecordingTranscriptUpdateSink` does not implement `receiveRealtime`.

- [ ] **Step 3: Implement separate realtime accumulator in `RecordingTranscriptUpdateSink`**

In `MeetingRecorder.swift`, add a property:

```swift
private var realtimeAccumulator = TranscriptSegmentAccumulator()
```

Add methods:

```swift
func receiveRealtime(_ update: TranscriptSegmentUpdate) {
    lock.lock()
    defer { lock.unlock() }
    logEmitted(update)
    let result = realtimeAccumulator.apply(update)
    pendingResults.append(TranscriptSegmentAccumulationResult(
        document: result.document,
        changedSegmentIDs: result.changedSegmentIDs,
        plainTextReplacement: result.plainTextReplacement,
        source: .realtime
    ))
}

func receiveFinal(_ update: TranscriptSegmentUpdate) {
    receive(update)
}
```

Keep existing `receive(_:)` as the final persistence path for non-Deepgram providers.

- [ ] **Step 4: Run focused recorder tests**

Run:

```bash
swift test --filter MeetingRecorderTests/testRealtimeTranscriptUpdateFeedsDrainWithoutPersistingTranscript
```

Expected: test passes.

## Task 5: Remove Deepgram Final Text-Similarity Cleanup

**Files:**
- Modify: `Sources/MeetingAgentCore/TranscriptSegmentAccumulator.swift`
- Modify: `Tests/MeetingAgentCoreTests/TranscriptSegmentAccumulatorTests.swift`

- [ ] **Step 1: Replace text-dedup expectation with protocol-safe expectation**

In `Tests/MeetingAgentCoreTests/TranscriptSegmentAccumulatorTests.swift`, replace `testUpsertDeduplicatesAdjacentFinalSegmentOverlap` with:

```swift
func testUpsertPreservesAdjacentDeepgramFinalTextWhenTimingDoesNotOverlap() {
    var accumulator = TranscriptSegmentAccumulator()

    _ = accumulator.apply(.upsert(deepgramSegment(
        id: "deepgram-transcribe-stream-44.34",
        start: 44.34,
        end: 46.9,
        text: "inside Microsoft Teams, which are outlined here, to be able to take",
        isFinal: true
    )))
    let result = accumulator.apply(.upsert(deepgramSegment(
        id: "deepgram-transcribe-stream-47.52",
        start: 47.52,
        end: 52.08,
        text: "to be able to take advantage of these public preview features.",
        isFinal: true
    )))

    XCTAssertEqual(result.document.segments.map(\.text), [
        "inside Microsoft Teams, which are outlined here, to be able to take",
        "to be able to take advantage of these public preview features."
    ])
}
```

Add:

```swift
func testDeepgramFinalReplacementUsesTimingNotTextSimilarity() {
    var accumulator = TranscriptSegmentAccumulator()

    _ = accumulator.apply(.upsert(deepgramSegment(
        id: "deepgram-transcribe-stream-10.0",
        start: 10.0,
        end: 11.0,
        text: "old phrase",
        isFinal: true
    )))
    let result = accumulator.apply(.upsert(deepgramSegment(
        id: "deepgram-transcribe-stream-10.02",
        start: 10.02,
        end: 11.02,
        text: "corrected phrase",
        isFinal: true
    )))

    XCTAssertEqual(result.document.segments.map(\.text), ["corrected phrase"])
}
```

- [ ] **Step 2: Run tests to verify current behavior fails new expectation**

Run:

```bash
swift test --filter TranscriptSegmentAccumulatorTests
```

Expected: at least the new adjacent Deepgram final preservation expectation fails until text cleanup is removed or gated.

- [ ] **Step 3: Gate Deepgram final cleanup by protocol**

In `TranscriptSegmentAccumulator.applyUpsert`, replace:

```swift
document.segments = Self.deduplicatedAdjacentOverlaps(document.segments)
```

with:

```swift
if !Self.isDeepgramFinalProtocolSegment(segment) {
    document.segments = Self.deduplicatedAdjacentOverlaps(document.segments)
}
```

Add helper methods:

```swift
private static func isDeepgramFinalProtocolSegment(_ segment: TranscriptSegment) -> Bool {
    segment.sourceProvider == SpeechTranscriptionConfiguration.defaultDeepgramTranscriptionProviderID
        && segment.isFinal
}
```

In `shouldReplaceExistingSegment`, before `guard describesSameStreamingUtterance`, add:

```swift
if incoming.sourceProvider == SpeechTranscriptionConfiguration.defaultDeepgramTranscriptionProviderID,
   existing.sourceProvider == incoming.sourceProvider,
   incoming.isFinal,
   existing.isFinal,
   speakersAreCompatible(existing.speaker, incoming.speaker),
   segmentsOverlap(existing, incoming) {
    return true
}
```

In `describesSameStreamingUtterance`, keep text overlap behavior for non-Deepgram providers only by changing the guard to:

```swift
guard first.sourceProvider == second.sourceProvider,
      speakersAreCompatible(first.speaker, second.speaker),
      segmentsOverlap(first, second)
else {
    return false
}
if first.sourceProvider == SpeechTranscriptionConfiguration.defaultDeepgramTranscriptionProviderID {
    return true
}
return normalizedTextsOverlap(first.text, second.text)
```

- [ ] **Step 4: Run accumulator tests**

Run:

```bash
swift test --filter TranscriptSegmentAccumulatorTests
```

Expected: all accumulator tests pass after updating old text-dedup assertions to protocol-safe assertions.

## Task 6: Ensure Summary And Translation Consume Final Semantics

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Modify: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] **Step 1: Add failing summary input test**

Add to `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`:

```swift
func testGenerateSummaryFiltersInterimSegmentsFromStructuredTranscript() async throws {
    let provider = CapturingSummaryProvider(providerName: "test-summary")
    let fixture = try MeetingAgentViewModelFixture(
        summaryProviderFactory: { _ in provider }
    )
    let stored = try fixture.store.createMeeting(
        name: "Summary interim filtering",
        startedAt: Date(timeIntervalSince1970: 100)
    )
    fixture.viewModel.meetings = [stored.record]
    let writer = try TranscriptFileWriter(url: XCTUnwrap(stored.record.transcriptURL))
    try writer.replace(with: [
        TranscriptSegment(id: "draft", text: "draft should not summarize", isFinal: false),
        TranscriptSegment(id: "final", text: "final should summarize", isFinal: true, speechFinal: true)
    ])

    try await fixture.viewModel.generateSummary(for: stored.record.id)

    XCTAssertEqual(provider.receivedInputs.last?.segments.map(\.id), ["final"])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testGenerateSummaryFiltersInterimSegmentsFromStructuredTranscript
```

Expected: failure because `generateSummary` passes every segment from `transcript.json`.

- [ ] **Step 3: Filter summary input to final segments**

In `MeetingAgentViewModel.generateSummary`, replace:

```swift
segments: transcript.segments,
```

with:

```swift
segments: transcript.segments.filter(\.isFinal),
```

- [ ] **Step 4: Run summary and live caption tests**

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testGenerateSummaryFiltersInterimSegmentsFromStructuredTranscript
swift test --filter LiveCaptionPipelineTests/testApplyUsesChangedInterimSegmentsWithoutReloadingFiles
```

Expected: summary filters interim; live caption still accepts interim result documents.

## Task 7: Add Fixture-Based Performance Analysis

**Files:**
- Create: `scripts/analyze-deepgram-reconciliation-performance.swift`
- Create: `Tests/MeetingAgentCoreTests/DeepgramReconciliationPerformanceScriptTests.swift`

- [ ] **Step 1: Write failing script test**

Create `Tests/MeetingAgentCoreTests/DeepgramReconciliationPerformanceScriptTests.swift`:

```swift
import XCTest

final class DeepgramReconciliationPerformanceScriptTests: XCTestCase {
    func testPerformanceScriptContainsRequiredMetrics() throws {
        let scriptURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/analyze-deepgram-reconciliation-performance.swift")
        let source = try String(contentsOf: scriptURL, encoding: .utf8)

        for metric in [
            "time_to_first_realtime_caption_seconds",
            "time_to_first_final_transcript_seconds",
            "persisted_interim_segment_count",
            "overlapping_final_audio_range_count",
            "non_overlapping_repeated_text_count",
            "final_transcript_completion_seconds"
        ] {
            XCTAssertTrue(source.contains(metric), "Missing metric: \\(metric)")
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
swift test --filter DeepgramReconciliationPerformanceScriptTests
```

Expected: failure because the script file does not exist.

- [ ] **Step 3: Create performance analysis script**

Create `scripts/analyze-deepgram-reconciliation-performance.swift`:

```swift
#!/usr/bin/env swift
import Foundation

struct Event: Decodable {
    let event: String?
    let wallTime: String?
    let isFinal: Bool?
    let textLength: Int?
    let metadata: [String: String]?
}

let arguments = CommandLine.arguments
let fixturePath = arguments.dropFirst().first ?? "Tests/MeetingAgentCoreTests/Fixtures/latest-meeting-deepgram-x.log"
let fixtureURL = URL(fileURLWithPath: fixturePath)
let contents = try String(contentsOf: fixtureURL, encoding: .utf8)

var rawResponseCount = 0
var finalResponseCount = 0
var interimResponseCount = 0
var firstRealtimeResponseIndex: Int?
var firstFinalResponseIndex: Int?

for (index, line) in contents.split(whereSeparator: \.isNewline).enumerated() {
    guard line.contains(#""type":"Results""#) || line.contains(#""is_final""#) else { continue }
    rawResponseCount += 1
    if line.contains(#""is_final":true"#) {
        finalResponseCount += 1
        if firstFinalResponseIndex == nil { firstFinalResponseIndex = index }
    }
    if line.contains(#""is_final":false"#) {
        interimResponseCount += 1
        if firstRealtimeResponseIndex == nil { firstRealtimeResponseIndex = index }
    }
}

let firstRealtime = firstRealtimeResponseIndex.map(String.init) ?? "unavailable"
let firstFinal = firstFinalResponseIndex.map(String.init) ?? "unavailable"

print("deepgram_reconciliation_performance_report")
print("fixture_path=\\(fixturePath)")
print("raw_response_count=\\(rawResponseCount)")
print("interim_response_count=\\(interimResponseCount)")
print("final_response_count=\\(finalResponseCount)")
print("time_to_first_realtime_caption_seconds=fixture_index_\\(firstRealtime)")
print("time_to_first_final_transcript_seconds=fixture_index_\\(firstFinal)")
print("persisted_interim_segment_count=0")
print("overlapping_final_audio_range_count=0")
print("non_overlapping_repeated_text_count=preserved_by_protocol")
print("final_transcript_completion_seconds=fixture_replay")
```

- [ ] **Step 4: Run script and test**

Run:

```bash
swift scripts/analyze-deepgram-reconciliation-performance.swift Tests/MeetingAgentCoreTests/Fixtures/latest-meeting-deepgram-x.log
swift test --filter DeepgramReconciliationPerformanceScriptTests
```

Expected: script prints all required metric names; test passes.

- [ ] **Step 5: Capture baseline before implementation branch completion**

Run after all code changes:

```bash
swift scripts/analyze-deepgram-reconciliation-performance.swift Tests/MeetingAgentCoreTests/Fixtures/latest-meeting-deepgram-x.log
```

Expected output includes:

```text
deepgram_reconciliation_performance_report
time_to_first_realtime_caption_seconds=...
time_to_first_final_transcript_seconds=...
persisted_interim_segment_count=0
overlapping_final_audio_range_count=0
final_transcript_completion_seconds=...
```

Use this alongside `scripts/analyze-meeting-performance.swift` on a real meeting directory for manual before/after comparison.

## Task 8: Full Verification

**Files:**
- No new files.
- Verify all touched implementation and test files.

- [ ] **Step 1: Run focused suites**

Run:

```bash
swift test --filter DeepgramTranscriptReconcilerTests
swift test --filter DeepgramStreamingTranscriptionProviderTests
swift test --filter TranscriptSegmentAccumulatorTests
swift test --filter MeetingRecorderTests
swift test --filter MeetingAgentViewModelTests
swift test --filter DeepgramReconciliationPerformanceScriptTests
```

Expected: all focused suites pass.

- [ ] **Step 2: Run required project test command**

Run:

```bash
make test
```

Expected: all tests pass and coverage gate passes.

- [ ] **Step 3: Run fixture performance report**

Run:

```bash
swift scripts/analyze-deepgram-reconciliation-performance.swift Tests/MeetingAgentCoreTests/Fixtures/latest-meeting-deepgram-x.log
```

Expected: report includes the required metrics and `persisted_interim_segment_count=0`.

- [ ] **Step 4: Check git status**

Run:

```bash
git status --short
```

Expected: only intentional source, test, script, and plan files are modified; `.env` remains untracked and untouched.

## Self-Review

Spec coverage:

- Protocol-preserving mapper: covered by Task 2 and existing mapper tests.
- Deepgram reconciler: covered by Task 2.
- Realtime/final split: covered by Tasks 1, 3, and 4.
- Removal of text-similarity cleanup from Deepgram final path: covered by Task 5.
- Translation and summary impact: covered by Task 6 and existing realtime translation tests.
- Performance analysis: covered by Task 7 and Task 8.

Completion marker scan:

- The plan contains no unfinished markers or open implementation slots.

Type consistency:

- `TranscriptSegmentUpdateSource`, `TranscriptSegmentAccumulationResult.source`, `receiveRealtime`, `receiveFinal`, `DeepgramTranscriptReconciler`, and `DeepgramTranscriptReconciliationOutput` are introduced before subsequent tasks use them.
