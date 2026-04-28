# Live Caption Chunked Translation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix #36 by translating long same-speaker speech as incrementally updated draft chunks, then freezing completed chunks so already completed text is not retranslated.

**Architecture:** Add Deepgram `speech_final` metadata to finalized transcript segments, introduce a pure `LiveCaptionChunker` that turns finalized STT segments into draft/frozen caption turns, then split caption translation scheduling into draft updates and one-time final translations. The view model owns chunker state and translation request revision checks; transcript capture remains append-only.

**Tech Stack:** Swift 5.9, Swift Package Manager, XCTest, macOS 14.2+, existing `MeetingAgentCore` live caption and Deepgram streaming providers.

---

## File Structure

- Modify `Sources/MeetingAgentCore/TranscriptSegment.swift`
  - Add backward-compatible `speechFinal` metadata to `TranscriptSegment`.
- Modify `Sources/MeetingAgentCore/DeepgramTranscriptionProvider.swift`
  - Add `endpointing=500`.
  - Decode `speech_final`.
  - Mark only the final speaker run from one Deepgram final response as `speechFinal`.
- Create `Sources/MeetingAgentCore/LiveCaptionChunker.swift`
  - Own draft/frozen chunking rules and emit deterministic updates.
- Modify `Sources/MeetingAgentCore/LiveMeetingCockpit.swift`
  - Add `LiveCaptionChunkState`, `LiveCaptionFreezeReason`, `translationRevision`.
  - Replace same-speaker infinite merge with chunk upsert/freeze operations.
- Modify `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
  - Route transcript segments through `LiveCaptionChunker`.
  - Schedule draft and final translations separately.
  - Discard stale draft translation responses.
  - Freeze open draft on stop.
- Modify tests:
  - `Tests/MeetingAgentCoreTests/DeepgramStreamingTranscriptionProviderTests.swift`
  - `Tests/MeetingAgentCoreTests/DeepgramTranscriptionProviderTests.swift`
  - `Tests/MeetingAgentCoreTests/TranscriptFileWriterTests.swift`
  - `Tests/MeetingAgentCoreTests/LiveCaptionChunkerTests.swift` (new)
  - `Tests/MeetingAgentCoreTests/LiveCaptionStoreTests.swift`
  - `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

## Task 1: Transcript and Deepgram Boundary Metadata

**Files:**
- Modify: `Sources/MeetingAgentCore/TranscriptSegment.swift`
- Modify: `Sources/MeetingAgentCore/DeepgramTranscriptionProvider.swift`
- Test: `Tests/MeetingAgentCoreTests/TranscriptFileWriterTests.swift`
- Test: `Tests/MeetingAgentCoreTests/DeepgramStreamingTranscriptionProviderTests.swift`
- Test: `Tests/MeetingAgentCoreTests/DeepgramTranscriptionProviderTests.swift`

- [ ] **Step 1: Add failing test for backward-compatible `speechFinal` decoding**

Add this test to `Tests/MeetingAgentCoreTests/TranscriptFileWriterTests.swift`:

```swift
func testTranscriptSegmentDecodesMissingSpeechFinalAsFalse() throws {
    let data = Data("""
    {
      "version": 1,
      "segments": [
        {
          "id": "segment-1",
          "text": "hello",
          "sourceProvider": "deepgram-transcribe",
          "isFinal": true,
          "createdAt": "2026-04-28T00:00:00Z",
          "timingSource": "unavailable"
        }
      ]
    }
    """.utf8)

    let document = try JSONDecoder.meetingAgent.decode(TranscriptDocument.self, from: data)

    XCTAssertEqual(document.segments.first?.speechFinal, false)
}
```

- [ ] **Step 2: Add failing Deepgram mapper test for `speech_final`**

Add this test to `Tests/MeetingAgentCoreTests/DeepgramStreamingTranscriptionProviderTests.swift`:

```swift
func testStreamingResponseMarksOnlyLastSpeakerRunAsSpeechFinal() throws {
    let segments = DeepgramStreamingResponseMapper.segments(
        from: Data("""
        {
          "is_final": true,
          "speech_final": true,
          "channel": {
            "alternatives": [
              {
                "transcript": "hello yes",
                "confidence": 0.91,
                "words": [
                  { "word": "hello", "punctuated_word": "Hello.", "start": 0.0, "end": 0.4, "speaker": 0 },
                  { "word": "yes", "punctuated_word": "Yes.", "start": 0.5, "end": 0.8, "speaker": 1 }
                ]
              }
            ]
          }
        }
        """.utf8),
        localeIdentifier: "en-US",
        providerID: "deepgram-transcribe"
    )

    XCTAssertEqual(segments.map(\\.text), ["Hello.", "Yes."])
    XCTAssertEqual(segments.map(\\.speechFinal), [false, true])
}
```

- [ ] **Step 3: Add failing Deepgram connection test for endpointing**

In `Tests/MeetingAgentCoreTests/DeepgramStreamingTranscriptionProviderTests.swift`, update `testStreamingClientBuildsWebSocketRequest` to assert:

```swift
XCTAssertEqual(components.queryItemsByName["endpointing"], "500")
```

If the file does not have `queryItemsByName`, add this helper near the test file bottom:

```swift
private extension URLComponents {
    var queryItemsByName: [String: String] {
        Dictionary(uniqueKeysWithValues: (queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
    }
}
```

- [ ] **Step 4: Run focused tests and verify they fail**

Run:

