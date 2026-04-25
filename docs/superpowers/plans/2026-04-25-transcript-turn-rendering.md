# Transcript Turn Rendering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render consecutive transcript segments from the same speaker as one speaker turn instead of repeating `User A:` for every STT chunk.

**Architecture:** Keep `TranscriptSegment` as the provider-neutral raw STT segment. Update only `TranscriptFormatter` to group consecutive non-empty segments by speaker before rendering. Existing providers keep writing the same segment arrays and automatically benefit from the render-time grouping.

**Tech Stack:** Swift 5.9, XCTest.

---

## File Structure

- Modify `Tests/MeetingAgentCoreTests/TranscriptSegmentTests.swift`
  - Update formatter expectations from one-line labels to turn-style blocks.
  - Add coverage for consecutive same-speaker grouping and speaker changes.
- Modify `Tests/MeetingAgentCoreTests/WhisperTranscriptionProviderTests.swift`
  - Update Whisper transcript expectations to the turn-style output.
- Modify `Sources/MeetingAgentCore/TranscriptSegment.swift`
  - Add internal `TranscriptTurn` grouping inside `TranscriptFormatter`.

### Task 1: Formatter Turn Grouping

**Files:**
- Modify: `Tests/MeetingAgentCoreTests/TranscriptSegmentTests.swift`
- Modify: `Sources/MeetingAgentCore/TranscriptSegment.swift`

- [ ] **Step 1: Write failing formatter tests**

Update `Tests/MeetingAgentCoreTests/TranscriptSegmentTests.swift` expectations:

```swift
XCTAssertEqual(output, """
User A:
hello
""")
```

Replace `testSpeakerIdentifiersMapToStableLabels` with:

```swift
func testConsecutiveSegmentsFromSameSpeakerRenderAsOneTurn() {
    let output = TranscriptFormatter.render([
        TranscriptSegment(text: "first chunk"),
        TranscriptSegment(text: "second chunk")
    ])

    XCTAssertEqual(output, """
    User A:
    first chunk
    second chunk
    """)
}

func testSpeakerChangesStartNewTurnsAndReuseLabels() {
    let output = TranscriptFormatter.render([
        TranscriptSegment(speaker: TranscriptSpeaker(identifier: "speaker-2"), text: "second speaks first"),
        TranscriptSegment(speaker: TranscriptSpeaker(identifier: "speaker-1"), text: "first speaks second"),
        TranscriptSegment(speaker: TranscriptSpeaker(identifier: "speaker-2"), text: "second again")
    ])

    XCTAssertEqual(output, """
    User A:
    second speaks first

    User B:
    first speaks second

    User A:
    second again
    """)
}
```

Update blank and system Speech expectations to:

```swift
XCTAssertEqual(output, """
User A:
hello
""")
```

```swift
XCTAssertEqual(output, """
User A:
current partial result
""")
```

- [ ] **Step 2: Run formatter tests to verify they fail**

Run:

```bash
swift test --filter TranscriptSegmentTests
```

Expected: FAIL because `TranscriptFormatter` still renders every segment as `User A: text`.

- [ ] **Step 3: Implement render-time turn grouping**

Update `Sources/MeetingAgentCore/TranscriptSegment.swift`:

```swift
public struct TranscriptFormatter {
    public static func render(_ segments: [TranscriptSegment]) -> String {
        var mapper = SpeakerLabelMapper()
        return turns(from: segments).map { turn in
            let label = mapper.label(for: turn.speaker)
            return ([label + ":"] + turn.texts).joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }

    private static func turns(from segments: [TranscriptSegment]) -> [TranscriptTurn] {
        var turns: [TranscriptTurn] = []
        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let lastIndex = turns.indices.last, turns[lastIndex].speaker == segment.speaker {
                turns[lastIndex].texts.append(text)
            } else {
                turns.append(TranscriptTurn(speaker: segment.speaker, texts: [text]))
            }
        }
        return turns
    }
}

private struct TranscriptTurn {
    let speaker: TranscriptSpeaker
    var texts: [String]
}
```

- [ ] **Step 4: Run formatter tests to verify they pass**

Run:

```bash
swift test --filter TranscriptSegmentTests
```

Expected: PASS.

### Task 2: Provider Expectations

**Files:**
- Modify: `Tests/MeetingAgentCoreTests/WhisperTranscriptionProviderTests.swift`

- [ ] **Step 1: Update Whisper expected transcript text**

Change Whisper transcript expectations from:

```swift
"User A: hello from whisper\n"
```

to:

```swift
"User A:\nhello from whisper\n"
```

Change `"User A: first chunk\n"` to `"User A:\nfirst chunk\n"`.

Change `"User A: hello\n"` to `"User A:\nhello\n"`.

- [ ] **Step 2: Run Whisper tests**

Run:

```bash
swift test --filter WhisperTranscriptionProviderTests
```

Expected: PASS once Task 1 is complete.

### Task 3: Final Verification

**Files:**
- Verify all modified files.

- [ ] **Step 1: Run full test suite**

Run:

```bash
swift test
```

Expected: PASS.

- [ ] **Step 2: Commit implementation**

Run:

```bash
git add Sources/MeetingAgentCore/TranscriptSegment.swift Tests/MeetingAgentCoreTests/TranscriptSegmentTests.swift Tests/MeetingAgentCoreTests/WhisperTranscriptionProviderTests.swift
git commit -m "Render transcript segments as speaker turns"
```
