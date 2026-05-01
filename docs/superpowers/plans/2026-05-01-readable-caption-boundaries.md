# Readable Caption Boundaries Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tune live caption boundary heuristics so bilingual subtitle turns merge short same-speaker fragments, split at natural sentence endings, and remain observable through boundary reason and strength.

**Architecture:** Keep the behavior inside `LiveCaptionChunker`, because it already owns open chunk state, speaker changes, timing, and freeze metadata. Extend `LiveCaptionChunkingPolicy` with readable-boundary controls while preserving existing initializer compatibility and public behavior. Cover the behavior through `LiveCaptionChunkerTests` and a focused assembler test.

**Tech Stack:** Swift 5.9, Swift Package Manager, XCTest, existing `MeetingAgentCore` model types.

---

### Task 1: Add Regression Tests For Readable Boundaries

**Files:**
- Modify: `Tests/MeetingAgentCoreTests/LiveCaptionChunkerTests.swift`
- Modify: `Tests/MeetingAgentCoreTests/CaptionTurnAssemblerTests.swift`

- [ ] **Step 1: Add short-fragment merge and punctuation-boundary tests**

Insert these tests in `LiveCaptionChunkerTests` near the existing punctuation and speaker-change tests:

```swift
func testSameSpeakerShortFragmentsMergeWhenTimingIsClose() {
    var chunker = LiveCaptionChunker(
        sourceLocale: "en-US",
        targetLocale: "zh-CN",
        policy: LiveCaptionChunkingPolicy(
            readableCharacterLimit: 80,
            shortFragmentCharacters: 24,
            maxMergeGapSeconds: 1.25,
            minSentenceBoundaryCharacters: 30
        )
    )

    _ = chunker.append(segment(id: "s1", text: "Let's align", start: 0, end: 0.7))
    let updates = chunker.append(segment(id: "s2", text: "on the launch owner", start: 0.9, end: 1.8))

    XCTAssertEqual(updates.single?.turn.originalText, "Let's align on the launch owner")
    XCTAssertEqual(updates.single?.turn.sourceSegmentIDs, ["s1", "s2"])
    XCTAssertEqual(updates.single?.turn.displayState, .draft)
    XCTAssertNil(updates.single?.turn.boundaryReason)
    XCTAssertNil(updates.single?.turn.boundaryStrength)
}

func testTerminalSentencePunctuationCreatesSoftBoundaryAtReadableLength() {
    var chunker = LiveCaptionChunker(
        sourceLocale: "en-US",
        targetLocale: "zh-CN",
        policy: LiveCaptionChunkingPolicy(minSentenceBoundaryCharacters: 18)
    )

    let updates = chunker.append(segment(id: "s1", text: "That sounds good."))

    XCTAssertEqual(updates.last?.turn.displayState, .sealed)
    XCTAssertEqual(updates.last?.turn.boundaryReason, .punctuation)
    XCTAssertEqual(updates.last?.turn.boundaryStrength, .soft)
    XCTAssertEqual(updates.last?.turn.translationState, .draft)
}

func testInlinePunctuationDoesNotCreateSentenceBoundary() {
    var chunker = LiveCaptionChunker(
        sourceLocale: "en-US",
        targetLocale: "zh-CN",
        policy: LiveCaptionChunkingPolicy(minSentenceBoundaryCharacters: 10)
    )

    let updates = chunker.append(segment(id: "s1", text: "Yes, we can continue with rollout planning"))

    XCTAssertEqual(updates.single?.turn.displayState, .draft)
    XCTAssertNil(updates.single?.turn.boundaryReason)
    XCTAssertNil(updates.single?.turn.boundaryStrength)
}
```

- [ ] **Step 2: Add readable limit and assembler tests**

Insert this test in `LiveCaptionChunkerTests` near `testMaxLengthFreezesLongDraft`:

```swift
func testReadableCharacterLimitFreezesBeforeHardMaximum() {
    var chunker = LiveCaptionChunker(
        sourceLocale: "en-US",
        targetLocale: "zh-CN",
        policy: LiveCaptionChunkingPolicy(
            maxCharacters: 120,
            readableCharacterLimit: 48,
            minSentenceBoundaryCharacters: 80
        )
    )

    let updates = chunker.append(segment(
        id: "s1",
        text: "This caption is already long enough to become difficult to scan"
    ))

    XCTAssertEqual(updates.last?.turn.displayState, .sealed)
    XCTAssertEqual(updates.last?.turn.boundaryReason, .maxLength)
    XCTAssertEqual(updates.last?.turn.boundaryStrength, .soft)
}
```

Insert this test in `CaptionTurnAssemblerTests` near `testSameSpeakerFinalSegmentsMergeUntilHardBoundary`:

```swift
func testAssemblerUsesReadableChunkingPolicyForSoftSentenceBoundary() {
    var assembler = CaptionTurnAssembler(
        sourceLocale: "en-US",
        targetLocale: "zh-CN",
        policy: LiveCaptionChunkingPolicy(minSentenceBoundaryCharacters: 18)
    )

    let events = assembler.apply(segment(
        id: "segment-1",
        text: "That sounds good.",
        speechFinal: false
    ))

    guard case .sealed(let sealed) = events.last else {
        XCTFail("Expected readable sentence punctuation to seal a soft boundary")
        return
    }
    XCTAssertEqual(sealed.boundaryReason, .punctuation)
    XCTAssertEqual(sealed.boundaryStrength, .soft)
}
```

- [ ] **Step 3: Run focused tests and confirm they fail**

Run:

```bash
swift test --filter LiveCaptionChunkerTests
swift test --filter CaptionTurnAssemblerTests
```

Expected before implementation: failures because `LiveCaptionChunkingPolicy` does not yet accept the new readable-boundary fields and punctuation still uses the old `minPunctuationCharacters` behavior.

### Task 2: Implement Policy Fields And Boundary Heuristics

**Files:**
- Modify: `Sources/MeetingAgentCore/LiveCaptionChunker.swift`

- [ ] **Step 1: Extend `LiveCaptionChunkingPolicy`**

Update the struct to include new stored properties and initializer parameters:

```swift
public struct LiveCaptionChunkingPolicy: Equatable {
    public var maxCharacters: Int
    public var maxDurationSeconds: Double
    public var minPunctuationCharacters: Int
    public var readableCharacterLimit: Int
    public var shortFragmentCharacters: Int
    public var maxMergeGapSeconds: Double
    public var minSentenceBoundaryCharacters: Int

    public init(
        maxCharacters: Int = 240,
        maxDurationSeconds: Double = 10,
        minPunctuationCharacters: Int = 80,
        readableCharacterLimit: Int = 140,
        shortFragmentCharacters: Int = 24,
        maxMergeGapSeconds: Double = 1.25,
        minSentenceBoundaryCharacters: Int = 36
    ) {
        self.maxCharacters = maxCharacters
        self.maxDurationSeconds = maxDurationSeconds
        self.minPunctuationCharacters = minPunctuationCharacters
        self.readableCharacterLimit = readableCharacterLimit
        self.shortFragmentCharacters = shortFragmentCharacters
        self.maxMergeGapSeconds = maxMergeGapSeconds
        self.minSentenceBoundaryCharacters = minSentenceBoundaryCharacters
    }
}
```

- [ ] **Step 2: Replace punctuation and length checks**

Update `freezeReason(for:latestSegment:)`:

```swift
private func freezeReason(for chunk: OpenChunk, latestSegment: TranscriptSegment) -> LiveCaptionFreezeReason? {
    if latestSegment.speechFinal { return .speechFinal }
    if chunk.turn.originalText.count >= policy.maxCharacters { return .maxLength }
    if chunk.turn.originalText.count >= policy.readableCharacterLimit,
       !shouldKeepMergingShortFragment(chunk, latestSegment: latestSegment) {
        return .maxLength
    }
    if durationSeconds(for: chunk) >= policy.maxDurationSeconds,
       hasSentenceEndingPunctuation(chunk.turn.originalText) {
        return .maxDuration
    }
    if sentenceBoundaryCharacterLimit(for: chunk.turn.originalText) <= chunk.turn.originalText.count,
       hasSentenceEndingPunctuation(chunk.turn.originalText),
       !shouldKeepMergingShortFragment(chunk, latestSegment: latestSegment) {
        return .punctuation
    }
    return nil
}
```

- [ ] **Step 3: Add helper methods**

Add helpers below `durationSeconds(for:)`:

```swift
private func shouldKeepMergingShortFragment(_ chunk: OpenChunk, latestSegment: TranscriptSegment) -> Bool {
    guard chunk.turn.sourceSegmentIDs.count > 1 else { return false }
    guard latestSegment.text.trimmingCharacters(in: .whitespacesAndNewlines).count <= policy.shortFragmentCharacters else {
        return false
    }
    guard let previousEnd = chunk.previousEndTimeSeconds,
          let latestStart = latestSegment.startTimeSeconds
    else {
        return true
    }
    return max(0, latestStart - previousEnd) <= policy.maxMergeGapSeconds
}

private func sentenceBoundaryCharacterLimit(for text: String) -> Int {
    if containsCJKCharacter(text) {
        return max(12, policy.minSentenceBoundaryCharacters / 2)
    }
    return policy.minSentenceBoundaryCharacters
}

private func containsCJKCharacter(_ text: String) -> Bool {
    text.unicodeScalars.contains { scalar in
        (0x4E00...0x9FFF).contains(Int(scalar.value))
            || (0x3040...0x30FF).contains(Int(scalar.value))
            || (0xAC00...0xD7AF).contains(Int(scalar.value))
    }
}

private func hasSentenceEndingPunctuation(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    for marker in [".", "!", "?", "。", "！", "？"] where trimmed.contains(marker) {
        return true
    }
    return false
}
```

- [ ] **Step 4: Track previous end timing**

Extend `OpenChunk`:

```swift
private struct OpenChunk: Equatable {
    var turn: LiveCaptionTurn
    var startTimeSeconds: Double?
    var endTimeSeconds: Double?
    var previousEndTimeSeconds: Double?
}
```

When returning a merged chunk for a new segment, set `previousEndTimeSeconds: openChunk.endTimeSeconds`. For replacement of the same segment ID and for a brand-new chunk, keep `previousEndTimeSeconds` from the prior chunk or `nil` as appropriate.

- [ ] **Step 5: Run focused tests**

Run:

```bash
swift test --filter LiveCaptionChunkerTests
swift test --filter CaptionTurnAssemblerTests
```

Expected: both pass.

### Task 3: Full Verification And Commit

**Files:**
- Modify: `Sources/MeetingAgentCore/LiveCaptionChunker.swift`
- Modify: `Tests/MeetingAgentCoreTests/LiveCaptionChunkerTests.swift`
- Modify: `Tests/MeetingAgentCoreTests/CaptionTurnAssemblerTests.swift`

- [ ] **Step 1: Run required verification**

Run:

```bash
make test
```

Expected: all tests pass and coverage gate remains passing.

- [ ] **Step 2: Inspect final diff**

Run:

```bash
git diff
git status --short
```

Expected: only the chunker, chunker tests, assembler tests, spec, and plan files are changed.

- [ ] **Step 3: Commit implementation**

Run:

```bash
git add Sources/MeetingAgentCore/LiveCaptionChunker.swift Tests/MeetingAgentCoreTests/LiveCaptionChunkerTests.swift Tests/MeetingAgentCoreTests/CaptionTurnAssemblerTests.swift docs/superpowers/plans/2026-05-01-readable-caption-boundaries.md
git commit -m "feat: tune readable caption boundaries (#122)"
```
