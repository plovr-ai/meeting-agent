# Recorder-Driven Audio Stream Design

## Context

The current app drives recording from `MeetingAgentApp.swift` with a 250 ms loop that calls `MeetingAgentViewModel.drainRecordingFrames()`. That method pulls audio frames out of the recorder, pulls transcript updates out of the transcript sink, applies live caption logic, and manually invalidates SwiftUI state.

This was practical for the prototype, but it couples UI rendering to the audio pipeline. After a meeting stops, the loop can continue to wake the view model and trigger SwiftUI recomputation. The detail view also reads transcript, summary, and performance files during body computation, so repeated invalidation becomes visible as navigation and sidebar jank.

The architecture should match the domain: audio capture is a stream. The recorder should consume that stream and emit recording events. UI should send commands and listen for state changes, not poll the recorder to make audio processing happen.

## Goals

- Remove the 250 ms drain loop from the audio, STT, transcript, and caption path.
- Make `MeetingRecorder` a self-running recording engine after `startRecording`.
- Keep Core Audio callbacks lightweight and realtime-safe.
- Keep the UI able to start and stop recordings from buttons.
- Keep automatic process-detected start and process-ended stop behavior.
- Preserve the existing caption reducer, live caption pipeline, summary generation, and meeting progress behavior in the first implementation.
- Move expensive file reads out of SwiftUI body computation.

## Non-Goals

- Do not introduce a new `RecordingRuntime` abstraction in this pass.
- Do not rewrite the live caption reducer or translation/caption pipeline.
- Do not move process discovery into `MeetingRecorder`.
- Do not make `MeetingRecorder` aware of SwiftUI, Combine, or UI text.
- Do not remove the independent process-monitor polling unless a later design replaces it with process events.

## Architecture

`MeetingRecorder` becomes the owner of the recording processing task. After capture starts, it continuously consumes available audio frames from an async frame buffer. The recorder writes WAV data, feeds the active STT transcriber, receives transcript updates, and emits recorder events through an `AsyncStream`.

```text
UI button / process monitor / tests
        |
        v
MeetingAgentViewModel command methods
        |
        v
MeetingRecorder
        |
        +--> Audio capture callback pushes frames
        +--> Recorder async task consumes frames
        +--> WAV writer writes audio
        +--> STT transcriber receives frames
        +--> Transcript sink produces updates
        +--> Recorder emits MeetingRecorderEvent
        |
        v
MeetingAgentViewModel event listener
        |
        +--> updates meetings/status
        +--> applies existing live caption pipeline
        +--> refreshes meeting progress
        |
        v
SwiftUI observes published state
```

The view model remains the command and UI-state boundary. It can start or stop the recorder, select meetings, map recorder status into display text, and apply transcript updates to the existing caption pipeline. It no longer owns a recurring audio drain loop.

## Audio Frame Boundary

Core Audio callbacks must not write files, call STT providers, await network work, or mutate UI state. They only enqueue frames into a bounded, thread-safe, async-wakeable buffer.

The existing `AudioFrameRingBuffer` should be evolved or wrapped into an async buffer with semantics like:

```swift
public final class AudioFrameAsyncBuffer {
    public func push(_ frame: AudioFrame)
    public func finish()
    public func drainAvailable() -> [AudioFrame]
    public var batches: AsyncStream<[AudioFrame]> { get }
}
```

Required behavior:

- `push(_:)` is lightweight enough for the audio callback.
- New frames wake the async consumer instead of waiting for a timer.
- The consumer receives batches of available frames, not necessarily one event per frame.
- Capacity remains bounded; overflow drops oldest frames and tracks dropped count.
- `finish()` closes the stream so the recorder task can exit cleanly.

This removes the 250 ms audio drain entirely. Audio processing becomes event-driven: frame arrival wakes the recorder.

## Recorder Events

`MeetingRecorder` exposes recorder-level events:

```swift
public enum MeetingRecorderEvent {
    case prepared(MeetingRecord)
    case started(MeetingRecord)
    case captureStatusChanged(MeetingRecorderStatusSnapshot)
    case transcriptUpdates([TranscriptSegmentAccumulationResult])
    case stopped(MeetingRecord, reason: CaptureEndedReason)
    case failed(MeetingRecorderFailure)
}
```

These events are infrastructure events, not reducer events. The transcript update event carries the existing reducer/caption input type, but it does not replace reducer events or expose reducer internals.

Layering:

```text
MeetingRecorderEvent.transcriptUpdates
        |
        v
ViewModel / caption orchestration
        |
        v
existing LiveCaptionPipeline input
        |
        v
LiveCaptionTurn state
```

`MeetingRecorder` should not know about `LiveCaptionPipeline`.

## STT Responsibility

STT provider selection and model/API integration stay in the recorder/transcriber layer:

- `MeetingRecorder.startRecording(...)` still creates the appropriate `AudioFrameTranscriber` through the existing factory.
- The recorder processing task writes each drained frame to WAV and calls `transcriber.append(frame)`.
- Provider-specific code remains in Whisper, Deepgram, OpenAI realtime, or macOS Speech transcriber implementations.
- Transcript updates continue to enter through `TranscriptUpdateSink`.

