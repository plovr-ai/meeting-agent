# Stable Prefix Caption Rendering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add display-only stable-prefix metadata to live caption turns so repeated interim ASR revisions keep stable text anchored while preserving final provider text.

**Architecture:** `LiveCaptionTurn` carries optional display metadata beside `originalText`. `CaptionTurnAssembler` computes that metadata only for repeated interim updates to the same open draft, and final or reset paths clear it. Persistence remains source-segment driven and does not use this display-only state.

**Tech Stack:** Swift 5.9, Swift Package Manager, XCTest, macOS 14.2+.

---

## File Structure

- Modify `Sources/MeetingAgentCore/LiveMeetingCockpit.swift`: add optional stable-prefix fields to `LiveCaptionTurn`, encode/decode them with legacy-safe defaults, and preserve/reset them in store update paths.
- Modify `Sources/MeetingAgentCore/CaptionTurnAssembler.swift`: compute same-turn stable prefix/tail for draft updates and reset it on speaker changes or final/hard boundaries.
- Modify `Tests/MeetingAgentCoreTests/CaptionTurnAssemblerTests.swift`: add regression coverage for interim growth, interim correction, final promotion, and speaker reset.
- Optionally modify `Tests/MeetingAgentCoreTests/LiveCaptionStoreTests.swift`: add focused coverage only if store paths drop the new metadata unexpectedly.

### Task 1: Add LiveCaptionTurn Display Metadata

**Files:**
- Modify: `Sources/MeetingAgentCore/LiveMeetingCockpit.swift`
- Test: `Tests/MeetingAgentCoreTests/LiveCaptionStoreTests.swift`

- [ ] **Step 1: Write the failing legacy decode and initializer tests**

Add these tests near existing `LiveCaptionTurn` Codable/default tests in `Tests/MeetingAgentCoreTests/LiveCaptionStoreTests.swift`:

```swift
func testLiveCaptionTurnDefaultsStableDisplayMetadata() {
    let turn = LiveCaptionTurn(
        sourceSegmentID: "segment-1",
        originalText: "We should decide",
        isFinal: false
    )

    XCTAssertEqual(turn.stableOriginalTextPrefix, "")
    XCTAssertEqual(turn.unstableOriginalTextTail, "We should decide")
}

func testLiveCaptionTurnDecodesLegacyStableDisplayMetadataDefaults() throws {
    let data = Data("""
    {
      "id": "segment-1",
      "sourceSegmentID": "segment-1",
      "sourceSegmentIDs": ["segment-1"],
      "speaker": {},
      "originalText": "Legacy draft",
      "sourceLocale": "en-US",
      "targetLocale": "zh-CN",
      "isFinal": false,
      "captionHealth": { "state": "live" },
      "translationHealth": { "state": "pending" },
      "createdAt": "2026-04-30T00:00:00Z",
      "chunkState": "draft",
      "translationRevision": 1,
      "displayState": "draft",
      "translationState": "draft"
    }
    """.utf8)

    let turn = try JSONDecoder.meetingAgent.decode(LiveCaptionTurn.self, from: data)

    XCTAssertEqual(turn.stableOriginalTextPrefix, "")
    XCTAssertEqual(turn.unstableOriginalTextTail, "Legacy draft")
}
```

- [ ] **Step 2: Run focused tests to verify failure**

Run:

```bash
swift test --filter LiveCaptionStoreTests/testLiveCaptionTurnDefaultsStableDisplayMetadata
```

Expected: compile failure because `stableOriginalTextPrefix` and `unstableOriginalTextTail` do not exist.

- [ ] **Step 3: Implement metadata fields on LiveCaptionTurn**

In `Sources/MeetingAgentCore/LiveMeetingCockpit.swift`, add stored properties after `originalText`:

```swift
public var stableOriginalTextPrefix: String
public var unstableOriginalTextTail: String
```

Update the initializer signature after `originalText`:

```swift
stableOriginalTextPrefix: String? = nil,
unstableOriginalTextTail: String? = nil,
```

Inside the initializer after `self.originalText = originalText`, add:

```swift
let resolvedStablePrefix = stableOriginalTextPrefix ?? (isFinal ? originalText : "")
self.stableOriginalTextPrefix = resolvedStablePrefix
self.unstableOriginalTextTail = unstableOriginalTextTail ?? {
    if isFinal {
        return ""
    }
    return String(originalText.dropFirst(resolvedStablePrefix.count))
}()
```

Update `CodingKeys`:

```swift
case stableOriginalTextPrefix
case unstableOriginalTextTail
```

Update `init(from:)` after decoding `originalText`:

```swift
let decodedStablePrefix = try container.decodeIfPresent(String.self, forKey: .stableOriginalTextPrefix)
stableOriginalTextPrefix = decodedStablePrefix ?? (isFinal ? originalText : "")
unstableOriginalTextTail = try container.decodeIfPresent(String.self, forKey: .unstableOriginalTextTail) ?? {
    if isFinal {
        return ""
    }
    return String(originalText.dropFirst(stableOriginalTextPrefix.count))
}()
```