```bash
swift test --filter TranscriptFileWriterTests/testTranscriptSegmentDecodesMissingSpeechFinalAsFalse
swift test --filter DeepgramStreamingTranscriptionProviderTests/testStreamingResponseMarksOnlyLastSpeakerRunAsSpeechFinal
swift test --filter DeepgramStreamingTranscriptionProviderTests/testStreamingClientBuildsWebSocketRequest
```

Expected: failures because `speechFinal` and `endpointing` do not exist yet.

- [ ] **Step 5: Implement `TranscriptSegment.speechFinal`**

In `Sources/MeetingAgentCore/TranscriptSegment.swift`, add the property:

```swift
public let speechFinal: Bool
```

Update the initializer signature and assignment:

```swift
speechFinal: Bool = false,
```

```swift
self.speechFinal = speechFinal
```

Add custom coding keys and decoding with defaults so older transcript JSON remains readable:

```swift
private enum CodingKeys: String, CodingKey {
    case id
    case speakerID
    case speakerLabel
    case startTimeSeconds
    case endTimeSeconds
    case text
    case language
    case sourceProvider
    case isFinal
    case speechFinal
    case confidence
    case createdAt
    case timingSource
}

public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    speakerID = try container.decodeIfPresent(String.self, forKey: .speakerID)
    speakerLabel = try container.decodeIfPresent(String.self, forKey: .speakerLabel)
    startTimeSeconds = try container.decodeIfPresent(Double.self, forKey: .startTimeSeconds)
    endTimeSeconds = try container.decodeIfPresent(Double.self, forKey: .endTimeSeconds)
    text = try container.decode(String.self, forKey: .text)
    language = try container.decodeIfPresent(String.self, forKey: .language)
    sourceProvider = try container.decodeIfPresent(String.self, forKey: .sourceProvider) ?? "unknown"
    isFinal = try container.decodeIfPresent(Bool.self, forKey: .isFinal) ?? true
    speechFinal = try container.decodeIfPresent(Bool.self, forKey: .speechFinal) ?? false
    confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
    createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    timingSource = try container.decodeIfPresent(TranscriptTimingSource.self, forKey: .timingSource) ?? .unavailable
}
```

- [ ] **Step 6: Implement Deepgram `speech_final` and endpointing**

In `Sources/MeetingAgentCore/DeepgramTranscriptionProvider.swift`, add the query item:

```swift
URLQueryItem(name: "endpointing", value: "500")
```

In `DeepgramStreamingResponse`, add:

```swift
let speechFinal: Bool?
```

and coding key:

```swift
case speechFinal = "speech_final"
```

In `DeepgramStreamingResponseMapper.segments`, after constructing candidate runs, apply `speechFinal` only to the last segment:

```swift
let speechFinal = response.speechFinal == true
let mapped = runs.compactMap { run -> TranscriptSegment? in
    let text = run.words
        .map { $0.displayText }
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    let firstWord = run.words.first
    let lastWord = run.words.last
    return TranscriptSegment(
        speaker: speaker(for: run.speaker),
        startTimeSeconds: firstWord?.start,
        endTimeSeconds: lastWord?.end,
        text: text,
        language: localeIdentifier,
        sourceProvider: providerID,
        confidence: alternative.confidence,
        timingSource: firstWord?.start == nil && lastWord?.end == nil ? .unavailable : .precise
    )
}
guard speechFinal, !mapped.isEmpty else { return mapped }
return mapped.enumerated().map { index, segment in
    TranscriptSegment(
        id: segment.id,
        speaker: segment.speaker,
        startTimeSeconds: segment.startTimeSeconds,
        endTimeSeconds: segment.endTimeSeconds,
        text: segment.text,
        language: segment.language,
        sourceProvider: segment.sourceProvider,
        isFinal: segment.isFinal,
        speechFinal: index == mapped.count - 1,
        confidence: segment.confidence,
        createdAt: segment.createdAt,
        timingSource: segment.timingSource
    )
}
```

For the no-words fallback, set `speechFinal: response.speechFinal == true`.

- [ ] **Step 7: Run focused tests and commit**

Run:

```bash
swift test --filter TranscriptFileWriterTests/testTranscriptSegmentDecodesMissingSpeechFinalAsFalse
swift test --filter DeepgramStreamingTranscriptionProviderTests/testStreamingResponseMarksOnlyLastSpeakerRunAsSpeechFinal
swift test --filter DeepgramStreamingTranscriptionProviderTests/testStreamingClientBuildsWebSocketRequest
```

Expected: PASS.

Commit:

```bash
git add Sources/MeetingAgentCore/TranscriptSegment.swift Sources/MeetingAgentCore/DeepgramTranscriptionProvider.swift Tests/MeetingAgentCoreTests/TranscriptFileWriterTests.swift Tests/MeetingAgentCoreTests/DeepgramStreamingTranscriptionProviderTests.swift
git commit -m "feat: carry Deepgram speech final metadata"
```

## Task 2: Pure Live Caption Chunker

**Files:**
- Create: `Sources/MeetingAgentCore/LiveCaptionChunker.swift`
- Test: `Tests/MeetingAgentCoreTests/LiveCaptionChunkerTests.swift`

- [ ] **Step 1: Write failing chunker tests**

Create `Tests/MeetingAgentCoreTests/LiveCaptionChunkerTests.swift`:

```swift
import XCTest
@testable import MeetingAgentCore

final class LiveCaptionChunkerTests: XCTestCase {
    func testSpeechFinalFreezesDraftChunk() {
        var chunker = LiveCaptionChunker(sourceLocale: "en-US", targetLocale: "zh-CN")

        let updates = chunker.append(segment(
            id: "s1",
            text: "We should launch.",
            speechFinal: true
        ))

        XCTAssertEqual(updates.count, 2)
        XCTAssertEqual(updates.first?.turn.chunkState, .draft)
        XCTAssertEqual(updates.last?.turn.chunkState, .frozen)
        XCTAssertEqual(updates.last?.turn.freezeReason, .speechFinal)
        XCTAssertEqual(updates.last?.turn.originalText, "We should launch.")
    }

    func testSpeakerChangeFreezesPreviousChunkAndStartsNewDraft() {
        var chunker = LiveCaptionChunker(sourceLocale: "en-US", targetLocale: "zh-CN")
        _ = chunker.append(segment(id: "a1", speaker: "a", text: "First speaker"))

        let updates = chunker.append(segment(id: "b1", speaker: "b", text: "Second speaker"))

        XCTAssertEqual(updates.map { $0.turn.originalText }, ["First speaker", "Second speaker"])
        XCTAssertEqual(updates.map { $0.turn.chunkState }, [.frozen, .draft])
        XCTAssertEqual(updates.first?.turn.freezeReason, .speakerChanged)
    }

    func testMaxLengthFreezesLongDraft() {
        var chunker = LiveCaptionChunker(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            policy: LiveCaptionChunkingPolicy(maxCharacters: 20)
        )

        let updates = chunker.append(segment(id: "s1", text: "This is a source segment that is long enough."))

        XCTAssertEqual(updates.last?.turn.chunkState, .frozen)
        XCTAssertEqual(updates.last?.turn.freezeReason, .maxLength)
    }

    func testMaxDurationFreezesTimedDraft() {
        var chunker = LiveCaptionChunker(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            policy: LiveCaptionChunkingPolicy(maxDurationSeconds: 2)
        )

        let updates = chunker.append(segment(
            id: "s1",
            text: "Timed segment",
            start: 0,
            end: 3
        ))

        XCTAssertEqual(updates.last?.turn.chunkState, .frozen)
        XCTAssertEqual(updates.last?.turn.freezeReason, .maxDuration)
    }

    func testPunctuationFreezesWhenMinimumLengthReached() {
        var chunker = LiveCaptionChunker(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            policy: LiveCaptionChunkingPolicy(minPunctuationCharacters: 10)
        )

        let updates = chunker.append(segment(id: "s1", text: "That sounds good."))

        XCTAssertEqual(updates.last?.turn.chunkState, .frozen)
        XCTAssertEqual(updates.last?.turn.freezeReason, .punctuation)
    }

    func testManualFlushFreezesOpenDraft() {
        var chunker = LiveCaptionChunker(sourceLocale: "en-US", targetLocale: "zh-CN")
        _ = chunker.append(segment(id: "s1", text: "Still open"))

        let updates = chunker.flushOpenChunk(reason: .manualStop)

        XCTAssertEqual(updates.single?.turn.chunkState, .frozen)
        XCTAssertEqual(updates.single?.turn.freezeReason, .manualStop)
    }

    private func segment(
        id: String,
        speaker: String = "speaker-1",
        text: String,
        start: Double? = nil,
        end: Double? = nil,
        speechFinal: Bool = false
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            speaker: TranscriptSpeaker(identifier: speaker),
            startTimeSeconds: start,
            endTimeSeconds: end,
            text: text,
            language: "en-US",
            sourceProvider: "deepgram-transcribe",
            speechFinal: speechFinal,
            timingSource: start == nil && end == nil ? .unavailable : .precise
        )
    }
}

private extension Array {
    var single: Element? {
        count == 1 ? first : nil
    }
}
```

- [ ] **Step 2: Run chunker tests and verify they fail**

Run:

```bash
swift test --filter LiveCaptionChunkerTests
```

Expected: FAIL because `LiveCaptionChunker`, `LiveCaptionChunkingPolicy`, and new turn metadata do not exist.

- [ ] **Step 3: Add live caption turn metadata**

In `Sources/MeetingAgentCore/LiveMeetingCockpit.swift`, add:

```swift
public enum LiveCaptionChunkState: String, Codable, Equatable {
    case draft
    case frozen
}

public enum LiveCaptionFreezeReason: String, Codable, Equatable {
    case speechFinal
    case speakerChanged
    case maxLength
    case maxDuration
    case punctuation
    case manualStop
}
```

Add fields to `LiveCaptionTurn`:

```swift
public var chunkState: LiveCaptionChunkState
public var translationRevision: Int
public var freezeReason: LiveCaptionFreezeReason?
```

Update the initializer with defaults:

```swift
chunkState: LiveCaptionChunkState = .frozen,
translationRevision: Int = 0,
freezeReason: LiveCaptionFreezeReason? = nil
```

Update coding keys and explicit decode defaults:

```swift
chunkState = try container.decodeIfPresent(LiveCaptionChunkState.self, forKey: .chunkState) ?? .frozen
translationRevision = try container.decodeIfPresent(Int.self, forKey: .translationRevision) ?? 0
freezeReason = try container.decodeIfPresent(LiveCaptionFreezeReason.self, forKey: .freezeReason)
```

- [ ] **Step 4: Implement `LiveCaptionChunker`**

Create `Sources/MeetingAgentCore/LiveCaptionChunker.swift`:

```swift
import Foundation

public struct LiveCaptionChunkingPolicy: Equatable {
    public var maxCharacters: Int
    public var maxDurationSeconds: Double
    public var minPunctuationCharacters: Int

    public init(
        maxCharacters: Int = 240,
        maxDurationSeconds: Double = 10,
        minPunctuationCharacters: Int = 80
    ) {
        self.maxCharacters = maxCharacters
        self.maxDurationSeconds = maxDurationSeconds
        self.minPunctuationCharacters = minPunctuationCharacters
    }
}

public struct LiveCaptionChunkUpdate: Equatable {
    public let turn: LiveCaptionTurn

    public init(turn: LiveCaptionTurn) {
        self.turn = turn
    }
}

public struct LiveCaptionChunker: Equatable {
    private var openTurn: LiveCaptionTurn?
    private let policy: LiveCaptionChunkingPolicy
    private let sourceLocale: String
    private let targetLocale: String

    public init(
        sourceLocale: String,
        targetLocale: String,
        policy: LiveCaptionChunkingPolicy = LiveCaptionChunkingPolicy()
    ) {
        self.sourceLocale = sourceLocale
        self.targetLocale = targetLocale
        self.policy = policy
    }

    public mutating func append(_ segment: TranscriptSegment) -> [LiveCaptionChunkUpdate] {
        guard segment.isFinal else { return [] }
        var updates: [LiveCaptionChunkUpdate] = []

        if let openTurn, openTurn.speaker != segment.speaker {
            updates.append(LiveCaptionChunkUpdate(turn: frozen(openTurn, reason: .speakerChanged)))
            self.openTurn = nil
        }

        let draft = mergedDraft(appending: segment)
        openTurn = draft
        updates.append(LiveCaptionChunkUpdate(turn: draft))

        if let reason = freezeReason(for: draft, latestSegment: segment) {
            let final = frozen(draft, reason: reason)
            openTurn = nil
            updates.append(LiveCaptionChunkUpdate(turn: final))
        }

        return updates
    }

    public mutating func flushOpenChunk(reason: LiveCaptionFreezeReason) -> [LiveCaptionChunkUpdate] {
        guard let openTurn else { return [] }
        self.openTurn = nil
        return [LiveCaptionChunkUpdate(turn: frozen(openTurn, reason: reason))]
    }

    private mutating func mergedDraft(appending segment: TranscriptSegment) -> LiveCaptionTurn {
        if let openTurn {
            return LiveCaptionTurn(
                id: openTurn.id,
                sourceSegmentID: segment.id,
                sourceSegmentIDs: openTurn.sourceSegmentIDs + [segment.id],
                speaker: segment.speaker,
                originalText: joined(openTurn.originalText, segment.text),
                translatedText: openTurn.translatedText,
                sourceLocale: segment.language ?? sourceLocale,
                targetLocale: targetLocale,
                isFinal: true,
                captionHealth: .live,
                translationHealth: .pending,
                createdAt: segment.createdAt,
                chunkState: .draft,
                translationRevision: openTurn.translationRevision + 1,
                freezeReason: nil
            )
        }

        return LiveCaptionTurn(
            sourceSegmentID: segment.id,
            speaker: segment.speaker,
            originalText: segment.text,
            sourceLocale: segment.language ?? sourceLocale,
            targetLocale: targetLocale,
            isFinal: true,
            captionHealth: .live,
            translationHealth: .pending,
            createdAt: segment.createdAt,
            chunkState: .draft,
            translationRevision: 1,
            freezeReason: nil
        )
    }

    private func freezeReason(for turn: LiveCaptionTurn, latestSegment: TranscriptSegment) -> LiveCaptionFreezeReason? {
        if latestSegment.speechFinal { return .speechFinal }
        if turn.originalText.count >= policy.maxCharacters { return .maxLength }
        if durationSeconds(for: turn, latestSegment: latestSegment) >= policy.maxDurationSeconds { return .maxDuration }
        if turn.originalText.count >= policy.minPunctuationCharacters && hasStrongPunctuation(turn.originalText) {
            return .punctuation
        }
        return nil
    }

    private func durationSeconds(for turn: LiveCaptionTurn, latestSegment: TranscriptSegment) -> Double {
        guard let latestEnd = latestSegment.endTimeSeconds else { return 0 }
        let starts = [latestSegment.startTimeSeconds].compactMap { $0 }
        guard let earliestStart = starts.min() else { return 0 }
        return latestEnd - earliestStart
    }

    private func frozen(_ turn: LiveCaptionTurn, reason: LiveCaptionFreezeReason) -> LiveCaptionTurn {
        LiveCaptionTurn(
            id: turn.id,
            sourceSegmentID: turn.sourceSegmentID,
            sourceSegmentIDs: turn.sourceSegmentIDs,
            speaker: turn.speaker,
            originalText: turn.originalText,
            translatedText: turn.translatedText,
            sourceLocale: turn.sourceLocale,
            targetLocale: turn.targetLocale,
            isFinal: true,
            captionHealth: turn.captionHealth,
            translationHealth: .pending,
            createdAt: turn.createdAt,
            chunkState: .frozen,
            translationRevision: turn.translationRevision,
            freezeReason: reason
        )
    }

    private func joined(_ first: String, _ second: String) -> String {
        let first = first.trimmingCharacters(in: .whitespacesAndNewlines)
        let second = second.trimmingCharacters(in: .whitespacesAndNewlines)
        if first.isEmpty { return second }
        if second.isEmpty { return first }
        return "\(first) \(second)"
    }

    private func hasStrongPunctuation(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return [".", "!", "?", "。", "！", "？"].contains { trimmed.hasSuffix($0) }
    }
}
```

Before running tests, update the implementation above so duration uses private open chunk metadata instead of only the latest segment. Add this nested state to `LiveCaptionChunker`:

```swift
private struct OpenChunk: Equatable {
    var turn: LiveCaptionTurn
    var startTimeSeconds: Double?
    var endTimeSeconds: Double?
}
```

Change the stored property:

```swift
private var openChunk: OpenChunk?
```

