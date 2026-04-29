# Silence Audio Filter Design

## Issue

GitHub issue #56 asks for filtering blank audio during meetings so long silent periods, such as preparation time or pauses, do not trigger unnecessary model calls or token usage.

## Goal

Preserve complete meeting recordings while preventing silent captured frames from being sent to streaming transcription providers.

## Requirements

- The saved meeting WAV must continue to include all captured audio frames, including silence.
- Realtime frame consumers must continue receiving all captured frames so UI and diagnostics behavior stays unchanged.
- Streaming transcription must skip frames whose signed 16-bit PCM samples are below a conservative silence threshold.
- The filter must apply during normal recording and during startup replay while a hosted streaming transcriber is still connecting.
- The detector must be unit-testable without Core Audio or network providers.

## Non-Requirements

- Do not remove silence from the saved `audio.wav`.
- Do not add a settings UI in this first pass.
- Do not post-process existing recorded WAV files.
- Do not change provider-specific APIs or Deepgram/OpenAI request formats.

## Options Considered

### Provider-Level Filtering

Each transcription provider could inspect frames before sending them to its backend. This keeps filtering close to the network call, but duplicates logic across Deepgram, OpenAI realtime, macOS Speech, and any future provider.

### Recorder-Level Transcription Gate

`MeetingRecorder` already fans out each captured frame to the WAV writer, the transcriber, and the realtime consumer. Gating only the transcriber append path keeps saved audio and UI behavior intact while covering every streaming transcription provider through one boundary.

### Capture-Level Filtering

The capture session could stop producing silent frames. This would also remove silence from recordings and realtime consumers, which conflicts with the product decision to preserve the full meeting audio.

## Selected Approach

Use recorder-level transcription gating backed by a small reusable `AudioSilenceDetector`.

`AudioSilenceDetector` reads little-endian signed 16-bit PCM samples from `AudioFrame.pcm`. A frame is silent when it contains at least one complete sample and every sample's absolute amplitude is less than or equal to a conservative threshold. Empty or malformed PCM is treated as non-silent so data problems are not hidden by the filter.

`MeetingRecorder.appendFrameToTranscriber(_:)` skips silent frames before calling `AudioFrameTranscriber.append(_:)`. This path is used both for live draining and for startup replay, so silent frames are filtered consistently without affecting WAV writes.

## Affected Files

- `Sources/MeetingAgentCore/AudioSilenceDetector.swift` creates the detector.
- `Sources/MeetingAgentCore/MeetingRecorder.swift` injects and applies the detector in the transcriber-only path.
- `Tests/MeetingAgentCoreTests/AudioSilenceDetectorTests.swift` covers PCM classification.
- `Tests/MeetingAgentCoreTests/MeetingRecorderTests.swift` covers recorder fan-out behavior.

## Testing

- Unit-test the detector with zero, low-amplitude, voiced, empty, and malformed PCM.
- Unit-test the recorder to prove silent frames are still written to WAV and delivered to realtime consumers, but skipped for the transcriber.
- Run `make test` as the required repository verification entrypoint.
