# Meeting Audio Replay Button Design

## Goal

After a meeting ends, the top command button in the meeting workspace should become a simple audio replay control for the saved recording. The first version should support only play, pause, and continue. It should not add a timeline, volume control, scrubbing, or export workflow.

## Current Context

`MeetingStore` creates each meeting directory with an `audio.wav` path stored on `MeetingRecord.audioURL`. `MeetingRecorder` writes the WAV during capture and closes the writer during stop. The meeting workspace currently renders `Stop Recording` while recording and a disabled `Record` button when not recording.

The replay feature should reuse this persisted audio artifact. Recording, transcription, translation, summary generation, and meeting persistence should remain unchanged.

## User Experience

The top command row keeps one primary recording/replay control:

- While recording, the button remains `Stop Recording`.
- After recording ends, if the selected meeting has an available audio file, the button becomes `Replay`.
- Clicking `Replay` starts playing the meeting audio.
- While the selected meeting audio is playing, the button becomes `Pause`.
- Clicking `Pause` pauses playback in place.
- While the selected meeting audio is paused, the button becomes `Continue`.
- Clicking `Continue` resumes from the paused position.
- When playback reaches the end, the state returns to `Replay`.

If no audio file is available, the replay control is disabled and explains that the audio recording is not available. The first version should avoid a silent no-op.

## Architecture

Keep playback in `MeetingAgentApp`, not `MeetingAgentCore`.

Add a small app-layer controller, tentatively named `MeetingAudioReplayController`, responsible for local WAV playback. It can use `AVAudioPlayer` because the artifact is a local audio file and the first version does not need streaming or waveform analysis.

The controller exposes a compact state model:

- `idle`
- `playing(meetingID: UUID)`
- `paused(meetingID: UUID)`

The controller owns the current player instance, loads the selected meeting's `audioURL` on replay, and resets to `idle` when playback finishes or fails. If playback starts for a different meeting while another meeting is playing, it stops the old player and starts the new one.

`MeetingCommandCenterView` should render the command button from:

- `isRecording`
- the selected `MeetingRecord.id`
- the selected `MeetingRecord.audioURL`
- whether the audio file exists
- replay controller state for the selected meeting

No replay state should be persisted to meeting metadata.

## Data Flow

1. The selected meeting is passed into `MeetingCommandCenterView`.
2. The view checks whether `meeting.audioURL` exists on disk.
3. If recording is active, the view routes the button to `stopRecording`.
4. If recording is inactive and audio exists, the view routes the button to the replay controller:
   - `idle` for this meeting: load and play `audioURL`.
   - `playing` for this meeting: pause.
   - `paused` for this meeting: resume.
5. The controller publishes state changes so SwiftUI updates the button label.
6. AVAudioPlayer completion resets state to `idle`.

## Error Handling

Missing audio disables the replay button with a help message.

Playback initialization errors should not crash the app. The controller should reset to `idle` and surface a lightweight user-visible failure, such as a beep or status text, consistent with existing export/retry failure handling.

If the user navigates between meetings, the controller state remains global to the window. A selected meeting only shows `Pause` or `Continue` when the current replay state belongs to that same meeting.

If a new recording starts while audio is replaying, playback should stop so live capture remains the primary activity.

## Testing

Add focused coverage for the behavior without depending on real audio playback where possible:

- A controller or state reducer test verifies `idle -> playing -> paused -> playing -> idle`.
- A view/source test verifies the workspace no longer shows a disabled `Record` as the post-recording primary command when audio is available.
- A view/source test verifies `Stop Recording` still takes precedence while recording.
- A missing-audio case verifies replay is disabled or unavailable instead of attempting playback.

Run `make test` before claiming implementation complete.

## Non-Goals

- No progress bar.
- No scrubbing.
- No volume control.
- No waveform.
- No keyboard shortcuts.
- No media key integration.
- No background playback guarantees.
- No changes to recording or transcription persistence.
