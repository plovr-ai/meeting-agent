# Merge Same-Speaker Transcript Turns Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Consecutive final transcript segments from the same speaker render as one live caption turn instead of separate blocks.

**Architecture:** Implement the behavior in `LiveCaptionStore.append(_:)` so all consumers receive merged turn state. Keep duplicate segment ID updates first, then merge only adjacent final same-speaker turns. Clear stale translations whenever source text changes.

**Tech Stack:** Swift 5.9, SwiftPM, XCTest, `MeetingAgentCore`.

---

## File Structure

- Modify `Sources/MeetingAgentCore/LiveMeetingCockpit.swift`: update `LiveCaptionTurn` and `LiveCaptionStore.append(_:)`, add private merge helpers, and support appending multiple translations into a merged turn.
- Modify `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`: attach realtime final translations into merged captions until each represented source segment has one translation.
- Modify `Tests/MeetingAgentCoreTests/LiveCaptionStoreTests.swift`: add focused regression tests for same-speaker merging and preserved separation/update behavior.
- Modify `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`: update realtime translation expectations for merged same-speaker captions.

### Task 1: Add Failing Same-Speaker Merge Tests

**Files:**
- Test: `Tests/MeetingAgentCoreTests/LiveCaptionStoreTests.swift`

- [ ] **Step 1: Add regression tests**

Add these tests to `LiveCaptionStoreTests`:

```swift
func testAppendingFinalSegmentFromSameSpeakerMergesIntoLatestTurn() {
    var store = LiveCaptionStore(sourceLocale: "zh-CN", targetLocale: "en-US")
    let speaker = TranscriptSpeaker(identifier: "speaker-1", label: "User 1")
    _ = store.append(TranscriptSegment(
        id: "segment-1",
        speaker: speaker,
        text: "我们先看一下",
        language: "zh-CN",
        isFinal: true,
        createdAt: Date(timeIntervalSince1970: 100)
    ))

    let merged = store.append(TranscriptSegment(
        id: "segment-2",
        speaker: speaker,
        text: "这个季度的目标",
        language: "zh-CN",
        isFinal: true,
        createdAt: Date(timeIntervalSince1970: 120)
    ))

    XCTAssertEqual(store.turns.count, 1)
    XCTAssertEqual(merged.id, "segment-1")
    XCTAssertEqual(merged.sourceSegmentID, "segment-2")
    XCTAssertEqual(merged.originalText, "我们先看一下 这个季度的目标")
    XCTAssertEqual(merged.speaker, speaker)
    XCTAssertEqual(merged.sourceLocale, "zh-CN")
    XCTAssertEqual(merged.targetLocale, "en-US")
    XCTAssertTrue(merged.isFinal)
    XCTAssertEqual(merged.translationHealth, .pending)
    XCTAssertEqual(merged.createdAt, Date(timeIntervalSince1970: 120))
}

func testAppendingFinalSegmentFromDifferentSpeakerCreatesNewTurn() {
    var store = LiveCaptionStore(sourceLocale: "zh-CN", targetLocale: "en-US")
    _ = store.append(TranscriptSegment(
        id: "segment-1",
        speaker: TranscriptSpeaker(identifier: "speaker-1", label: "User 1"),
        text: "我们先看一下",
        language: "zh-CN",
        isFinal: true
    ))

    _ = store.append(TranscriptSegment(
        id: "segment-2",
        speaker: TranscriptSpeaker(identifier: "speaker-2", label: "User 2"),
        text: "我有一个问题",
        language: "zh-CN",
        isFinal: true
    ))

    XCTAssertEqual(store.turns.count, 2)
    XCTAssertEqual(store.turns.map(\.originalText), ["我们先看一下", "我有一个问题"])
}

func testMergingSameSpeakerClearsStaleTranslation() {
    var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
    let speaker = TranscriptSpeaker(identifier: "speaker-1", label: "User 1")
    _ = store.append(TranscriptSegment(id: "segment-1", speaker: speaker, text: "first", language: "en-US", isFinal: true))
    store.attachTranslation("第一句", toTurnID: "segment-1")

    let merged = store.append(TranscriptSegment(id: "segment-2", speaker: speaker, text: "second", language: "en-US", isFinal: true))

    XCTAssertEqual(merged.originalText, "first second")
    XCTAssertNil(merged.translatedText)
    XCTAssertEqual(merged.translationHealth, .pending)
    XCTAssertNil(store.turns.first?.translatedText)
    XCTAssertEqual(store.turns.first?.translationHealth, .pending)
}
```

- [ ] **Step 2: Run focused tests and confirm failure**

Run: `swift test --filter LiveCaptionStoreTests`

Expected: FAIL because `LiveCaptionStore.append(_:)` still appends same-speaker final segments as separate turns.

### Task 2: Implement Merge in LiveCaptionStore

**Files:**
- Modify: `Sources/MeetingAgentCore/LiveMeetingCockpit.swift`
- Test: `Tests/MeetingAgentCoreTests/LiveCaptionStoreTests.swift`

- [ ] **Step 1: Update append logic**

