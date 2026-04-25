# Target Process Ended Capture Status Design

## Issue

GitHub issue #15 asks the app and CLI to detect when the active capture target process exits during recording and persist capture diagnostics with `endedReason: targetProcessEnded`. WAV and transcript artifacts written before termination must remain saved.

## Goals

- Detect active target PID disappearance in both `MeetingAgentApp` and `CoreAudioTapProbe`.
- Stop the active recording predictably when the target process disappears.
- Persist `CaptureDiagnostics.endedReason` as `.targetProcessEnded` and `status` as `.targetProcessEnded`.
- Preserve audio and transcript artifacts written up to the stop point.
- Keep manual/user stop behavior unchanged as `.saved`.

## Non-Goals

- Do not add OS lifecycle notifications or event-source based monitoring.
- Do not refactor the CLI to use `MeetingRecorder`.
- Do not change capture setup, Core Audio tap creation, or transcription provider behavior.

## Approach

Use explicit process-liveness checks at existing polling points. The app already calls `drainRecordingFrames()` repeatedly while recording, and the CLI already loops every 250 ms while capture is active. These are the right places to check whether the active target PID is still present in `RunningProcessDiscovery.currentTargets()`.

Add a small liveness helper to `MeetingProcessMonitor` so production code can query a PID against the current process list and tests can exercise the same logic with injected target arrays. Keep `RunningProcessDiscovery` as the production source of truth.

Extend `MeetingRecorder.stopRecording` to accept a `CaptureEndedReason`, defaulting to `.saved`. On target exit, callers will pass `.targetProcessEnded`; normal user stops will continue using the default. `MeetingRecorder` will still close the writer, finish the transcriber, stop the capture session, save diagnostics, mark the meeting ended, and return to idle.

In `MeetingAgentViewModel`, when `drainRecordingFrames()` sees the active target has ended, it will drain any buffered frames, stop the recorder with `.targetProcessEnded`, update the meeting row, clear `activeTarget`, and leave `statusText` as `Target process ended: <name>`.

In `CoreAudioTapProbe`, each capture loop iteration will check target liveness. If the target process has disappeared, the loop will drain/write frames for that tick, finish the writer/transcriber, write diagnostics with `.targetProcessEnded`, and log diagnostics before exiting normally.

## Testing

- Add unit coverage for the process-liveness helper.
- Add a `MeetingRecorder` test that `markStopped` or stop finalization can persist `.targetProcessEnded`.
- Add a `MeetingAgentViewModel` test using an injected process-list provider so target PID disappearance stops the meeting and sets target-ended status.
- Run `swift test` and `swift build --product CoreAudioTapProbe`.