When appending a segment to an existing chunk, compute:

```swift
let start = [openChunk.startTimeSeconds, segment.startTimeSeconds].compactMap { $0 }.min()
let end = [openChunk.endTimeSeconds, segment.endTimeSeconds].compactMap { $0 }.max()
self.openChunk = OpenChunk(turn: draft, startTimeSeconds: start, endTimeSeconds: end)
```

When starting a new chunk, compute:

```swift
self.openChunk = OpenChunk(
    turn: draft,
    startTimeSeconds: segment.startTimeSeconds,
    endTimeSeconds: segment.endTimeSeconds
)
```

Replace `durationSeconds(for:latestSegment:)` with:

```swift
private func durationSeconds(for openChunk: OpenChunk?) -> Double {
    guard let start = openChunk?.startTimeSeconds,
          let end = openChunk?.endTimeSeconds
    else {
        return 0
    }
    return max(0, end - start)
}
```

Call it from `freezeReason` as:

```swift
if durationSeconds(for: openChunk) >= policy.maxDurationSeconds { return .maxDuration }
```

- [ ] **Step 5: Run chunker tests and commit**

Run:

```bash
swift test --filter LiveCaptionChunkerTests
```

Expected: PASS.

Commit:

```bash
git add Sources/MeetingAgentCore/LiveMeetingCockpit.swift Sources/MeetingAgentCore/LiveCaptionChunker.swift Tests/MeetingAgentCoreTests/LiveCaptionChunkerTests.swift
git commit -m "feat: add live caption chunker"
```

## Task 3: Replace Same-Speaker Infinite Merge With Chunk Upsert/Freeze

**Files:**
- Modify: `Sources/MeetingAgentCore/LiveMeetingCockpit.swift`
- Test: `Tests/MeetingAgentCoreTests/LiveCaptionStoreTests.swift`

- [ ] **Step 1: Write failing store tests**

In `Tests/MeetingAgentCoreTests/LiveCaptionStoreTests.swift`, replace the expectation that same-speaker final segments always merge into one turn with:

```swift
func testUpsertingDraftUpdatesSameTurn() {
    var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
    let draft = LiveCaptionTurn(
        sourceSegmentID: "segment-1",
        originalText: "first",
        isFinal: true,
        chunkState: .draft,
        translationRevision: 1
    )
    let updatedDraft = LiveCaptionTurn(
        id: draft.id,
        sourceSegmentID: "segment-2",
        sourceSegmentIDs: ["segment-1", "segment-2"],
        originalText: "first second",
        isFinal: true,
        chunkState: .draft,
        translationRevision: 2
    )

    store.upsert(draft)
    store.upsert(updatedDraft)

    XCTAssertEqual(store.turns.count, 1)
    XCTAssertEqual(store.turns.first?.originalText, "first second")
    XCTAssertEqual(store.turns.first?.translationRevision, 2)
}

func testFrozenSameSpeakerTurnDoesNotMergeWithLaterDraft() {
    var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
    let frozen = LiveCaptionTurn(
        sourceSegmentID: "segment-1",
        speaker: TranscriptSpeaker(identifier: "speaker-1"),
        originalText: "finished",
        isFinal: true,
        chunkState: .frozen,
        freezeReason: .speechFinal
    )
    let nextDraft = LiveCaptionTurn(
        sourceSegmentID: "segment-2",
        speaker: TranscriptSpeaker(identifier: "speaker-1"),
        originalText: "new thought",
        isFinal: true,
        chunkState: .draft,
        translationRevision: 1
    )

    store.upsert(frozen)
    store.upsert(nextDraft)

    XCTAssertEqual(store.turns.map(\\.originalText), ["finished", "new thought"])
}
```

- [ ] **Step 2: Run store tests and verify they fail**

Run:

```bash
swift test --filter LiveCaptionStoreTests/testUpsertingDraftUpdatesSameTurn
swift test --filter LiveCaptionStoreTests/testFrozenSameSpeakerTurnDoesNotMergeWithLaterDraft
```

Expected: FAIL because `upsert` does not exist or existing append still merges.

- [ ] **Step 3: Add `LiveCaptionStore.upsert`**

In `Sources/MeetingAgentCore/LiveMeetingCockpit.swift`, add:

```swift
@discardableResult
public mutating func upsert(_ turn: LiveCaptionTurn) -> LiveCaptionTurn {
    if let index = turns.firstIndex(where: { $0.id == turn.id }) {
        let previous = turns[index]
        var updated = turn
        if !((previous.translatedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
           updated.translatedText == nil {
            updated.translatedText = previous.translatedText
        }
        turns[index] = updated
        return updated
    }
    turns.append(turn)
    return turn
}
```

Keep `append(_ segment:)` temporarily for existing tests, but stop using it from the view model in Task 4. Update the old same-speaker merge tests in this task so they assert the new chunked behavior: draft turns upsert in place, frozen turns remain separate from later same-speaker draft turns.

- [ ] **Step 4: Run store tests and commit**

Run:

```bash
swift test --filter LiveCaptionStoreTests
```

Expected: PASS after updating obsolete merge expectations.

Commit:

```bash
git add Sources/MeetingAgentCore/LiveMeetingCockpit.swift Tests/MeetingAgentCoreTests/LiveCaptionStoreTests.swift
git commit -m "feat: upsert chunked live caption turns"
```

## Task 4: Draft and Final Translation Scheduling

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] **Step 1: Add failing view-model regression tests**

Add tests to `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift` using the existing fake translation provider patterns:

First update `ViewModelFakeTextTranslationProvider` in the same file so tests can change translations between draft revisions and inspect translated source text:

