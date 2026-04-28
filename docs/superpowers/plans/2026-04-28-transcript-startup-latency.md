# Transcript Startup Latency Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce initial live subtitle delay by rendering Deepgram interim transcript results and preserving startup audio frames until the transcriber is ready.

**Architecture:** Deepgram streaming responses become structured transcript segments as soon as they contain non-empty text. Segment writes use upsert semantics so interim updates replace the active interim row and final responses replace it with durable text. `MeetingRecorder` separately protects early audio frames by buffering transcription-only copies while the async transcriber starts.

**Tech Stack:** Swift 5.9, Swift Package Manager, XCTest, macOS audio capture abstractions.

---

## File Structure

- Modify `Sources/MeetingAgentCore/TranscriptFileWriter.swift` to add `upsert(_:)`, preserving existing `append(_:)` for callers that need append-only behavior.
- Modify `Sources/MeetingAgentCore/DeepgramTranscriptionProvider.swift` to map interim responses, generate stable streaming ids, and call `upsert(_:)`.
- Modify `Sources/MeetingAgentCore/MeetingAgentViewModel.swift` to feed interim and final segments into `LiveCaptionStore`.
- Modify `Sources/MeetingAgentCore/MeetingRecorder.swift` to buffer early transcription frames and flush them after transcriber startup.
- Modify `Tests/MeetingAgentCoreTests/DeepgramStreamingTranscriptionProviderTests.swift` for interim mapping and upsert behavior.
- Modify `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift` for interim caption visibility and final-only translation scheduling.
- Modify `Tests/MeetingAgentCoreTests/MeetingRecorderTests.swift` for startup frame buffering.

### Task 1: Transcript Upsert Primitive

**Files:**
- Modify: `Sources/MeetingAgentCore/TranscriptFileWriter.swift`
- Test: `Tests/MeetingAgentCoreTests/TranscriptFileWriterTests.swift`

- [ ] **Step 1: Add failing upsert test**

Add this test to `TranscriptFileWriterTests`:

```swift
func testUpsertReplacesExistingSegmentWithSameID() throws {
    let url = temporaryURL("transcript-upsert.txt")
    defer {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("json"))
    }
    let writer = try TranscriptFileWriter(url: url)

    try writer.upsert(TranscriptSegment(id: "active", text: "hello", isFinal: false))
    try writer.upsert(TranscriptSegment(id: "active", text: "hello world", isFinal: true))

    let document = try TranscriptFileWriter.readDocument(from: url.deletingPathExtension().appendingPathExtension("json"))
    XCTAssertEqual(document.segments.map(\.id), ["active"])
    XCTAssertEqual(document.segments.map(\.text), ["hello world"])
    XCTAssertEqual(document.segments.map(\.isFinal), [true])
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "hello world")
}
```

- [ ] **Step 2: Run test to verify failure**

Run: `swift test --filter TranscriptFileWriterTests/testUpsertReplacesExistingSegmentWithSameID`

Expected: compile failure because `TranscriptFileWriter` has no `upsert` method.

- [ ] **Step 3: Implement upsert**

Add this method beside `append(_:)`:

```swift
public func upsert(_ segment: TranscriptSegment) throws {
    guard !isClosed else { return }
    var document = try Self.readDocument(from: structuredURL)
    if let index = document.segments.firstIndex(where: { $0.id == segment.id }) {
        document.segments[index] = segment
    } else {
        document.segments.append(segment)
    }
    try replace(with: document.segments)
}
```

- [ ] **Step 4: Run test to verify pass**

Run: `swift test --filter TranscriptFileWriterTests/testUpsertReplacesExistingSegmentWithSameID`

Expected: PASS.

### Task 2: Deepgram Interim Mapping And Streaming Upsert

**Files:**
- Modify: `Sources/MeetingAgentCore/DeepgramTranscriptionProvider.swift`
- Test: `Tests/MeetingAgentCoreTests/DeepgramStreamingTranscriptionProviderTests.swift`

- [ ] **Step 1: Add failing mapper test**

Add a test proving interim text maps to a non-final segment:

```swift
func testStreamingResponseMapsInterimTranscriptToNonFinalSegment() throws {
    let data = Data("""
    {
      "is_final": false,
      "channel": {
        "alternatives": [
          { "transcript": "hello interim", "confidence": 0.6, "words": [] }
        ]
      }
    }
    """.utf8)

    let segments = DeepgramStreamingResponseMapper.segments(
        from: data,
        localeIdentifier: "en-US",
        providerID: "deepgram-transcribe"
    )

    XCTAssertEqual(segments.count, 1)
    XCTAssertEqual(segments.first?.text, "hello interim")
    XCTAssertEqual(segments.first?.isFinal, false)
}
```

- [ ] **Step 2: Add failing streaming replacement test**

