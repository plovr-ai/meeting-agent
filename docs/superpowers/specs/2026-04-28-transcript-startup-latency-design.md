# Transcript Startup Latency Design

## Context

GitHub issue #46 reports that after the app detects a video stream, starts recording, and enters the meeting page, subtitles have an obvious long delay.

The default transcription path is hosted Deepgram streaming. The app requests `interim_results=true`, but the local Deepgram streaming mapper currently drops every response unless `is_final == true`. The meeting UI then refreshes live captions from the structured transcript document. As a result, Deepgram can return early interim text, but the app does not render it until Deepgram emits a final segment. At meeting startup, a speaker may continue talking for several seconds before a final segment appears, creating the visible initial subtitle delay.

There is also a startup protection gap in `MeetingRecorder`: capture starts before the async streaming transcriber finishes connecting. If the app drains audio frames while `transcriber` is still nil, those frames are written to WAV but not sent to transcription.

## Goal

Show the first live captions as soon as the streaming provider emits usable interim transcript text, and preserve early startup audio for transcription while the transcriber connection is still being established.

## Non-Goals

- Do not change the selected default STT provider or model.
- Do not add a new transcription provider.
- Do not trigger translation for interim captions.
- Do not redesign the meeting UI.
- Do not change export formats beyond avoiding transient interim duplicates in the structured transcript source.

## Selected Approach

### Deepgram Interim Captions

Update `DeepgramStreamingResponseMapper` so non-empty Deepgram responses produce transcript segments for both interim and final messages. Interim segments should be marked `isFinal: false`; final segments remain `isFinal: true`.

Use a stable segment identifier for active Deepgram streaming results so repeated interim updates replace the previous active interim segment instead of accumulating as duplicate transcript rows. When a final response arrives for the same active range, it should replace the interim segment and become the durable final segment.

`LiveCaptionStore` already tracks `isFinal` and only marks final turns as translation-pending. `MeetingAgentViewModel.refreshLiveCaptionTurnsFromSelectedMeeting()` should append interim and final segments so the UI can show interim captions, while translation scheduling remains final-only.

### Startup Transcription Frame Buffer

Update `MeetingRecorder` to keep a small pending transcription frame buffer for frames drained while the recorder has begun capture but the streaming transcriber is not ready yet. WAV writing and realtime frame fan-out continue immediately.

When the transcriber becomes available, flush pending transcription frames to it in order before normal live appends continue. If transcriber startup fails, discard the pending transcription frames and keep the existing behavior: mark transcription failed while preserving WAV recording.

## Affected Files

- `Sources/MeetingAgentCore/DeepgramTranscriptionProvider.swift`
  - Map interim responses to non-final `TranscriptSegment`s.
  - Maintain stable active segment IDs for interim-to-final replacement.
  - Write streaming segments with replacement semantics.
- `Sources/MeetingAgentCore/TranscriptFileWriter.swift`
  - Add a segment upsert path that replaces an existing segment with the same id and appends otherwise.
- `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
  - Refresh live caption turns from all transcript segments, not final-only segments.
- `Sources/MeetingAgentCore/MeetingRecorder.swift`
  - Buffer frames drained before transcriber startup completes and flush them once ready.
- `Tests/MeetingAgentCoreTests/DeepgramStreamingTranscriptionProviderTests.swift`
  - Cover interim response mapping, interim replacement, and final replacement.
- `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`
  - Cover interim captions becoming visible without scheduling translation.
- `Tests/MeetingAgentCoreTests/MeetingRecorderTests.swift`
  - Cover startup-drained frames being delivered to the transcriber after it becomes ready.

## Test Plan

- Run focused Deepgram streaming tests for interim mapping and replacement.
- Run focused view model tests for interim caption visibility.
- Run focused recorder tests for startup frame buffering.
- Run `make test`.

