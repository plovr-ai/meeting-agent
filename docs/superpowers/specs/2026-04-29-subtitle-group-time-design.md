# Subtitle Group Time Design

## Context

Issue #58 asks to show the local time after the subtitle speaker label, for example after `User A`. The current live transcript UI groups consecutive subtitle turns by speaker in `LiveCaptionSpeakerGroup` and renders one speaker header above the grouped subtitle blocks.

## Requirements

- Show a local time beside each live subtitle speaker group header.
- Use the first subtitle turn in the group as the displayed time.
- Format the time with hour, minute, and second precision.
- Preserve existing speaker editing behavior from the speaker header menu.
- Do not change transcript export, summary generation, or persisted transcript formats.

## Non-Requirements

- Do not show a different timestamp per subtitle line inside the group.
- Do not update the group timestamp when later turns are appended to the same speaker group.
- Do not add settings for time format in this change.

## Approach

Add a `startedAt` field to `LiveCaptionSpeakerGroup`. `groups(from:)` sets `startedAt` from the first turn when creating a group and leaves it unchanged when later consecutive turns from the same speaker are appended. `BilingualTranscriptGroup` formats `group.startedAt` with local time, showing hours, minutes, and seconds beside the speaker display name.

This keeps the timing rule in the grouping model, where the "first subtitle in this speaker group" boundary already lives. The UI only formats and displays that model value.

## Affected Files

- `Sources/MeetingAgentCore/LiveMeetingCockpit.swift`: add `startedAt` to speaker groups and preserve first-turn timestamp during grouping.
- `Sources/MeetingAgentApp/MainWindowView.swift`: render the group timestamp in the speaker header.
- `Tests/MeetingAgentCoreTests/LiveCaptionStoreTests.swift`: verify speaker groups use the first turn timestamp.
- `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`: guard that the speaker header includes timestamp rendering.

## Test Plan

- Add a unit test that creates two consecutive same-speaker turns with different `createdAt` values and asserts the group `startedAt` is the first value.
- Add a unit test or extend an existing grouping test to assert separate groups get their own first-turn timestamp.
- Add a source layout guard for the timestamp formatter and speaker header rendering.
- Run `make test`.