```swift
var requestedSegmentTexts: [[String]] = []
var translations: [String: String]
```

Replace the current immutable translation storage:

```swift
private let translations: [String: String]
```

with the mutable `var translations` above, and add this line at the start of `translate(transcript:options:)` after appending `requests`:

```swift
requestedSegmentTexts.append(transcript.segments.map(\.text))
```

```swift
func testDraftCaptionTranslationUpdatesSameTurnAsTextGrows() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(baseDirectory: root)
    let record = try store.createMeeting(name: "Meet", startedAt: Date()).record
    let writer = try TranscriptFileWriter(url: XCTUnwrap(record.transcriptURL), structuredURL: XCTUnwrap(record.transcriptJSONURL))
    try writer.replace(with: [
        TranscriptSegment(id: "segment-1", speaker: TranscriptSpeaker(identifier: "speaker-1"), text: "This is the first part", language: "en-US")
    ])
    let provider = ViewModelFakeTextTranslationProvider(translations: ["segment-1": "第一部分"])
    let viewModel = MeetingAgentViewModel(
        store: store,
        processTargetsProvider: { [] },
        captionTranslationProviderFactory: { _ in provider }
    )
    try viewModel.loadMeetings()
    viewModel.selectMeeting(record.id)

    viewModel.drainRecordingFrames()
    try await waitFor { viewModel.liveCaptionTurns.first?.translatedText == "第一部分" }

    try writer.replace(with: [
        TranscriptSegment(id: "segment-1", speaker: TranscriptSpeaker(identifier: "speaker-1"), text: "This is the first part", language: "en-US"),
        TranscriptSegment(id: "segment-2", speaker: TranscriptSpeaker(identifier: "speaker-1"), text: "and the second part", language: "en-US")
    ])
    provider.translations = ["segment-2": "第一部分和第二部分"]

    viewModel.drainRecordingFrames()
    try await waitFor { viewModel.liveCaptionTurns.first?.translatedText == "第一部分和第二部分" }

    XCTAssertEqual(viewModel.liveCaptionTurns.count, 1)
    XCTAssertEqual(provider.requestedSegmentTexts.last, ["This is the first part and the second part"])
}
```

Add a stale response test:

```swift
func testOlderDraftTranslationDoesNotOverwriteNewerDraft() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(baseDirectory: root)
    let record = try store.createMeeting(name: "Meet", startedAt: Date()).record
    let writer = try TranscriptFileWriter(url: XCTUnwrap(record.transcriptURL), structuredURL: XCTUnwrap(record.transcriptJSONURL))
    let provider = DelayedViewModelFakeTextTranslationProvider()
    let viewModel = MeetingAgentViewModel(
        store: store,
        processTargetsProvider: { [] },
        captionTranslationProviderFactory: { _ in provider }
    )
    try viewModel.loadMeetings()
    viewModel.selectMeeting(record.id)

    try writer.replace(with: [
        TranscriptSegment(id: "segment-1", speaker: TranscriptSpeaker(identifier: "speaker-1"), text: "first draft", language: "en-US")
    ])
    viewModel.drainRecordingFrames()
    try await waitFor { provider.pendingRequestCount == 1 }

    try writer.replace(with: [
        TranscriptSegment(id: "segment-1", speaker: TranscriptSpeaker(identifier: "speaker-1"), text: "first draft", language: "en-US"),
        TranscriptSegment(id: "segment-2", speaker: TranscriptSpeaker(identifier: "speaker-1"), text: "second draft", language: "en-US")
    ])
    viewModel.drainRecordingFrames()
    try await waitFor { provider.pendingRequestCount == 2 }

    provider.completeRequest(at: 1, targetText: "newer translation")
    try await waitFor { viewModel.liveCaptionTurns.first?.translatedText == "newer translation" }
    provider.completeRequest(at: 0, targetText: "older translation")
    try await Task.sleep(nanoseconds: 50_000_000)

    XCTAssertEqual(viewModel.liveCaptionTurns.first?.translatedText, "newer translation")
}
```

Add this fake near the existing view-model test fakes:

```swift
private final class DelayedViewModelFakeTextTranslationProvider: TextTranslationProvider {
    struct PendingRequest {
        let transcript: TranscriptDocument
        let continuation: CheckedContinuation<TranslatedTranscript, Error>
    }

    let descriptor = ProviderDescriptor(
        id: "delayed-view-model-translation",
        displayName: "Delayed Translation",
        capability: .textTranslation,
        executionMode: .hosted,
        supportedSourceLocales: ["*"],
        supportedTargetLocales: ["*"],
        requiresNetwork: false,
        requiresAPIKey: false
    )

    private(set) var pendingRequests: [PendingRequest] = []

    var pendingRequestCount: Int {
        pendingRequests.count
    }

    func translate(transcript: TranscriptDocument, options: TranslationOptions) async throws -> TranslatedTranscript {
        try await withCheckedThrowingContinuation { continuation in
            pendingRequests.append(PendingRequest(transcript: transcript, continuation: continuation))
        }
    }

    func completeRequest(at index: Int, targetText: String) {
        let request = pendingRequests[index]
        let source = request.transcript.segments[0]
        request.continuation.resume(returning: TranslatedTranscript(
            sourceLocale: source.language ?? "en-US",
            targetLocale: "zh-CN",
            segments: [
                BilingualSubtitleSegment(
                    id: source.id,
                    startTimeSeconds: source.startTimeSeconds,
                    endTimeSeconds: source.endTimeSeconds,
                    speaker: source.speaker,
                    sourceText: source.text,
                    targetText: targetText,
                    confidence: source.confidence,
                    providerChain: ["delayed-view-model-translation"]
                )
            ],
            provenance: PipelineProvenance(profileID: "delayed-view-model-translation")
        ))
    }
}
```

