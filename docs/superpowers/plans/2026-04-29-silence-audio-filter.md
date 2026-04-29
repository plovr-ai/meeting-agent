# Silence Audio Filter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Skip silent captured audio frames before streaming transcription provider calls while preserving complete WAV recordings.

**Architecture:** Add a small `AudioSilenceDetector` for little-endian signed 16-bit PCM and inject it into `MeetingRecorder`. The recorder continues to write every frame to the WAV writer and realtime consumer, but gates `AudioFrameTranscriber.append(_:)`.

**Tech Stack:** Swift 5.9, Swift Package Manager, XCTest, macOS 14.2+.

---

## File Structure

- Create `Sources/MeetingAgentCore/AudioSilenceDetector.swift`: contains PCM silence classification.
- Modify `Sources/MeetingAgentCore/MeetingRecorder.swift`: stores an injected detector and skips silent frames in `appendFrameToTranscriber(_:)`.
- Create `Tests/MeetingAgentCoreTests/AudioSilenceDetectorTests.swift`: covers detector edge cases.
- Modify `Tests/MeetingAgentCoreTests/MeetingRecorderTests.swift`: adds a recorder-level regression test.

### Task 1: Add Silence Detector

**Files:**
- Create: `Sources/MeetingAgentCore/AudioSilenceDetector.swift`
- Test: `Tests/MeetingAgentCoreTests/AudioSilenceDetectorTests.swift`

- [ ] **Step 1: Write detector tests**

```swift
import XCTest
@testable import MeetingAgentCore

final class AudioSilenceDetectorTests: XCTestCase {
    func testDetectsZeroPCMAsSilent() {
        let detector = AudioSilenceDetector()
        let frame = AudioFrame(pcm: pcm([0, 0, 0]), sampleRate: 16_000, channelCount: 1, timestampNanos: 1)

        XCTAssertTrue(detector.isSilent(frame))
    }

    func testDetectsLowAmplitudePCMAsSilent() {
        let detector = AudioSilenceDetector(amplitudeThreshold: 4)
        let frame = AudioFrame(pcm: pcm([-4, 0, 4]), sampleRate: 16_000, channelCount: 1, timestampNanos: 1)

        XCTAssertTrue(detector.isSilent(frame))
    }

    func testDetectsVoicedPCMAsNonSilent() {
        let detector = AudioSilenceDetector(amplitudeThreshold: 4)
        let frame = AudioFrame(pcm: pcm([0, 5]), sampleRate: 16_000, channelCount: 1, timestampNanos: 1)

        XCTAssertFalse(detector.isSilent(frame))
    }

    func testTreatsEmptyOrMalformedPCMAsNonSilent() {
        let detector = AudioSilenceDetector()

        XCTAssertFalse(detector.isSilent(AudioFrame(pcm: Data(), sampleRate: 16_000, channelCount: 1, timestampNanos: 1)))
        XCTAssertFalse(detector.isSilent(AudioFrame(pcm: Data([0]), sampleRate: 16_000, channelCount: 1, timestampNanos: 1)))
    }
}

private func pcm(_ samples: [Int16]) -> Data {
    var data = Data()
    for sample in samples {
        var littleEndian = sample.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
    return data
}
```

- [ ] **Step 2: Run focused tests to verify failure**

Run: `swift test --filter AudioSilenceDetectorTests`

Expected: FAIL because `AudioSilenceDetector` is not defined.

- [ ] **Step 3: Implement detector**

```swift
import Foundation

public struct AudioSilenceDetector: Equatable {
    public let amplitudeThreshold: Int16

    public init(amplitudeThreshold: Int16 = 32) {
        self.amplitudeThreshold = max(0, amplitudeThreshold)
    }

    public func isSilent(_ frame: AudioFrame) -> Bool {
        guard !frame.pcm.isEmpty, frame.pcm.count.isMultiple(of: MemoryLayout<Int16>.size) else {
            return false
        }

        let threshold = Int(amplitudeThreshold)
        var index = 0
        while index < frame.pcm.count {
            let low = UInt16(frame.pcm[index])
            let high = UInt16(frame.pcm[index + 1]) << 8
            let sample = Int(Int16(bitPattern: high | low))
            if abs(sample) > threshold {
                return false
            }
            index += 2
        }
        return true
    }
}
```

- [ ] **Step 4: Run focused tests**

Run: `swift test --filter AudioSilenceDetectorTests`

Expected: PASS.

### Task 2: Gate Transcriber Frames

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingRecorder.swift`
- Modify: `Tests/MeetingAgentCoreTests/MeetingRecorderTests.swift`

- [ ] **Step 1: Write recorder regression test**

Add a test that pushes a silent frame and a voiced frame, drains them, and asserts:

```swift
XCTAssertEqual(fixture.writer.writtenFrames, [silentFrame, voicedFrame])
XCTAssertEqual(fixture.transcriber.appendedFrames, [voicedFrame])
XCTAssertEqual(consumer.receivedFrames, [silentFrame, voicedFrame])
```

- [ ] **Step 2: Run focused test to verify failure**

Run: `swift test --filter MeetingRecorderTests/testDrainFramesSkipsSilentAudioOnlyForTranscription`

Expected: FAIL because the recorder still sends silent frames to the transcriber.

- [ ] **Step 3: Inject and apply detector**

Modify the internal recorder initializer to accept `silenceDetector: AudioSilenceDetector = AudioSilenceDetector()`. Store it on the recorder. In `appendFrameToTranscriber(_:)`, return early when `silenceDetector.isSilent(frame)` is true.

- [ ] **Step 4: Run focused recorder test**

Run: `swift test --filter MeetingRecorderTests/testDrainFramesSkipsSilentAudioOnlyForTranscription`

Expected: PASS.

### Task 3: Verify and Commit

**Files:**
- All changed source, test, spec, and plan files.

- [ ] **Step 1: Run full required verification**

Run: `make test`

Expected: PASS.

- [ ] **Step 2: Inspect diff**

Run: `git diff --stat && git diff --check`

Expected: only issue-related files changed and no whitespace errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/MeetingAgentCore/AudioSilenceDetector.swift Sources/MeetingAgentCore/MeetingRecorder.swift Tests/MeetingAgentCoreTests/AudioSilenceDetectorTests.swift Tests/MeetingAgentCoreTests/MeetingRecorderTests.swift docs/superpowers/specs/2026-04-29-silence-audio-filter-design.md docs/superpowers/plans/2026-04-29-silence-audio-filter.md
git commit -m "feat: filter silent audio before transcription (#56)"
```
