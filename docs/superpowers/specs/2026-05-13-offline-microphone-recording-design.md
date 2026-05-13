# Offline Microphone Recording Design

Date: 2026-05-13

## Context

Meeting Agent currently starts recording from a detected meeting process. The audio capture path is centered on `AudioCaptureTarget`, Core Audio Process Tap, an aggregate device, `AudioIOReader`, and `MeetingRecorder`. This works for online meetings, but it cannot start a recording when the useful audio is a local in-room discussion captured by the computer microphone.

The first offline discussion feature should let the user explicitly start listening through the computer microphone and store the result as a normal meeting record. It should reuse the existing WAV recording, transcription, live caption, summary, and export workflows wherever possible.

## Goal

Add an explicit offline meeting mode that captures audio from the Mac's default microphone, creates a standalone meeting record, shows live captions during recording, and generates the same persisted artifacts as process-audio recordings.

## Requirements

- The user can start an offline microphone recording without a detected meeting process.
- Starting offline recording creates a normal `MeetingRecord` with a readable default name, such as `Offline Discussion`.
- Microphone audio flows into the existing `MeetingRecorder` drain loop as `AudioFrame` values.
- Existing WAV writing, transcription provider selection, live captions, summary generation, and export actions are reused.
- Offline microphone recordings do not depend on `pendingCandidate`.
- Offline microphone recordings do not stop automatically because a process target disappeared.
- Capture diagnostics identify the source as microphone input and keep a readable display name.
- Existing process-audio recording behavior remains unchanged.
- Unit tests cover the new capture-source routing and view-model start flow.

## Non-Requirements

- Do not mix microphone audio with an online meeting's system audio in this phase.
- Do not implement speaker diarization or local participant separation.
- Do not add microphone device selection in the first version.
- Do not add automatic voice activity wake-up or background always-listening behavior.
- Do not replace the current Core Audio Process Tap implementation for online meetings.

## Selected Approach

Introduce an explicit audio capture source abstraction while preserving the existing process-recording API.

Suggested model:

```swift
public enum AudioCaptureSource: Equatable {
    case process(AudioCaptureTarget)
    case microphone(displayName: String = "Computer Microphone")
}
```

`MeetingRecorder` should internally prepare and start recordings against `AudioCaptureSource`. Existing public methods that accept `AudioCaptureTarget` remain as compatibility wrappers using `.process(target)`. A new microphone-specific method starts `.microphone`.

This gives the recorder one source-aware path for record metadata, diagnostics, capture start, frame draining, and stop handling, while keeping call-site churn small.

## Capture Architecture

The online meeting path remains:

```text
AudioCaptureSource.process
    -> AudioCaptureSession
    -> AudioTapManager
    -> AggregateDeviceManager
    -> AudioIOReader
    -> MeetingRecorder
```

The offline microphone path becomes:

```text
AudioCaptureSource.microphone
    -> MicrophoneCaptureSession
    -> Default input device
    -> AudioIOReader
    -> MeetingRecorder
```

`MicrophoneCaptureSession` should conform to the same `AudioCaptureSessionManaging` protocol as `AudioCaptureSession`. It reads the default input device ID, starts `AudioIOReader` directly on that input device, publishes `outputSampleRate` and `outputChannelCount`, and stops the reader cleanly.

If the existing `AudioIOReader` cannot reliably start directly on the default input device, the fallback is a small `AVAudioEngine`-based reader that converts microphone buffers into the same signed 16-bit PCM `AudioFrame` shape. The public boundary should still be `AudioCaptureSessionManaging` so `MeetingRecorder` does not care which low-level microphone reader is used.

## Recorder And Diagnostics

`MeetingRecorder` should use source display metadata instead of assuming every recording target is a process. For `.process`, display name and process ID come from `AudioCaptureTarget`. For `.microphone`, the display name is `Computer Microphone` and the process ID can be stored as a sentinel only inside diagnostics if the current diagnostics schema requires it.

The preferred implementation is to extend diagnostics with source fields while keeping old JSON readable:

- `sourceKind`: `process` or `microphone`
- `sourceDisplayName`
- Existing `targetProcessID` and `targetDisplayName` remain for backward compatibility.

Offline recordings should finish with the existing `.saved` reason on manual stop. Capture failures should still write diagnostics where possible.

## View Model Behavior

Add a view-model entry point such as:

```swift
public func startOfflineMicrophoneRecording(
    name: String = "Offline Discussion",
    localeIdentifier: String? = nil
) async throws
```

The method should:

1. Create or prepare a normal meeting record.
2. Reset live caption state.
3. Set `activeMeetingID`.
4. Mark the active source as microphone rather than process.
5. Start the recorder with `.microphone`.
6. Enter the same live workspace behavior as process recordings.

`drainRecordingFrames` should continue to drain frames and apply transcript updates. The process-ended check must only run when the active source is `.process`.

## UI

Add an explicit offline recording command in the primary meeting surface. The first version can use one clear button in Today or Meetings:

- Label: `Record Offline`
- Icon: microphone
- Disabled while any recording is active

When clicked, it starts `startOfflineMicrophoneRecording`, selects the new meeting, and opens the workspace. During recording, the existing workspace status and `Stop Recording` action are reused.

The disabled `Record` button in meeting detail can stay disabled unless a future iteration supports starting microphone recording from a pre-created agenda item.

## Error Handling

- If microphone permission is denied or the input device cannot start, surface the existing `Recording failed: ...` status.
- Recording setup failures should stop and clean up the reader.
- Transcription startup failure should not stop WAV recording, matching existing behavior.
- If no audio is detected, existing diagnostics statuses such as `recordingNoAudioDetected` and `recordingSilentAudio` remain valid.

## Alternatives Considered

### Separate AVAudioEngine Recording Chain

This would keep microphone logic independent from Core Audio Process Tap. It is easy to reason about at first, but it duplicates recording, diagnostics, transcription, and live caption flow. That makes future fixes more expensive.

### Fake `AudioCaptureTarget`

The microphone could be represented as a special target with a fake process ID. This minimizes immediate call-site changes, but it leaks false process semantics into process-ended handling, diagnostics, and future source selection.

## Test Plan

- Add `MicrophoneCaptureSession` unit coverage with an injected device resolver or reader to prove it starts the default input device and stops cleanly.
- Add `MeetingRecorderTests` for starting a microphone-source recording and draining frames through writer and transcriber.
- Add diagnostics tests proving microphone recordings preserve readable source metadata.
- Add `MeetingAgentViewModelTests` proving offline recording creates a meeting without `pendingCandidate`.
- Add `MeetingAgentViewModelTests` proving process-ended polling does not stop an active microphone recording.
- Run `make test`.

## Deferred Work

- Mixing local microphone and online meeting audio in one recording.
- User-selectable input devices.
- Per-source labels in transcript segments.
- Echo cancellation and duplicate speech suppression.
- Background always-listening or push-to-talk modes.