The view model never sends audio frames to STT.

## Stop Semantics

Stop is a command, not a side effect of an audio drain loop.

Manual stop:

```text
Stop button
  -> ViewModel.stopRecordingAndGenerateSummary()
  -> recorder.stopRecording(reason: .saved)
  -> recorder emits .stopped(record, .saved)
  -> ViewModel updates UI state and starts summary generation if requested
```

Automatic process-ended stop:

```text
Process monitor poll
  -> detects active process ended
  -> ViewModel calls recorder.stopRecording(reason: .targetProcessEnded)
  -> recorder emits .stopped(record, .targetProcessEnded)
```

Rules:

- `MeetingRecorder` does not call `RunningProcessDiscovery`; process policy stays outside the recorder.
- Stop finishes the audio buffer, flushes available frames, finishes the transcriber, closes the writer, saves metadata, and emits one stopped event.
- Stop handling in the view model must be idempotent by meeting id and stop generation so a returned stop record and `.stopped` event do not double-apply UI state.
- After stop, the recorder must not emit transcript updates from that session.

## Process Monitoring

The 250 ms drain loop is deleted. The existing process monitor can keep a separate low-frequency poll, currently every 3 seconds, for:

- detecting new meeting candidates;
- detecting active target process exit;
- sending start/stop commands through the same view model command path used by UI buttons.

This poll must not drive audio processing and must not cause window-wide invalidation when no process state changes.

## UI Performance

SwiftUI should only re-render when visible state changes.

Changes:

- Remove `viewModel.drainRecordingFrames()` from `MeetingAgentApp.swift`.
- Remove or retire `MeetingAgentViewModel.drainRecordingFrames()` from the app path.
- Listen to `recorder.events` from the view model and update `@Published` state only when events arrive.
- Avoid manual `objectWillChange.send()` except for narrow batch cases that cannot be expressed through `@Published` assignments.
- Move detail artifact reads out of SwiftUI body computation.

The detail view currently computes values by synchronously reading:

- `transcript.json` through `TranscriptFileWriter.readDocument` / `renderedTranscript`;
- `summary.json` through `MeetingSummaryWriter.read`;
- `performance-events.jsonl` through `String(contentsOf:)`.

Introduce a selected-meeting artifact snapshot loaded outside the view body:

```swift
public struct MeetingArtifactSnapshot: Equatable {
    public var meetingID: UUID
    public var transcriptText: String
    public var summary: MeetingSummary?
    public var transcriptLatencyText: String
    public var knowledgeSegments: [TranscriptSegment]
}
```

The loader should use file signatures to avoid rereading unchanged artifacts. SwiftUI receives this in-memory snapshot.

## Testing Strategy

### Audio Frame Buffer Tests

- Pushing a frame wakes an async consumer.
- Multiple pushed frames can be delivered as one batch.
- Capacity overflow drops oldest frames and records dropped count.
- `finish()` closes the stream and unblocks consumers.

### Meeting Recorder Tests

- Starting a recording causes audio frames pushed by the capture session to be written and fed to STT without external `drainFrames()`.
- Transcript updates emitted by the transcriber become `.transcriptUpdates` recorder events.
- Stop flushes remaining frames and closes writer/transcriber.
- Stop emits exactly one `.stopped` event.
- Stop prevents later transcript events for the stopped session.
- Existing `drainFrames()` can remain as an internal/test helper during migration, but the app path must not depend on it.

### View Model Tests

- ViewModel starts and stops the recorder through commands.
- ViewModel consumes recorder events to update active meeting state.
- ViewModel applies `.transcriptUpdates` to the existing live caption pipeline.
- Process-ended detection calls recorder stop instead of relying on drain.
- No app-facing method named `drainRecordingFrames` remains in use.

### UI Performance Tests

- Source-level test: `MeetingAgentApp.swift` does not call `drainRecordingFrames`.
- Source-level test: `MainWindowView.swift` does not synchronously call transcript, summary, or performance file readers in view body helpers.
- Snapshot loader tests verify file-signature caching.

## Migration Plan

1. Add async frame buffer behavior and tests.
2. Make capture sessions expose or use the async buffer while preserving callback safety.
3. Move recorder frame processing into an internal task started by `startRecording`.
4. Add `MeetingRecorderEvent` and recorder event stream.
5. Convert view model to listen for recorder events and apply existing caption/progress logic.
6. Remove `viewModel.drainRecordingFrames()` from `MeetingAgentApp.swift`.
7. Move process-ended stop to the process monitor command path.
8. Add selected-meeting artifact snapshot loading and remove body-time file reads.
9. Retire or narrow old drain APIs after tests no longer depend on the app path.

## Acceptance Criteria

- The audio/STT/caption main path has no 250 ms timer.
- Audio frames are processed when they arrive.
- UI can still start and stop recordings.
- Process detection can still start recordings and stop an active recording when the target process exits.
- Stopping a recording flushes audio and transcript state before summary generation.
- After stop, no idle recorder mechanism continuously invalidates SwiftUI.
- Navigation/sidebar interactions do not reread large transcript, summary, or performance files.
- `make test` passes.
