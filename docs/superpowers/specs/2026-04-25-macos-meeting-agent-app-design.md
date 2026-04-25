# macOS Meeting Agent App Design

Date: 2026-04-25

## Context

The project is intended to become a meeting agent for managers running cross-border meetings. The long-term product should reduce language barriers, support localized expression, analyze meeting progress, and produce summaries and targeted analysis based on meeting goals.

The current implementation is a Swift Package with a command-line prototype, `CoreAudioTapProbe`. It can discover running meeting/browser processes, capture system audio with Core Audio Process Tap, write WAV output, and write a local macOS Speech transcript through the `local` STT provider.

This design defines the first real macOS application version. The application should be usable as a menu bar resident app with a main window, meeting detection, recording prompts, real-time transcript display, and persisted meeting records.

## Goals

1. Add a real macOS app target while preserving the existing CLI as a debugging tool.
2. Run as a menu bar resident app with a small status menu.
3. Monitor common meeting apps and Google Meet browser hosts after launch.
4. Prompt the user when a likely meeting process is detected.
5. Start recording only after user confirmation.
6. Show each meeting as one record in the main window.
7. Show recording status and live transcript text for the active meeting.
8. Persist meeting metadata, audio, and transcript under Application Support.

## Non-Goals

1. Multi-meeting parallel recording.
2. Cloud STT provider implementation.
3. Meeting summary, agenda tracking, translation, or localized response generation.
4. Speaker diarization.
5. Full App Store packaging, signing, or notarization.
6. Pixel-perfect visual design.

## Package Structure

Use a single Swift Package with multiple targets:

- `MeetingAgentCore`: shared library target for process discovery, capture, recording output, transcript providers, meeting records, and persistence.
- `CoreAudioTapProbe`: existing CLI executable target, refactored to depend on `MeetingAgentCore`.
- `MeetingAgentApp`: new macOS SwiftUI executable target for the user-facing app.
- `MeetingAgentCoreTests`: tests for core logic.
- Existing test coverage should either move to `MeetingAgentCoreTests` or continue under a renamed test target that depends on the core library.

This keeps the current CLI useful while avoiding duplicate capture and STT logic.

## App Behavior

### Launch

When the app starts:

1. Create a system menu bar item.
2. Open no main window by default unless launched in a debug mode that requests it.
3. Start monitoring running applications.
4. Load persisted meeting records from Application Support.

### Menu Bar

The status item menu contains:

1. `Open Meeting Agent`
2. Current status, such as `Idle` or `Recording Google Meet`
3. `Start Recording` when a meeting candidate exists and nothing is recording
4. `Stop Recording` when recording is active
5. `Quit`

The status item should remain active while the app is running.

### Meeting Detection

The app polls running applications every few seconds using the existing `RunningProcessDiscovery` logic. Preferred targets include Zoom, Teams, Lark, Tencent Meeting, Chrome, Edge, Safari, and The Browser.

Detection rules:

1. Ignore the app's own process.
2. Prefer known meeting apps and common Google Meet browser hosts.
3. Deduplicate prompts by process id.
4. Do not prompt again for the same process while it remains running.
5. If recording is already active, do not start another recording.

When a new preferred target is detected and no recording is active, show a user prompt asking whether to start recording.

### Recording Prompt

The first version uses a macOS user notification when the app is running in the background. Clicking the notification opens the main window and presents a confirmation action in the app. This avoids starting recording from a passive notification and keeps the final consent step visible in the app UI. The prompt text should include the target display name and make clear that audio recording will start only after confirmation.

Example:

```text
Google Chrome meeting detected. Start recording?
```

If the user accepts, create a meeting record and start recording.

If the user dismisses or rejects the prompt, mark that process as ignored until it exits.

## Main Window

Use the selected layout: split list and detail.

Left sidebar:

- Meeting records sorted by start time descending.
- Each row shows meeting name, start time, and status.

Right detail:

- Meeting name.
- Start and end time.
- Recording state.
- Audio file path or status.
- Transcript text.
- `Stop Recording` button for the active meeting.

The UI should be implemented in SwiftUI with thin views and testable view models.

## Data Model

The first version uses a small meeting model:

```swift
struct MeetingRecord: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var startedAt: Date
    var endedAt: Date?
    var audioURL: URL?
    var transcriptURL: URL?
}
```

The `name` should default to the detected process display name, such as `Google Chrome` or `zoom.us`.

## Persistence

Use the macOS Application Support directory:

```text
~/Library/Application Support/MeetingAgent/Meetings/<meeting-id>/
  metadata.json
  audio.wav
  transcript.txt
```

`metadata.json` stores the `MeetingRecord`. `audio.wav` and `transcript.txt` are stored beside it.

The existing `.record/` directory remains a CLI/debug output convention only. The app should not depend on the source checkout path.

## Core Services

### MeetingProcessMonitor

Responsibilities:

- Poll running applications.
- Publish newly detected preferred targets.
- Track ignored process ids.
- Track prompted process ids.

### MeetingStore

Responsibilities:

- Resolve Application Support paths.
- Create a directory for a new meeting.
- Write `metadata.json`.
- Load existing meetings.
- Update metadata when recording stops.

### MeetingRecorder

Responsibilities:

- Own one active recording session.
- Create WAV and transcript writers for the meeting directory.
- Use Core Audio capture services to capture the chosen process.
- Send frames to the selected `SpeechTranscriptionProvider`.
- Publish live transcript updates for the UI.
- Stop cleanly and update the meeting end time.

### STT Provider

The first app version uses only:

```text
--stt-provider local
```

The provider boundary already exists so later versions can add OpenAI realtime or batch transcription without rewriting the app UI.

## Error Handling

1. If system audio capture permission is missing, show a visible error in the main window.
2. If Speech permission is missing or local STT is unavailable, continue WAV recording and show the failure in transcript status.
3. If recording fails to start, keep the meeting record with error status only if a directory was already created.
4. If persistence fails, do not start recording.

## Testing Strategy

Add focused XCTest coverage for:

1. `MeetingRecord` encoding and decoding.
2. `MeetingStore` directory creation, metadata writes, and record loading.
3. Application Support path construction with an injectable base directory.
4. `MeetingProcessMonitor` detection, deduplication, and ignored process behavior.
5. `MeetingRecorder` state transitions with fake capture and fake transcriber components.
6. Existing CLI option parsing and process discovery behavior.

SwiftUI views can remain lightly tested. Most logic should live in core services and view models.

## Open Questions Resolved

1. The first version should be a real runnable macOS app, not only a shell or mock.
2. The UI uses the split list/detail layout.
3. Meeting data is stored under Application Support, not `.record/`.
4. Only one active recording is supported in the first version.
5. The existing CLI remains available.