Extend `testStreamingProviderSendsAudioFramesAndWritesIncomingTranscriptSegments` or add a new test that yields an interim JSON and then a final JSON with the same active result, then asserts the structured transcript contains one final segment with the final text.

- [ ] **Step 3: Run tests to verify failure**

Run: `swift test --filter DeepgramStreamingTranscriptionProviderTests`

Expected: interim mapper test fails because interim responses are dropped; replacement test fails because streaming writes append or does not emit interim.

- [ ] **Step 4: Implement interim mapping and upsert**

Change the mapper guard so it accepts `response.isFinal != nil` instead of only `true`, pass `isFinal: response.isFinal == true` to each `TranscriptSegment`, and assign a stable id for active streaming results. For responses without provider ids from Deepgram, use a deterministic id built from provider and timing when available, falling back to `"deepgram-stream-active"`.

In `DeepgramStreamingTranscriber`, replace `writer.append(segment)` with `writer.upsert(segment)`.

- [ ] **Step 5: Run Deepgram tests**

Run: `swift test --filter DeepgramStreamingTranscriptionProviderTests`

Expected: PASS.

### Task 3: Show Interim Captions In ViewModel

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] **Step 1: Add failing view model test**

Add a test that writes a structured transcript with `isFinal: false`, calls the existing refresh path through `drainRecordingFrames()`, and asserts `liveCaptionTurns` contains the interim text with `isFinal == false`.

- [ ] **Step 2: Run test to verify failure**

Run: `swift test --filter MeetingAgentViewModelTests/<new-test-name>`

Expected: FAIL because refresh currently filters `where segment.isFinal`.

- [ ] **Step 3: Implement refresh change**

Change:

```swift
for segment in document.segments where segment.isFinal {
    _ = liveCaptionStore.append(segment)
}
```

to:

```swift
for segment in document.segments {
    _ = liveCaptionStore.append(segment)
}
```

- [ ] **Step 4: Run focused test**

Run: `swift test --filter MeetingAgentViewModelTests/<new-test-name>`

Expected: PASS.

### Task 4: Buffer Startup Frames Until Transcriber Ready

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingRecorder.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingRecorderTests.swift`

- [ ] **Step 1: Add failing recorder test**

Add a test that starts recording with a transcriber factory that suspends, pushes and drains a frame before the factory resumes, then resumes the factory and verifies the transcriber received that early frame.

- [ ] **Step 2: Run test to verify failure**

Run: `swift test --filter MeetingRecorderTests/<new-test-name>`

Expected: FAIL because frames drained before transcriber assignment are not sent to the transcriber.

- [ ] **Step 3: Implement pending transcription frame buffer**

Add private state:

```swift
private var pendingTranscriptionFrames: [AudioFrame] = []
private var isStartingTranscriber = false
private let pendingTranscriptionFrameLimit = 512
```

Set `isStartingTranscriber = true` before awaiting the transcriber factory. After assignment, set it false and flush pending frames in order with existing failure handling. In `drainFrames()`, if `transcriber` is nil and `isStartingTranscriber` is true, append frames to the pending buffer with oldest-frame dropping at the limit. If startup fails, clear pending frames.

- [ ] **Step 4: Run focused recorder test**

Run: `swift test --filter MeetingRecorderTests/<new-test-name>`

Expected: PASS.

### Task 5: Full Verification And Commit

**Files:**
- All changed files from previous tasks.

- [ ] **Step 1: Run focused test group**

Run:

```bash
swift test --filter TranscriptFileWriterTests/testUpsertReplacesExistingSegmentWithSameID
swift test --filter DeepgramStreamingTranscriptionProviderTests
swift test --filter MeetingAgentViewModelTests/<new-test-name>
swift test --filter MeetingRecorderTests/<new-test-name>
```

Expected: PASS.

- [ ] **Step 2: Run required project test command**

Run: `make test`

Expected: PASS.

- [ ] **Step 3: Commit implementation**

Run:

```bash
git add Sources/MeetingAgentCore/TranscriptFileWriter.swift Sources/MeetingAgentCore/DeepgramTranscriptionProvider.swift Sources/MeetingAgentCore/MeetingAgentViewModel.swift Sources/MeetingAgentCore/MeetingRecorder.swift Tests/MeetingAgentCoreTests/TranscriptFileWriterTests.swift Tests/MeetingAgentCoreTests/DeepgramStreamingTranscriptionProviderTests.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift Tests/MeetingAgentCoreTests/MeetingRecorderTests.swift docs/superpowers/specs/2026-04-28-transcript-startup-latency-design.md docs/superpowers/plans/2026-04-28-transcript-startup-latency.md
git commit -m "feat: reduce transcript startup latency (#46)"
```

Expected: commit succeeds.

