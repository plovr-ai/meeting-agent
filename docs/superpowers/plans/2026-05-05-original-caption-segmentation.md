# Original Caption Segmentation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix new-recording original transcript and live caption segmentation so overlapping Deepgram stable chunks do not duplicate text and only real or conservative semantic boundaries seal user-facing captions.

**Architecture:** Keep `DeepgramStreamingResponseMapper` semantics unchanged. Add canonical overlap cleanup to `TranscriptSegmentAccumulator`, then make `LiveCaptionChunker` overlap-aware and terminal-punctuation-only for soft sentence boundaries.

**Tech Stack:** Swift 5.9, Swift Package Manager, XCTest, macOS 14.2+.

---

## File Structure

- Modify `Sources/MeetingAgentCore/TranscriptSegmentAccumulator.swift`
  - Owns canonical transcript state for new `.upsert` updates.
  - Add token overlap helpers and a post-upsert cleanup pass.
- Modify `Sources/MeetingAgentCore/LiveCaptionChunker.swift`
  - Owns user-facing caption chunk assembly.
  - Add overlap-aware joining and terminal-only punctuation detection.
- Modify `Tests/MeetingAgentCoreTests/TranscriptSegmentAccumulatorTests.swift`
  - Add canonical overlap and issue-shape regressions.
- Modify `Tests/MeetingAgentCoreTests/LiveCaptionChunkerTests.swift`
  - Add overlap-aware caption joining regression and replace the old inline-punctuation boundary expectation.
- Modify `Tests/MeetingAgentCoreTests/CaptionTurnAssemblerTests.swift`
  - Add assembler-level coverage for `speechFinal=false` overlap merging. Existing `testFinalSpeechFinalSegmentSealsHardBoundary` remains the hard-boundary coverage.
- Modify `Tests/MeetingAgentCoreTests/TranscriptFileWriterTests.swift`
  - Add one writer-level rendered transcript regression for the issue #135 shape.

## Task 1: Canonical Transcript Overlap Regressions

**Files:**
- Modify: `Tests/MeetingAgentCoreTests/TranscriptSegmentAccumulatorTests.swift`

- [ ] **Step 1: Add failing accumulator tests**

Add these tests before `testFileBackedTranscriptUpdateSinkPersistsUpdates()`:

```swift
func testUpsertDeduplicatesAdjacentFinalSegmentOverlap() {
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
        "advantage of these public preview features."
    ])
}

func testUpsertTrimsInterimCoveredBySurroundingFinalSegments() {
    var accumulator = TranscriptSegmentAccumulator()

    _ = accumulator.apply(.upsert(deepgramSegment(
        id: "deepgram-transcribe-stream-44.34",
        start: 44.34,
        end: 46.9,
        text: "inside Microsoft Teams, are outlined here,",
        isFinal: true
    )))
    _ = accumulator.apply(.upsert(deepgramSegment(
        id: "deepgram-transcribe-stream-44.5",
        start: 44.5,
        end: 48.42,
        text: "inside Microsoft Teams, which are outlined here, to be able to take",
        isFinal: false
    )))
    let result = accumulator.apply(.upsert(deepgramSegment(
        id: "deepgram-transcribe-stream-47.52",
        start: 47.52,
        end: 52.08,
        text: "to be able to take advantage of these public preview features.",
        isFinal: true
    )))

    XCTAssertEqual(result.document.segments.map(\.id), [
        "deepgram-transcribe-stream-44.34",
        "deepgram-transcribe-stream-47.52"
    ])
    XCTAssertEqual(result.document.segments.map(\.text).joined(separator: " "), """
    inside Microsoft Teams, are outlined here, to be able to take advantage of these public preview features.
    """.trimmingCharacters(in: .whitespacesAndNewlines))
}

func testIssue135MeetingShapeDoesNotRepeatAbleToTake() {
    var accumulator = TranscriptSegmentAccumulator()

    for segment in [
        deepgramSegment(
            id: "deepgram-transcribe-stream-39.9",
            start: 39.9,
            end: 44.1,
            text: "below, as an end user, you have to take some steps",
            isFinal: true
        ),
        deepgramSegment(
            id: "deepgram-transcribe-stream-44.34",
            start: 44.34,
            end: 46.9,
            text: "inside Microsoft Teams, are outlined here,",
            isFinal: true
        ),
        deepgramSegment(
            id: "deepgram-transcribe-stream-44.5",
            start: 44.5,
            end: 48.42,
            text: "inside Microsoft Teams, which are outlined here, to be able to take",
            isFinal: false
        ),
        deepgramSegment(
            id: "deepgram-transcribe-stream-47.52",
            start: 47.52,
            end: 52.08,
            text: "to be able to take advantage of these public preview features. So inside the new Teams client,",
            isFinal: true
        )
    ] {
        _ = accumulator.apply(.upsert(segment))
    }

    let renderedText = accumulator.currentDocument.segments.map(\.text).joined(separator: " ")
    XCTAssertFalse(renderedText.contains("to be able to take to be able to take"))
    XCTAssertEqual(
        renderedText,
        "below, as an end user, you have to take some steps inside Microsoft Teams, are outlined here, to be able to take advantage of these public preview features. So inside the new Teams client,"
    )
}
```