In `LiveCaptionStore.append(_:)`, keep the existing duplicate `sourceSegmentID` update block before any new merge logic. After that block, add a same-speaker merge path before `turns.append(turn)`:

```swift
if let index = mergeTargetIndex(for: turn) {
    turns[index] = mergedTurn(turns[index], appending: turn)
    return turns[index]
}
turns.append(turn)
return turn
```

- [ ] **Step 2: Add merge helpers**

Add these private helpers inside `LiveCaptionStore`:

```swift
private func mergeTargetIndex(for turn: LiveCaptionTurn) -> Int? {
    guard turn.isFinal,
          let lastIndex = turns.indices.last,
          turns[lastIndex].isFinal,
          turns[lastIndex].speaker == turn.speaker
    else {
        return nil
    }
    return lastIndex
}

private func mergedTurn(_ existing: LiveCaptionTurn, appending turn: LiveCaptionTurn) -> LiveCaptionTurn {
    var merged = existing
    merged.sourceSegmentID = turn.sourceSegmentID
    merged.originalText = joinedTranscriptText(existing.originalText, turn.originalText)
    merged.sourceLocale = turn.sourceLocale
    merged.targetLocale = turn.targetLocale
    merged.isFinal = turn.isFinal
    merged.captionHealth = turn.captionHealth
    merged.translatedText = nil
    merged.translationHealth = .pending
    merged.createdAt = turn.createdAt
    return merged
}

private func joinedTranscriptText(_ first: String, _ second: String) -> String {
    let trimmedFirst = first.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedSecond = second.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedFirst.isEmpty {
        return trimmedSecond
    }
    if trimmedSecond.isEmpty {
        return trimmedFirst
    }
    return "\(trimmedFirst) \(trimmedSecond)"
}
```

- [ ] **Step 3: Run focused tests and confirm pass**

Run: `swift test --filter LiveCaptionStoreTests`

Expected: PASS.

### Task 3: Preserve Realtime Translation Attachment for Merged Captions

**Files:**
- Modify: `Sources/MeetingAgentCore/LiveMeetingCockpit.swift`
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Test: `Tests/MeetingAgentCoreTests/LiveCaptionStoreTests.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] **Step 1: Track represented source segments**

Add `sourceSegmentIDs` to `LiveCaptionTurn`, defaulting to `[sourceSegmentID]`, and preserve backward decoding by defaulting missing `sourceSegmentIDs` to `[sourceSegmentID]`.

- [ ] **Step 2: Append source segment IDs during merge**

When `LiveCaptionStore` merges same-speaker turns, append the new turn's `sourceSegmentIDs` into the existing turn so consumers know how many final source segments the display turn represents.

- [ ] **Step 3: Add append-translation behavior**

Add `LiveCaptionStore.appendTranslation(_:toTurnID:)` to join multiple realtime target text finals into one merged turn without changing `attachTranslation(_:toTurnID:)`, which still replaces a turn's translation for one-shot translation providers.

- [ ] **Step 4: Update realtime attachment counts**

In `MeetingAgentViewModel`, track `realtimeTranslationAttachmentCountsByCaptionID`. In `attachRealtimeTranslationsToLiveCaptions`, choose the first final caption where attached translation count is less than `sourceSegmentIDs.count`, append the translation, increment the count, and mark the realtime translation turn attached.

- [ ] **Step 5: Run targeted tests**

Run:

```bash
swift test --filter LiveCaptionStoreTests
swift test --filter MeetingAgentViewModelTests/testRealtimeTranslationFinalTextsAttachByCaptionOrderOnce
```

Expected: PASS.

### Task 4: Verify Full Test Suite and Commit

**Files:**
- Modify: `Sources/MeetingAgentCore/LiveMeetingCockpit.swift`
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Modify: `Tests/MeetingAgentCoreTests/LiveCaptionStoreTests.swift`
- Modify: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] **Step 1: Run repository verification**

Run: `make test`

Expected: PASS.

- [ ] **Step 2: Review diff**

Run: `git diff -- Sources/MeetingAgentCore/LiveMeetingCockpit.swift Tests/MeetingAgentCoreTests/LiveCaptionStoreTests.swift`

Expected: diff only contains same-speaker merge behavior and tests.

- [ ] **Step 3: Commit implementation**

```bash
git add Sources/MeetingAgentCore/LiveMeetingCockpit.swift Sources/MeetingAgentCore/MeetingAgentViewModel.swift Tests/MeetingAgentCoreTests/LiveCaptionStoreTests.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift docs/superpowers/plans/2026-04-28-merge-same-speaker-transcript-turns.md
git commit -m "feat: merge same-speaker transcript turns (#28)"
```

## Self-Review

- Spec coverage: covered same-speaker merge, different-speaker separation, duplicate segment update preservation, stale translation clearing, and focused/full verification.
- Placeholder scan: no placeholder steps remain.
- Type consistency: uses existing `LiveCaptionStore`, `LiveCaptionTurn`, `TranscriptSegment`, `TranscriptSpeaker`, and `LivePipelineHealth` names.
