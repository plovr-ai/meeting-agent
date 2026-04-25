# Speaker-Labeled Transcripts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Standardize STT transcript files so provider output is rendered as speaker-labeled lines such as `User A: hello`.

**Architecture:** Add provider-neutral transcript segment and formatter types in `MeetingAgentCore`. Existing providers will hand transcript text to this shared layer; providers without speaker metadata use the default speaker, which renders as `User A`. Error messages remain plain text and bypass the formatter.

**Tech Stack:** Swift 5.9, XCTest, macOS Speech, local `whisper.cpp` CLI integration.

---

## File Structure

- Create `Sources/MeetingAgentCore/TranscriptSegment.swift`
  - Owns `TranscriptSpeaker`, `TranscriptSegment`, `SpeakerLabelMapper`, and `TranscriptFormatter`.
- Create `Tests/MeetingAgentCoreTests/TranscriptSegmentTests.swift`
  - Tests provider-neutral formatting and speaker label mapping.
- Modify `Sources/MeetingAgentCore/WhisperTranscriptionProvider.swift`
  - Store `[TranscriptSegment]` instead of `[String]`; render via `TranscriptFormatter`.
- Modify `Tests/MeetingAgentCoreTests/WhisperTranscriptionProviderTests.swift`
  - Update expectations from raw text to `User A:` labeled output.
- Modify `Sources/MeetingAgentCore/SystemSpeechTranscriber.swift`
  - Render Speech framework results through `TranscriptFormatter`.

### Task 1: Transcript Formatter

**Files:**
- Create: `Sources/MeetingAgentCore/TranscriptSegment.swift`
- Test: `Tests/MeetingAgentCoreTests/TranscriptSegmentTests.swift`

- [ ] **Step 1: Write the failing formatter tests**

Create `Tests/MeetingAgentCoreTests/TranscriptSegmentTests.swift`:

```swift
import XCTest
@testable import MeetingAgentCore

final class TranscriptSegmentTests: XCTestCase {
    func testDefaultSpeakerRendersAsUserA() {
        let output = TranscriptFormatter.render([
            TranscriptSegment(text: "hello")
        ])

        XCTAssertEqual(output, "User A: hello")
    }

    func testSpeakerIdentifiersMapToStableLabels() {
        let output = TranscriptFormatter.render([
            TranscriptSegment(speaker: TranscriptSpeaker(identifier: "speaker-2"), text: "second speaks first"),
            TranscriptSegment(speaker: TranscriptSpeaker(identifier: "speaker-1"), text: "first speaks second"),
            TranscriptSegment(speaker: TranscriptSpeaker(identifier: "speaker-2"), text: "second again")
        ])

        XCTAssertEqual(output, """
        User A: second speaks first
        User B: first speaks second
        User A: second again
        """)
    }

    func testBlankSegmentsAreOmitted() {
        let output = TranscriptFormatter.render([
            TranscriptSegment(text: "  "),
            TranscriptSegment(text: "\nhello\n"),
            TranscriptSegment(text: "")
        ])

        XCTAssertEqual(output, "User A: hello")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
swift test --filter TranscriptSegmentTests
```

Expected: FAIL because `TranscriptFormatter`, `TranscriptSegment`, and `TranscriptSpeaker` are not defined.

- [ ] **Step 3: Add the minimal formatter implementation**

Create `Sources/MeetingAgentCore/TranscriptSegment.swift`:

```swift
import Foundation

public struct TranscriptSpeaker: Equatable, Hashable {
    public static let `default` = TranscriptSpeaker(identifier: nil)

    public let identifier: String?

    public init(identifier: String?) {
        let trimmed = identifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.identifier = trimmed.flatMap { $0.isEmpty ? nil : $0 }
    }
}

public struct TranscriptSegment: Equatable {
    public let speaker: TranscriptSpeaker
    public let text: String

    public init(speaker: TranscriptSpeaker = .default, text: String) {
        self.speaker = speaker
        self.text = text
    }
}

public struct TranscriptFormatter {
    public static func render(_ segments: [TranscriptSegment]) -> String {
        var mapper = SpeakerLabelMapper()
        return segments.compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return "\(mapper.label(for: segment.speaker)): \(text)"
        }
        .joined(separator: "\n")
    }
}

struct SpeakerLabelMapper {
    private var labelsBySpeaker: [TranscriptSpeaker: String] = [:]
    private var nextIndex = 0

    mutating func label(for speaker: TranscriptSpeaker) -> String {
        if let existing = labelsBySpeaker[speaker] {
            return existing
        }
        let label = "User \(Self.letter(for: nextIndex))"
        labelsBySpeaker[speaker] = label
        nextIndex += 1
        return label
    }

    private static func letter(for index: Int) -> String {
        let scalar = UnicodeScalar(UInt8(ascii: "A") + UInt8(index % 26))
        let suffix = index < 26 ? "" : " \(index / 26 + 1)"
        return "\(Character(scalar))\(suffix)"
    }
}
```

- [ ] **Step 4: Run formatter tests to verify they pass**

Run:

```bash
swift test --filter TranscriptSegmentTests
```

Expected: PASS.

- [ ] **Step 5: Commit formatter unit**

Run:

```bash
git add Sources/MeetingAgentCore/TranscriptSegment.swift Tests/MeetingAgentCoreTests/TranscriptSegmentTests.swift
git commit -m "Add transcript segment formatter"
```

### Task 2: Whisper Standardized Output

**Files:**
- Modify: `Sources/MeetingAgentCore/WhisperTranscriptionProvider.swift`
- Modify: `Tests/MeetingAgentCoreTests/WhisperTranscriptionProviderTests.swift`

- [ ] **Step 1: Update Whisper expectations first**

In `Tests/MeetingAgentCoreTests/WhisperTranscriptionProviderTests.swift`, update these assertions:

```swift
XCTAssertEqual(try String(contentsOf: transcriptURL, encoding: .utf8), "User A: hello from whisper\n")
```

```swift
XCTAssertEqual(try String(contentsOf: transcriptURL, encoding: .utf8), "User A: first chunk\n")
```

```swift
XCTAssertEqual(try String(contentsOf: transcriptURL, encoding: .utf8), "User A: hello\n")
```

Leave failure-message assertions unchanged:

```swift
XCTAssertEqual(try String(contentsOf: transcriptURL, encoding: .utf8), "Whisper transcription unavailable: process failed\n")
XCTAssertEqual(try String(contentsOf: transcriptURL, encoding: .utf8), "Whisper transcription unavailable: no audio frames were captured\n")
```

- [ ] **Step 2: Run Whisper tests to verify they fail**

Run:

```bash
swift test --filter WhisperTranscriptionProviderTests
```

Expected: FAIL because Whisper still writes unlabeled text such as `hello from whisper\n`.

- [ ] **Step 3: Store and render Whisper segments**

In `Sources/MeetingAgentCore/WhisperTranscriptionProvider.swift`, change:

```swift
private var transcriptParts: [String] = []
```

to:

```swift
private var transcriptSegments: [TranscriptSegment] = []
```

Update the no-audio guard in `finish()`:

```swift
guard !chunkFrames.isEmpty || !transcriptSegments.isEmpty else {
    throw ProbeError.speechRecognition("Whisper transcription unavailable: no audio frames were captured")
}
```

Update the append/write block in `transcribePendingChunk()`:

```swift
if !transcript.isEmpty {
    transcriptSegments.append(TranscriptSegment(text: transcript))
    try TranscriptFileWriter(url: transcriptURL).replace(with: TranscriptFormatter.render(transcriptSegments))
}
```

- [ ] **Step 4: Run Whisper tests to verify they pass**

Run:

```bash
swift test --filter WhisperTranscriptionProviderTests
```

Expected: PASS.

- [ ] **Step 5: Commit Whisper integration**

Run:

```bash
git add Sources/MeetingAgentCore/WhisperTranscriptionProvider.swift Tests/MeetingAgentCoreTests/WhisperTranscriptionProviderTests.swift
git commit -m "Standardize Whisper transcript output"
```

### Task 3: macOS Speech Standardized Output

**Files:**
- Modify: `Sources/MeetingAgentCore/SystemSpeechTranscriber.swift`

- [ ] **Step 1: Add a focused formatter assertion for the local Speech shape**

In `Tests/MeetingAgentCoreTests/TranscriptSegmentTests.swift`, add:

```swift
func testReplacingCurrentSpeechResultUsesDefaultSpeakerFormat() {
    let output = TranscriptFormatter.render([
        TranscriptSegment(text: "current partial result")
    ])

    XCTAssertEqual(output, "User A: current partial result")
}
```

- [ ] **Step 2: Run the focused test**

Run:

```bash
swift test --filter TranscriptSegmentTests/testReplacingCurrentSpeechResultUsesDefaultSpeakerFormat
```

Expected: PASS if Task 1 is complete. This test documents the exact output that `SystemSpeechTranscriber` must write for current partial results.

- [ ] **Step 3: Route System Speech writes through the formatter**

In `Sources/MeetingAgentCore/SystemSpeechTranscriber.swift`, replace:

```swift
try? writer.replace(with: result.bestTranscription.formattedString)
```

with:

```swift
let transcript = TranscriptFormatter.render([
    TranscriptSegment(text: result.bestTranscription.formattedString)
])
try? writer.replace(with: transcript)
```

- [ ] **Step 4: Run core tests**

Run:

```bash
swift test
```

Expected: PASS.

- [ ] **Step 5: Commit local Speech integration**

Run:

```bash
git add Sources/MeetingAgentCore/SystemSpeechTranscriber.swift Tests/MeetingAgentCoreTests/TranscriptSegmentTests.swift
git commit -m "Standardize system speech transcript output"
```

### Task 4: Final Verification

**Files:**
- Verify all modified files.

- [ ] **Step 1: Check repository status**

Run:

```bash
git status --short
```

Expected: no unrelated changes. Plan/spec files may already be committed from the design process.

- [ ] **Step 2: Run the full test suite**

Run:

```bash
swift test
```

Expected: PASS.

- [ ] **Step 3: Inspect final diff**

Run:

```bash
git diff HEAD~3..HEAD -- Sources/MeetingAgentCore Tests/MeetingAgentCoreTests
```

Expected: changes are limited to transcript segment formatting and provider integration.