If Swift complains that `isFinal` is used before initialization, decode `isFinal` before this block and keep field assignments ordered so every property is initialized once.

- [ ] **Step 4: Run focused tests**

Run:

```bash
swift test --filter LiveCaptionStoreTests/testLiveCaptionTurnDefaultsStableDisplayMetadata
swift test --filter LiveCaptionStoreTests/testLiveCaptionTurnDecodesLegacyStableDisplayMetadataDefaults
```

Expected: both pass.

- [ ] **Step 5: Commit Task 1**

```bash
git add Sources/MeetingAgentCore/LiveMeetingCockpit.swift Tests/MeetingAgentCoreTests/LiveCaptionStoreTests.swift
git commit -m "feat: add live caption stable display metadata"
```

### Task 2: Compute Stable Prefixes in CaptionTurnAssembler

**Files:**
- Modify: `Sources/MeetingAgentCore/CaptionTurnAssembler.swift`
- Test: `Tests/MeetingAgentCoreTests/CaptionTurnAssemblerTests.swift`

- [ ] **Step 1: Write failing assembler tests**

Add these tests after `testInterimUpdatesReplaceDraftForSameSegmentID`:

```swift
func testInterimGrowthPreservesSharedStablePrefix() {
    var assembler = CaptionTurnAssembler(sourceLocale: "en-US", targetLocale: "zh-CN")
    let id = "deepgram-transcribe-stream-0.0"
    _ = assembler.apply(segment(
        id: id,
        speaker: "deepgram-speaker-0",
        text: "We should",
        isFinal: false,
        speechFinal: false
    ))

    let events = assembler.apply(segment(
        id: id,
        speaker: "deepgram-speaker-0",
        text: "We should decide",
        isFinal: false,
        speechFinal: false
    ))

    guard case .draftUpdated(let draft) = events.single else {
        XCTFail("Expected same-ID interim to update draft")
        return
    }
    XCTAssertEqual(draft.originalText, "We should decide")
    XCTAssertEqual(draft.stableOriginalTextPrefix, "We should")
    XCTAssertEqual(draft.unstableOriginalTextTail, " decide")
}

func testInterimCorrectionKeepsOnlyPrefixBeforeChangedWordStable() {
    var assembler = CaptionTurnAssembler(sourceLocale: "en-US", targetLocale: "zh-CN")
    let id = "deepgram-transcribe-stream-0.0"
    _ = assembler.apply(segment(
        id: id,
        speaker: "deepgram-speaker-0",
        text: "We should decide",
        isFinal: false,
        speechFinal: false
    ))

    let events = assembler.apply(segment(
        id: id,
        speaker: "deepgram-speaker-0",
        text: "We might decide",
        isFinal: false,
        speechFinal: false
    ))

    guard case .draftUpdated(let draft) = events.single else {
        XCTFail("Expected same-ID interim to update draft")
        return
    }
    XCTAssertEqual(draft.stableOriginalTextPrefix, "We ")
    XCTAssertEqual(draft.unstableOriginalTextTail, "might decide")
}

func testFinalPromotionClearsMutableStableTail() {
    var assembler = CaptionTurnAssembler(sourceLocale: "en-US", targetLocale: "zh-CN")
    let id = "deepgram-transcribe-stream-0.0"
    _ = assembler.apply(segment(
        id: id,
        speaker: "deepgram-speaker-0",
        text: "We should decide",
        isFinal: false,
        speechFinal: false
    ))

    let events = assembler.apply(segment(
        id: id,
        speaker: "deepgram-speaker-0",
        text: "We should decide today.",
        isFinal: true,
        speechFinal: true
    ))

    guard case .sealed(let sealed) = events.last else {
        XCTFail("Expected final segment to seal matching interim draft")
        return
    }
    XCTAssertEqual(sealed.originalText, "We should decide today.")
    XCTAssertEqual(sealed.stableOriginalTextPrefix, "We should decide today.")
    XCTAssertEqual(sealed.unstableOriginalTextTail, "")
}

func testSpeakerChangeResetsStablePrefixForSameSegmentID() {
    var assembler = CaptionTurnAssembler(sourceLocale: "en-US", targetLocale: "zh-CN")
    let id = "deepgram-transcribe-stream-0.0"
    _ = assembler.apply(segment(
        id: id,
        speaker: "deepgram-speaker-0",
        text: "We should decide",
        isFinal: false,
        speechFinal: false
    ))

    let events = assembler.apply(segment(
        id: id,
        speaker: "deepgram-speaker-1",
        text: "We should decide now",
        isFinal: false,
        speechFinal: false
    ))

    guard case .draftUpdated(let draft) = events.single else {
        XCTFail("Expected same-ID interim to update draft")
        return
    }
    XCTAssertEqual(draft.stableOriginalTextPrefix, "")
    XCTAssertEqual(draft.unstableOriginalTextTail, "We should decide now")
}
```