- [ ] **Step 2: Run new view-model tests and verify they fail**

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testDraftCaptionTranslationUpdatesSameTurnAsTextGrows
swift test --filter MeetingAgentViewModelTests/testOlderDraftTranslationDoesNotOverwriteNewerDraft
```

Expected: FAIL because view model still reads transcript segments directly into `LiveCaptionStore.append` and has no revision guard.

- [ ] **Step 3: Add chunker state to `MeetingAgentViewModel`**

In `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`, add properties:

```swift
private var liveCaptionChunker = LiveCaptionChunker(sourceLocale: "en-US", targetLocale: "zh-CN")
private var processedLiveCaptionSegmentIDs = Set<String>()
private var draftTranslationKeysByTurnID: [String: String] = [:]
private var draftTranslationInFlightByTurnID: [String: Int] = [:]
private var draftTranslationCharacterCountsByTurnID: [String: Int] = [:]
private var draftTranslationAttemptDatesByTurnID: [String: Date] = [:]
private var finalTranslationKeysByTurnID: [String: String] = [:]
```

In `resetLiveCaptionStore()`, reset both store and chunker:

```swift
liveCaptionChunker = LiveCaptionChunker(
    sourceLocale: speechConfiguration.localeIdentifier,
    targetLocale: speechConfiguration.targetLocaleIdentifier
)
processedLiveCaptionSegmentIDs.removeAll()
draftTranslationKeysByTurnID.removeAll()
draftTranslationInFlightByTurnID.removeAll()
draftTranslationCharacterCountsByTurnID.removeAll()
draftTranslationAttemptDatesByTurnID.removeAll()
finalTranslationKeysByTurnID.removeAll()
```

- [ ] **Step 4: Route transcript segments through chunker**

Replace the loop in `refreshLiveCaptionTurnsFromSelectedMeeting`:

```swift
for segment in document.segments where segment.isFinal && !processedLiveCaptionSegmentIDs.contains(segment.id) {
    processedLiveCaptionSegmentIDs.insert(segment.id)
    for update in liveCaptionChunker.append(segment) {
        liveCaptionStore.upsert(update.turn)
    }
}
```

Keep existing realtime translation attachment after upserting:

```swift
liveCaptionTurns = liveCaptionStore.turns
meetingProgressHealth.caption = liveCaptionTurns.isEmpty ? .idle : .live
attachRealtimeTranslationsToLiveCaptions()
scheduleCaptionTextTranslationIfNeeded()
```

- [ ] **Step 5: Split translation candidate selection**

Replace `scheduleCaptionTextTranslationIfNeeded` with logic that selects draft and frozen turns separately. Add constants near the view-model private properties:

```swift
private let minDraftTranslationCharacterDelta = 80
private let minDraftTranslationInterval: TimeInterval = 2
```

Add this helper:

```swift
private func shouldTranslateDraftCaption(_ turn: LiveCaptionTurn, now: Date = Date()) -> Bool {
    let key = draftCaptionTranslationKey(for: turn)
    if draftTranslationKeysByTurnID[turn.id] == nil {
        return true
    }
    if draftTranslationKeysByTurnID[turn.id] == key {
        return false
    }
    let previousCount = draftTranslationCharacterCountsByTurnID[turn.id] ?? 0
    if turn.originalText.count - previousCount >= minDraftTranslationCharacterDelta {
        return true
    }
    let previousAttempt = draftTranslationAttemptDatesByTurnID[turn.id] ?? .distantPast
    return now.timeIntervalSince(previousAttempt) >= minDraftTranslationInterval
}
```

```swift
let draftCandidates = liveCaptionStore.turns.filter { turn in
    guard turn.chunkState == .draft, turn.translationHealth == .pending else { return false }
    return shouldTranslateDraftCaption(turn)
        && draftTranslationInFlightByTurnID[turn.id] != turn.translationRevision
}

let finalCandidates = liveCaptionStore.turns.filter { turn in
    guard turn.chunkState == .frozen, turn.translationHealth == .pending else { return false }
    let key = finalCaptionTranslationKey(for: turn)
    return finalTranslationKeysByTurnID[turn.id] != key
        && !captionTranslationInFlightTurnIDs.contains(turn.id)
}
```

When enqueueing a draft request, record the attempt metadata:

```swift
draftTranslationInFlightByTurnID[turn.id] = turn.translationRevision
draftTranslationAttemptDatesByTurnID[turn.id] = Date()
```

When a draft response is accepted, record:

```swift
draftTranslationKeysByTurnID[request.turn.id] = request.key
draftTranslationCharacterCountsByTurnID[request.turn.id] = current.originalText.count
```

This gives the UI fast first draft translation, then refreshes the draft when either 80 new characters arrive or 2 seconds have elapsed since the last attempt.

- [ ] **Step 6: Implement revision-guarded translation**

Add:

```swift
private struct CaptionTranslationRequest {
    let turn: LiveCaptionTurn
    let key: String
    let isDraft: Bool
    let revision: Int
}
```

Update translation execution to pass requests. When a draft response returns:

```swift
guard let current = liveCaptionStore.turns.first(where: { $0.id == request.turn.id }),
      current.translationRevision == request.revision,
      current.chunkState == .draft