Add this helper inside the test class:

```swift
private func deepgramSegment(
    id: String,
    speaker: String = "deepgram-speaker-0",
    start: Double,
    end: Double,
    text: String,
    isFinal: Bool
) -> TranscriptSegment {
    TranscriptSegment(
        id: id,
        speaker: TranscriptSpeaker(identifier: speaker),
        startTimeSeconds: start,
        endTimeSeconds: end,
        text: text,
        sourceProvider: SpeechTranscriptionConfiguration.defaultDeepgramTranscriptionProviderID,
        isFinal: isFinal,
        speechFinal: false,
        timingSource: .precise
    )
}
```

- [ ] **Step 2: Run focused test to verify failure**

Run:

```sh
swift test --filter TranscriptSegmentAccumulatorTests
```

Expected: FAIL because final/final and final/interim/final overlap cleanup is not implemented.

## Task 2: Canonical Transcript Cleanup Implementation

**Files:**
- Modify: `Sources/MeetingAgentCore/TranscriptSegmentAccumulator.swift`
- Test: `Tests/MeetingAgentCoreTests/TranscriptSegmentAccumulatorTests.swift`

- [ ] **Step 1: Call canonical cleanup after existing interim pruning**

In `applyUpsert(_:)`, replace:

```swift
document.segments = Self.trimmedCoveredInterimPrefixes(document.segments)
document.segments = Self.prunedCoveredInterimSegments(document.segments)
```

with:

```swift
document.segments = Self.trimmedCoveredInterimPrefixes(document.segments)
document.segments = Self.prunedCoveredInterimSegments(document.segments)
document.segments = Self.deduplicatedAdjacentOverlaps(document.segments)
```

- [ ] **Step 2: Add overlap cleanup helpers**

Add these helpers before `speakersAreCompatible(_:_:)`:

```swift
private static func deduplicatedAdjacentOverlaps(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
    guard segments.count > 1 else { return segments }
    var output: [TranscriptSegment] = []

    for segment in segments {
        guard var current = cleaned(segment, after: output.last) else { continue }
        if !current.isFinal {
            current = cleanedInterim(current, previousFinal: output.last)
            guard !current.text.isEmpty else { continue }
        }
        output.append(current)
    }

    guard output.count > 1 else { return output }
    var backwardCleaned = output
    for index in backwardCleaned.indices.dropLast().reversed() {
        let next = backwardCleaned[index + 1]
        guard !backwardCleaned[index].isFinal else { continue }
        let cleaned = cleanedInterim(backwardCleaned[index], nextFinal: next)
        if cleaned.text.isEmpty {
            backwardCleaned.remove(at: index)
        } else {
            backwardCleaned[index] = cleaned
        }
    }
    return backwardCleaned
}

private static func cleaned(_ segment: TranscriptSegment, after previous: TranscriptSegment?) -> TranscriptSegment? {
    guard let previous,
          segmentsCanShareTextBoundary(previous, segment),
          let overlap = suffixPrefixOverlap(previous.text, segment.text),
          overlap.count >= 2
    else {
        return segment
    }
    let text = removingPrefixTokenCount(overlap.count, from: segment.text)
    guard !text.isEmpty else { return nil }
    return rewritten(segment, text: text, startTimeSeconds: segment.startTimeSeconds)
}

private static func cleanedInterim(
    _ segment: TranscriptSegment,
    previousFinal: TranscriptSegment? = nil,
    nextFinal: TranscriptSegment? = nil
) -> TranscriptSegment {
    var current = segment
    if let previousFinal,
       previousFinal.isFinal,
       segmentsCanShareTextBoundary(previousFinal, current),
       let overlap = suffixPrefixOverlap(previousFinal.text, current.text),
       overlap.count >= 2 {
        let text = removingPrefixTokenCount(overlap.count, from: current.text)
        current = rewritten(
            current,
            text: text,
            startTimeSeconds: adjustedStartTime(after: previousFinal, fallback: current.startTimeSeconds)
        )
    }
    if let nextFinal,
       nextFinal.isFinal,
       segmentsCanShareTextBoundary(current, nextFinal),
       let overlap = suffixPrefixOverlap(current.text, nextFinal.text),
       overlap.count >= 2 {
        let text = removingSuffixTokenCount(overlap.count, from: current.text)
        current = rewritten(current, text: text, startTimeSeconds: current.startTimeSeconds)
    }
    return current
}

private static func segmentsCanShareTextBoundary(_ first: TranscriptSegment, _ second: TranscriptSegment) -> Bool {
    guard first.sourceProvider == second.sourceProvider,
          speakersAreCompatible(first.speaker, second.speaker)
    else {
        return false
    }
    return segmentsAreNearby(first, second)
}

private static func segmentsAreNearby(_ first: TranscriptSegment, _ second: TranscriptSegment) -> Bool {
    guard let firstEnd = first.endTimeSeconds,
          let secondStart = second.startTimeSeconds
    else {
        return true
    }
    return secondStart <= firstEnd + 1.25
}

private static func suffixPrefixOverlap(_ first: String, _ second: String) -> [String]? {
    let firstTokens = normalizedTokens(first)
    let secondTokens = normalizedTokens(second)
    let maxOverlap = min(firstTokens.count, secondTokens.count)
    guard maxOverlap > 0 else { return nil }
    for candidate in stride(from: maxOverlap, through: 1, by: -1) {
        let suffix = Array(firstTokens.suffix(candidate))
        let prefix = Array(secondTokens.prefix(candidate))
        if suffix == prefix {
            return suffix
        }
    }
    return nil
}

private static func removingPrefixTokenCount(_ count: Int, from text: String) -> String {
    guard count > 0 else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
    var remaining = count
    var index = text.startIndex
    var insideToken = false
    while index < text.endIndex {
        let scalar = text[index].unicodeScalars.first
        let isToken = scalar.map { CharacterSet.alphanumerics.contains($0) } ?? false
        if isToken {
            insideToken = true
        } else if insideToken {
            remaining -= 1
            insideToken = false
            if remaining == 0 {
                return String(text[index...])
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.;:!?")))
            }
        }
        index = text.index(after: index)
    }
    return remaining <= 1 && insideToken ? "" : text.trimmingCharacters(in: .whitespacesAndNewlines)
}

private static func removingSuffixTokenCount(_ count: Int, from text: String) -> String {
    guard count > 0 else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
    var remaining = count
    var index = text.endIndex
    var insideToken = false
    while index > text.startIndex {
        index = text.index(before: index)
        let scalar = text[index].unicodeScalars.first
        let isToken = scalar.map { CharacterSet.alphanumerics.contains($0) } ?? false
        if isToken {
            insideToken = true
        } else if insideToken {
            remaining -= 1
            insideToken = false
            if remaining == 0 {
                return String(text[..<text.index(after: index)])
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.;:!?")))
            }
        }
    }
    return remaining <= 1 && insideToken ? "" : text.trimmingCharacters(in: .whitespacesAndNewlines)
}

private static func adjustedStartTime(after previous: TranscriptSegment, fallback: Double?) -> Double? {
    guard let previousEnd = previous.endTimeSeconds else { return fallback }
    guard let fallback else { return previousEnd }
    return max(previousEnd, fallback)
}

private static func rewritten(
    _ segment: TranscriptSegment,
    text: String,
    startTimeSeconds: Double?
) -> TranscriptSegment {
    TranscriptSegment(
        id: segment.id,
        speaker: segment.speaker,
        startTimeSeconds: startTimeSeconds,
        endTimeSeconds: segment.endTimeSeconds,
        text: text.trimmingCharacters(in: .whitespacesAndNewlines),
        language: segment.language,
        sourceProvider: segment.sourceProvider,
        isFinal: segment.isFinal,
        speechFinal: segment.speechFinal,
        confidence: segment.confidence,
        createdAt: segment.createdAt,
        timingSource: segment.timingSource,
        translatedText: segment.translatedText,
        translationTargetLocale: segment.translationTargetLocale,
        translationIsFinal: segment.translationIsFinal
    )
}
```