- [ ] **Step 2: Run focused assembler tests to verify failure**

Run:

```bash
swift test --filter CaptionTurnAssemblerTests/testInterimGrowthPreservesSharedStablePrefix
```

Expected: failure because the assembler still defaults updated draft stable metadata incorrectly.

- [ ] **Step 3: Implement assembler stability calculation**

In `Sources/MeetingAgentCore/CaptionTurnAssembler.swift`, update `draftTurn(for:)` so it computes display metadata before constructing `LiveCaptionTurn`:

```swift
var stableOriginalTextPrefix: String?
var unstableOriginalTextTail: String?
if let previous {
    let stability = stableDisplayText(previous: previous, segment: segment)
    stableOriginalTextPrefix = stability.prefix
    unstableOriginalTextTail = stability.tail
}
```

Pass the values into `LiveCaptionTurn` after `originalText: segment.text`:

```swift
stableOriginalTextPrefix: stableOriginalTextPrefix,
unstableOriginalTextTail: unstableOriginalTextTail,
```

Add private helpers in `CaptionTurnAssembler`:

```swift
private func stableDisplayText(
    previous: LiveCaptionTurn,
    segment: TranscriptSegment
) -> (prefix: String, tail: String) {
    guard previous.speaker == segment.speaker else {
        return ("", segment.text)
    }
    let prefix = stablePrefix(previous.originalText, segment.text)
    let tail = String(segment.text.dropFirst(prefix.count))
    return (prefix, tail)
}

private func stablePrefix(_ previous: String, _ current: String) -> String {
    guard !previous.isEmpty, !current.isEmpty else { return "" }
    let previousCharacters = Array(previous)
    let currentCharacters = Array(current)
    var index = 0
    while index < previousCharacters.count,
          index < currentCharacters.count,
          previousCharacters[index] == currentCharacters[index] {
        index += 1
    }
    let rawPrefix = String(currentCharacters.prefix(index))
    if index == currentCharacters.count {
        return rawPrefix
    }
    if index == previousCharacters.count {
        return rawPrefix
    }
    return rawPrefix.trimmingToLastWordBoundary()
}
```

Add a private `String` extension at the bottom of the file:

```swift
private extension String {
    func trimmingToLastWordBoundary() -> String {
        guard let boundary = lastIndex(where: { $0.isWhitespace || $0.isPunctuation }) else {
            return ""
        }
        return String(self[...boundary])
    }
}
```

- [ ] **Step 4: Run focused assembler tests**

Run:

```bash
swift test --filter CaptionTurnAssemblerTests
```

Expected: all `CaptionTurnAssemblerTests` pass.

- [ ] **Step 5: Commit Task 2**

```bash
git add Sources/MeetingAgentCore/CaptionTurnAssembler.swift Tests/MeetingAgentCoreTests/CaptionTurnAssemblerTests.swift
git commit -m "feat: compute stable prefixes for interim captions"
```

### Task 3: Verify Store Preservation and Full Suite

**Files:**
- Modify if needed: `Sources/MeetingAgentCore/LiveMeetingCockpit.swift`
- Modify if needed: `Tests/MeetingAgentCoreTests/LiveCaptionStoreTests.swift`

- [ ] **Step 1: Search store update paths for metadata loss**

Run:

```bash
rg -n "LiveCaptionTurn\\(|originalText =|turns\\[index\\] =|merged" Sources/MeetingAgentCore/LiveMeetingCockpit.swift
```

Expected: identify every path that creates or rewrites a `LiveCaptionTurn`.

- [ ] **Step 2: Add preservation tests only if a path drops metadata**

If `upsert(_:)`, `replaceRepresentedSegment`, `mergedProvisionalTurn`, or `rebuiltTurn` loses display metadata for a same-turn update, add a focused test like:

```swift
func testUpsertPreservesStableDisplayMetadataFromTurn() {
    var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
    let draft = LiveCaptionTurn(
        sourceSegmentID: "segment-1",
        originalText: "We should decide",
        stableOriginalTextPrefix: "We should",
        unstableOriginalTextTail: " decide",
        isFinal: false
    )

    let updated = store.upsert(draft)

    XCTAssertEqual(updated.stableOriginalTextPrefix, "We should")
    XCTAssertEqual(updated.unstableOriginalTextTail, " decide")
    XCTAssertEqual(store.turns.first?.stableOriginalTextPrefix, "We should")
}
```

- [ ] **Step 3: Run build**

Run:

```bash
swift build --product MeetingAgentApp
```

Expected: build succeeds.

- [ ] **Step 4: Run required test and coverage gate**

Run:

```bash
make test
```

Expected: all unit tests pass and coverage gate remains passing.

- [ ] **Step 5: Commit verification fixes if any**

If Step 2 required code or tests:

```bash
git add Sources/MeetingAgentCore/LiveMeetingCockpit.swift Tests/MeetingAgentCoreTests/LiveCaptionStoreTests.swift
git commit -m "test: cover stable caption metadata preservation"
```

If no changes were required, do not create an empty commit.
