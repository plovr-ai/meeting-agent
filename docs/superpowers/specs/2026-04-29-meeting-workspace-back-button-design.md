# Meeting Workspace Back Button Design

## Context

GitHub issue #99 requests a back button on the meeting page. In the current macOS prototype, `MainWindowView` owns a hand-written `MainWindowDestination` state. Agenda buckets (`Today`, `This Week`, and `History`) render `TodayAgendaView`; opening a meeting switches the destination to `.workspace`, where `MeetingDetailView` renders the meeting workspace.

## User Intent

Managers should be able to return from a meeting workspace to the meeting list context they came from. If they opened a meeting from `History`, Back should return to `History`; if they opened one from `Today`, Back should return to `Today`. Entry paths without an obvious source, such as the meeting-detected alert, should return to `Today`.

## Selected Approach

Add source-page memory in `MainWindowView`.

- Store the most recent agenda bucket used to enter `.workspace`.
- Update that source before switching to `.workspace` from agenda cards and recording actions.
- Add a `backToMeetings` callback to `MeetingDetailView`.
- Render a compact `chevron.left` Back button at the top of the workspace.
- Invoke the callback to switch back to the stored agenda bucket, falling back to `Today`.

## Alternatives Considered

### Always Return To Today

This is the smallest implementation, but it creates a poor flow when users inspect a historical meeting and return to an unrelated list.

### Navigation Stack

A full navigation stack would model history more generally, but the app currently uses explicit destination state instead of nested `NavigationLink` paths. Adding stack machinery for one button would increase complexity without improving the current workflow.

## Requirements

- The meeting workspace shows a visible Back button with a left-chevron icon.
- Back returns to the agenda bucket used to open the current workspace.
- If there is no stored source bucket, Back returns to `Today`.
- Existing meeting selection, recording start, stop recording, export, retry transcription, summary, and speaker label behaviors remain unchanged.
- The implementation stays inside the existing `MainWindowView` destination model.

## Non-Requirements

- No browser-style multi-step history.
- No changes to meeting persistence.
- No sidebar redesign.
- No new keyboard shortcut.

## Affected Files

- `Sources/MeetingAgentApp/MainWindowView.swift`
- `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

## Testing

Add focused layout/source regression coverage for:

- `MeetingDetailView` accepting and invoking `backToMeetings`.
- `MeetingCommandCenterView` rendering a Back button with `chevron.left`.
- Agenda bucket and recording entry paths recording the return destination before switching to `.workspace`.
- No-source workspace entry paths defaulting to `Today`.

Run `make test` before completion.