else {
    return
}
liveCaptionStore.attachTranslation(translatedText, toTurnID: request.turn.id)
draftTranslationKeysByTurnID[request.turn.id] = request.key
```

For final responses:

```swift
guard liveCaptionStore.turns.contains(where: { $0.id == request.turn.id && $0.chunkState == .frozen }) else {
    return
}
liveCaptionStore.attachTranslation(translatedText, toTurnID: request.turn.id)
finalTranslationKeysByTurnID[request.turn.id] = request.key
```

- [ ] **Step 7: Run focused tests and commit**

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testDraftCaptionTranslationUpdatesSameTurnAsTextGrows
swift test --filter MeetingAgentViewModelTests/testOlderDraftTranslationDoesNotOverwriteNewerDraft
```

Expected: PASS.

Commit:

```bash
git add Sources/MeetingAgentCore/MeetingAgentViewModel.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift
git commit -m "feat: translate draft and frozen caption chunks"
```

## Task 5: Freeze Open Draft on Stop and Verify End-to-End Behavior

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] **Step 1: Add failing stop-freeze test**

Add to `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`:

```swift
func testStoppingRecordingFreezesOpenDraftCaptionForFinalTranslation() async throws {
    let fixture = try ViewModelRecorderFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let target = AudioCaptureTarget(processID: 42, displayName: "Meet", bundleIdentifier: nil)
    let provider = ViewModelFakeTextTranslationProvider(translations: ["segment-1": "最终翻译"])
    let viewModel = MeetingAgentViewModel(
        store: fixture.store,
        recorder: fixture.recorder,
        processTargetsProvider: { [target] },
        captionTranslationProviderFactory: { _ in provider }
    )

    try await viewModel.startRecording(for: target)
    let record = try XCTUnwrap(viewModel.selectedMeeting)
    let writer = try TranscriptFileWriter(url: XCTUnwrap(record.transcriptURL), structuredURL: XCTUnwrap(record.transcriptJSONURL))
    try writer.replace(with: [
        TranscriptSegment(id: "segment-1", speaker: TranscriptSpeaker(identifier: "speaker-1"), text: "unfinished thought", language: "en-US")
    ])

    viewModel.drainRecordingFrames()
    XCTAssertEqual(viewModel.liveCaptionTurns.first?.chunkState, .draft)

    viewModel.stopRecording()

    XCTAssertEqual(viewModel.liveCaptionTurns.first?.chunkState, .frozen)
    XCTAssertEqual(viewModel.liveCaptionTurns.first?.freezeReason, .manualStop)
}
```

- [ ] **Step 2: Run stop-freeze test and verify it fails**

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testStoppingRecordingFreezesOpenDraftCaptionForFinalTranslation
```

Expected: FAIL because stop does not flush chunker.

- [ ] **Step 3: Implement flush on stop**

In `MeetingAgentViewModel.stopRecording(at:)`, after recorder stop succeeds and before clearing active IDs:

```swift
for update in liveCaptionChunker.flushOpenChunk(reason: .manualStop) {
    liveCaptionStore.upsert(update.turn)
}
liveCaptionTurns = liveCaptionStore.turns
scheduleCaptionTextTranslationIfNeeded()
```

Also call the same helper from target-ended stop path if `stopRecordingIfTargetProcessEnded` stops an active recording:

```swift
freezeOpenLiveCaptionChunk(reason: .manualStop)
```

Implement helper:

```swift
private func freezeOpenLiveCaptionChunk(reason: LiveCaptionFreezeReason) {
    for update in liveCaptionChunker.flushOpenChunk(reason: reason) {
        liveCaptionStore.upsert(update.turn)
    }
    liveCaptionTurns = liveCaptionStore.turns
    scheduleCaptionTextTranslationIfNeeded()
}
```

- [ ] **Step 4: Run focused stop test and commit**

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testStoppingRecordingFreezesOpenDraftCaptionForFinalTranslation
```

Expected: PASS.

Commit:

```bash
git add Sources/MeetingAgentCore/MeetingAgentViewModel.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift
git commit -m "feat: freeze open caption chunk on recording stop"
```

## Task 6: Regression Sweep and Required Verification

**Files:**
- Modify: `Tests/MeetingAgentCoreTests/DeepgramStreamingTranscriptionProviderTests.swift`
- Modify: `Tests/MeetingAgentCoreTests/LiveCaptionChunkerTests.swift`
- Modify: `Tests/MeetingAgentCoreTests/LiveCaptionStoreTests.swift`
- Modify: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] **Step 1: Run the focused live caption suite**

Run:

```bash
swift test --filter DeepgramStreamingTranscriptionProviderTests
swift test --filter LiveCaptionChunkerTests
swift test --filter LiveCaptionStoreTests
swift test --filter MeetingAgentViewModelTests
```

Expected: PASS. Update any remaining same-speaker merge assertions in `LiveCaptionStoreTests` and `MeetingAgentViewModelTests` so they expect a draft turn to update in place before freezing, and a frozen turn to remain separate from later same-speaker draft turns.

- [ ] **Step 2: Run required project verification**

Run:

```bash
make test
```

Expected: PASS, including coverage enforcement.

- [ ] **Step 3: Inspect git diff for unrelated changes**

Run:

```bash
git status --short
git diff --stat
```

Expected: only #36 implementation files and tests are changed. Do not include pre-existing UI changes in `Sources/MeetingAgentApp/MainWindowView.swift` or `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift` unless the user explicitly asks to include them.

- [ ] **Step 4: Final commit if verification changes were needed**

Commit any test-only fixes from Step 1 or Step 2:

```bash
git add Sources/MeetingAgentCore Tests/MeetingAgentCoreTests
git commit -m "test: cover chunked caption translation regressions"
```

When all verification passes, do not create an empty commit.
