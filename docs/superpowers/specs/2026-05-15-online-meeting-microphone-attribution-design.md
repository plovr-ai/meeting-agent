# Online Meeting Microphone Attribution Design

## Goal

When MeetingAgent starts recording from a detected online meeting process, it must capture both the remote meeting audio and the local microphone. Microphone transcription from this online-meeting mode represents the current user and must enter the standard transcript event stream as `Me`; remote process audio keeps provider speaker diarization.

## Scope

This design covers online meeting recordings started from a detected process target, including `acceptPendingCandidate` and `startRecording(for:)`. It does not change offline discussion recording: `startOfflineMicrophoneRecording` remains a single microphone capture path and does not automatically label speech as `Me`.

The design does not use voice prints, speaker profiles, enrollment, embeddings, or UI-specific label overrides. `Me` is a capture-source attribution: in online-meeting mode, the local microphone source is the current user.

## Behavior

- Online meeting process audio is captured as the existing primary audio stream and written to the existing `audio.wav`.
- Online meeting microphone audio is captured as a second stream and written to a new microphone WAV artifact, for example `audio-microphone.wav`.
- The process stream uses the configured STT provider normally. Provider diarization, speaker ids, interim/final behavior, and language metadata are preserved.
- The microphone stream uses a second STT transcriber instance with the same speech configuration. Before microphone STT events reach transcript accumulation, their utterance speaker is normalized to `TranscriptSpeaker(identifier: "local-user", label: "Me")`.
- Both streams publish standard `SpeechRecognitionEvent` / `TranscriptSegment` updates into the same recording transcript sink. Downstream caption projection, summary, export, and knowledge-package flows consume standard speaker metadata and do not need UI-specific rules.
- If the microphone provider returns its own speaker diarization, online-meeting source attribution wins and the speaker is still `Me`.
- Offline discussion recordings keep current behavior and do not force microphone speech to `Me`.

## Architecture

### Capture Source Model

Extend capture source semantics with a composite online-meeting mode:

```swift
AudioCaptureSource.processWithMicrophone(
    target: AudioCaptureTarget,
    microphoneDisplayName: String = "Computer Microphone"
)
```

The existing `.process(target)` and `.microphone(displayName:)` cases keep their current meaning. `.processWithMicrophone` is selected only by online meeting process recordings.

### Recorder Runtime

`MeetingRecorder` should manage one primary process capture pipeline and one optional microphone pipeline:

```text
process capture session
  -> audio.wav
  -> process STT transcriber
  -> RecordingTranscriptUpdateSink

microphone capture session
  -> audio-microphone.wav
  -> microphone STT transcriber
  -> MicrophoneSpeakerAttributionSink
  -> RecordingTranscriptUpdateSink
```

The two STT streams are independent provider sessions. The app should not mix process and microphone PCM into one stream because that would erase source attribution and push the product back toward diarization guesses.

The existing `audio.wav` remains process/system audio for compatibility. The new microphone WAV is an additional artifact for debugging and future retry work.

### Event Attribution

Add a small source-attribution adapter at the transcript event boundary. For microphone events in online-meeting mode:

```text
.hypothesis(payload) or .final(payload)
  -> payload.speaker = TranscriptSpeaker(identifier: "local-user", label: "Me")
```

`providerStatus` events pass through unchanged. Process-stream events do not pass through this adapter.

This keeps UI and caption reducers source-agnostic. They continue to render whatever standard speaker metadata arrives.

### Transcript Merge

Both streams write into the same `RecordingTranscriptUpdateSink`. The merged `CaptionDocument` should preserve:

- process provider speaker ids and labels where available;
- microphone turns with `speakerID == "local-user"` and `speakerLabel == "Me"`;
- source timing, provider ids, interim/final state, and utterance ids used by the existing caption pipeline.

When active recording updates `MeetingSessionState`, the in-memory `TranscriptState.captionDocument` is the source of truth for summary, export, artifact snapshots, clipboard, and knowledge-package flows.

## Data Flow

```text
online process audio
  -> process STT stream
  -> standard speech events
  -> transcript sink

online microphone audio
  -> microphone STT stream
  -> microphone speaker attribution adapter
  -> standard speech events with speaker = local-user / Me
  -> transcript sink

merged transcript sink
  -> CaptionDocument
  -> LiveCaptionPipeline
  -> TranscriptState
  -> summary / export / knowledge package
```

No UI layer needs to know whether a turn came from microphone or process audio.

## Error Handling

- If process capture fails to start, online meeting recording fails as it does today because the primary target audio is unavailable.
- If microphone capture fails to start, process recording may continue, and the failure is logged as a microphone-side failure.
- If process STT fails, microphone STT can continue producing `Me` turns.
- If microphone STT fails, process STT can continue producing remote participant turns.
- A failure in one stream must not close the other stream's capture, writer, or transcriber.
- Stop recording must finish both transcribers, drain both frame buffers, close both WAV writers, and flush the caption document.
- Realtime caption paths must not emit `caption_translation_*` or `translation_*` events as part of this feature.

## Persistence

Meeting metadata should gain optional fields for the microphone artifact and capture mode while keeping old records decodable:

```text
audio.wav              existing primary process/system audio
audio-microphone.wav   new local microphone audio for online meetings
transcript.json        merged caption document
```

The main `audio.wav` should not include microphone audio in this issue.

## Tests

Focused unit tests cover:

- Online meeting ViewModel startup selects a composite process-with-microphone source.
- Offline discussion startup still selects the microphone-only source and does not enable `Me` attribution.
- The recorder starts two capture sessions and two STT transcribers for the composite source.
- The primary process stream writes the existing `audio.wav`; the microphone stream writes the new microphone WAV.
- Microphone `hypothesis` and `final` events are rewritten to `local-user` / `Me`; `providerStatus` events pass through unchanged.
- Process-stream events are not rewritten to `Me`.
- The merged active `CaptionDocument` preserves `Me` speaker metadata while keeping process speaker metadata.
- Stop persistence preserves `Me` in `transcript.json`.
- Summary/export/knowledge-package consumption reads the in-memory caption document speaker metadata.

## Non-Goals

- Voice print enrollment or speaker embedding matching.
- UI-layer special cases for `Me`.
- Mixing process and microphone audio into the primary WAV.
- Automatically labeling offline discussion microphone speech as `Me`.
- Real-name recognition for remote participants.
- Realtime translation or caption translation architecture changes.