- [ ] **Step 3: Run focused test**

Run:

```sh
swift test --filter TranscriptSegmentAccumulatorTests
```

Expected: PASS with the exact expected strings from Task 1.

- [ ] **Step 4: Commit canonical cleanup**

Run:

```sh
git add Sources/MeetingAgentCore/TranscriptSegmentAccumulator.swift Tests/MeetingAgentCoreTests/TranscriptSegmentAccumulatorTests.swift
git commit -m "fix: deduplicate original transcript overlaps (#135)"
```

## Task 3: Live Caption Chunker Regressions

**Files:**
- Modify: `Tests/MeetingAgentCoreTests/LiveCaptionChunkerTests.swift`

- [ ] **Step 1: Add failing live caption overlap test**

Add this test before `testManualFlushFreezesOpenDraft()`:

```swift
func testJoiningAdjacentFinalChunksRemovesSuffixPrefixOverlap() {
    var chunker = LiveCaptionChunker(sourceLocale: "en-US", targetLocale: "zh-CN")

    _ = chunker.append(segment(
        id: "deepgram-transcribe-stream-44.34",
        text: "inside Microsoft Teams, which are outlined here, to be able to take",
        start: 44.34,
        end: 46.9
    ))
    let updates = chunker.append(segment(
        id: "deepgram-transcribe-stream-47.52",
        text: "to be able to take advantage of these public preview features.",
        start: 47.52,
        end: 52.08
    ))

    XCTAssertEqual(
        updates.last?.turn.originalText,
        "inside Microsoft Teams, which are outlined here, to be able to take advantage of these public preview features."
    )
}
```

- [ ] **Step 2: Replace the inline punctuation expectation**

Replace `testInternalSentenceBoundaryFreezesLongDeepgramChunkBeforeNextSameSpeakerSegment` with:

```swift
func testInlineSentencePunctuationDoesNotCreateBoundaryInLongDeepgramChunk() {
    var chunker = LiveCaptionChunker(
        sourceLocale: "en-US",
        targetLocale: "zh-CN",
        policy: LiveCaptionChunkingPolicy(minPunctuationCharacters: 80)
    )

    let updates = chunker.append(segment(
        id: "deepgram-transcribe-stream-0.00",
        text: "My name is Sherwin Chaffee, and I work at Microsoft as a copilot principal technical specialist. Now on this channel, we often build our own autonomous agents",
        start: 0,
        end: 9.49
    ))

    XCTAssertEqual(updates.single?.turn.chunkState, .draft)
    XCTAssertNil(updates.single?.turn.freezeReason)
}
```

- [ ] **Step 3: Run focused test to verify failure**

Run:

```sh
swift test --filter LiveCaptionChunkerTests
```

Expected: FAIL because `joined` still duplicates overlap and `hasSentenceEndingPunctuation` still uses inline `contains`.

## Task 4: Live Caption Chunker Implementation

**Files:**
- Modify: `Sources/MeetingAgentCore/LiveCaptionChunker.swift`
- Test: `Tests/MeetingAgentCoreTests/LiveCaptionChunkerTests.swift`

- [ ] **Step 1: Replace `joined(_:_:)` with overlap-aware join**

Replace the existing `joined(_:_:)` with:

```swift
private func joined(_ first: String, _ second: String) -> String {
    let first = first.trimmingCharacters(in: .whitespacesAndNewlines)
    let second = second.trimmingCharacters(in: .whitespacesAndNewlines)
    if first.isEmpty { return second }
    if second.isEmpty { return first }
    if let overlap = suffixPrefixOverlap(first, second), overlap >= 2 {
        let trimmedSecond = removingPrefixTokenCount(overlap, from: second)
        if trimmedSecond.isEmpty { return first }
        return "\(first) \(trimmedSecond)"
    }
    return "\(first) \(second)"
}
```

Add these helpers near `joined(_:_:)`:

```swift
private func suffixPrefixOverlap(_ first: String, _ second: String) -> Int? {
    let firstTokens = normalizedTokens(first)
    let secondTokens = normalizedTokens(second)
    let maxOverlap = min(firstTokens.count, secondTokens.count)
    guard maxOverlap > 0 else { return nil }
    for candidate in stride(from: maxOverlap, through: 1, by: -1) {
        if Array(firstTokens.suffix(candidate)) == Array(secondTokens.prefix(candidate)) {
            return candidate
        }
    }
    return nil
}

private func normalizedTokens(_ text: String) -> [String] {
    text
        .lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
}

private func removingPrefixTokenCount(_ count: Int, from text: String) -> String {
    guard count > 0 else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
    var remaining = count
    var index = text.startIndex
    var insideToken = false
    while index < text.endIndex {
        let scalar = text[index].unicodeScalars.first
        let isToken = scalar.map { CharacterSet.alphanumerics.contains($0) } ?? false
        if isToken {
            insideToken = true
        } else if insideToken {
            remaining -= 1
            insideToken = false
            if remaining == 0 {
                return String(text[index...])
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.;:!?")))
            }
        }
        index = text.index(after: index)
    }
    return remaining <= 1 && insideToken ? "" : text.trimmingCharacters(in: .whitespacesAndNewlines)
}
```

- [ ] **Step 2: Make punctuation terminal-only**

Replace `hasSentenceEndingPunctuation(_:)` with:

```swift
private func hasSentenceEndingPunctuation(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let last = trimmed.last else { return false }
    return [".", "!", "?", "。", "！", "？"].contains(String(last))
}
```

- [ ] **Step 3: Run focused tests**

Run:

```sh
swift test --filter LiveCaptionChunkerTests
```

Expected: PASS.

- [ ] **Step 4: Commit live caption cleanup**

Run:

```sh
git add Sources/MeetingAgentCore/LiveCaptionChunker.swift Tests/MeetingAgentCoreTests/LiveCaptionChunkerTests.swift
git commit -m "fix: naturalize original caption chunks (#135)"
```

## Task 5: Assembler And Writer Integration Regressions

**Files:**
- Modify: `Tests/MeetingAgentCoreTests/CaptionTurnAssemblerTests.swift`
- Modify: `Tests/MeetingAgentCoreTests/TranscriptFileWriterTests.swift`

- [ ] **Step 1: Add assembler issue-shape regression**

Add this test before `testFlushSealsOpenFinalDraft()`:

```swift
func testSpeechFinalFalseFinalChunksRemainOpenAndDeduplicateOverlap() {
    var assembler = CaptionTurnAssembler(sourceLocale: "en-US", targetLocale: "zh-CN")

    _ = assembler.apply(segment(
        id: "deepgram-transcribe-stream-44.34",
        startTimeSeconds: 44.34,
        endTimeSeconds: 46.9,
        text: "inside Microsoft Teams, which are outlined here, to be able to take",
        speechFinal: false
    ))
    let events = assembler.apply(segment(
        id: "deepgram-transcribe-stream-47.52",
        startTimeSeconds: 47.52,
        endTimeSeconds: 52.08,
        text: "to be able to take advantage of these public preview features",
        speechFinal: false
    ))

    guard case .draftUpdated(let draft) = events.single else {
        XCTFail("Expected the second speechFinal=false final segment to keep updating the open draft")
        return
    }
    XCTAssertEqual(
        draft.originalText,
        "inside Microsoft Teams, which are outlined here, to be able to take advantage of these public preview features"
    )
    XCTAssertNil(draft.boundaryReason)
    XCTAssertEqual(draft.displayState, .draft)
}
```

- [ ] **Step 2: Add writer rendered transcript regression**

Add this test to `TranscriptFileWriterTests` near the other `upsert` tests:

```swift
func testUpsertRendersIssue135ShapeWithoutRepeatedAdjacentPhrase() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("probe-transcript-\(UUID().uuidString).txt")
    let jsonURL = url.deletingPathExtension().appendingPathExtension("json")
    defer {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: jsonURL)
    }
    let writer = try TranscriptFileWriter(url: url)

    try writer.upsert(TranscriptSegment(
        id: "deepgram-transcribe-stream-44.34",
        speaker: TranscriptSpeaker(identifier: "deepgram-speaker-0"),
        startTimeSeconds: 44.34,
        endTimeSeconds: 46.9,
        text: "inside Microsoft Teams, are outlined here,",
        sourceProvider: SpeechTranscriptionConfiguration.defaultDeepgramTranscriptionProviderID,
        isFinal: true,
        timingSource: .precise
    ))
    try writer.upsert(TranscriptSegment(
        id: "deepgram-transcribe-stream-44.5",
        speaker: TranscriptSpeaker(identifier: "deepgram-speaker-0"),
        startTimeSeconds: 44.5,
        endTimeSeconds: 48.42,
        text: "inside Microsoft Teams, which are outlined here, to be able to take",
        sourceProvider: SpeechTranscriptionConfiguration.defaultDeepgramTranscriptionProviderID,
        isFinal: false,
        timingSource: .precise
    ))
    try writer.upsert(TranscriptSegment(
        id: "deepgram-transcribe-stream-47.52",
        speaker: TranscriptSpeaker(identifier: "deepgram-speaker-0"),
        startTimeSeconds: 47.52,
        endTimeSeconds: 52.08,
        text: "to be able to take advantage of these public preview features.",
        sourceProvider: SpeechTranscriptionConfiguration.defaultDeepgramTranscriptionProviderID,
        isFinal: true,
        timingSource: .precise
    ))

    let transcript = try String(contentsOf: url, encoding: .utf8)
    XCTAssertFalse(transcript.contains("to be able to take to be able to take"))
    XCTAssertEqual(
        transcript.trimmingCharacters(in: .whitespacesAndNewlines),
        "User A:\ninside Microsoft Teams, are outlined here, to be able to take advantage of these public preview features."
    )
}
```

- [ ] **Step 3: Run focused integration tests**

Run:

```sh
swift test --filter CaptionTurnAssemblerTests
swift test --filter TranscriptFileWriterTests
```

Expected: PASS.

- [ ] **Step 4: Commit integration regressions**

Run:

```sh
git add Tests/MeetingAgentCoreTests/CaptionTurnAssemblerTests.swift Tests/MeetingAgentCoreTests/TranscriptFileWriterTests.swift
git commit -m "test: cover issue 135 caption segmentation (#135)"
```

## Task 6: Full Verification

**Files:**
- No source edits unless verification reveals a regression caused by this change.

- [ ] **Step 1: Run focused suites serially**

Run:

```sh
swift test --filter TranscriptSegmentAccumulatorTests
swift test --filter LiveCaptionChunkerTests
swift test --filter CaptionTurnAssemblerTests
swift test --filter TranscriptFileWriterTests
```

Expected: PASS for all four commands.

- [ ] **Step 2: Run required project verification**

Run:

```sh
make test
```

Expected: PASS, including the repository coverage gate.

- [ ] **Step 3: Inspect final diff**

Run:

```sh
git status --short
git diff --stat HEAD~3..HEAD
```

Expected: only issue #135 source/tests/docs are changed.

- [ ] **Step 4: Fix any verification-only regression**

If `make test` fails because of this change, make the smallest targeted fix, rerun the failing command, then rerun `make test`. Commit only the files changed for that verification fix. For example, if the fix touches `Sources/MeetingAgentCore/TranscriptSegmentAccumulator.swift` and `Tests/MeetingAgentCoreTests/TranscriptSegmentAccumulatorTests.swift`, run:

```sh
git add Sources/MeetingAgentCore/TranscriptSegmentAccumulator.swift Tests/MeetingAgentCoreTests/TranscriptSegmentAccumulatorTests.swift
git commit -m "fix: stabilize caption segmentation verification (#135)"
```

Expected: final worktree is clean and all required verification passes.
