# Meeting Detail Goal Editing Design

## Issue

GitHub issue #101 asks for the meeting detail page to allow editing the meeting goal.

## Context

Meeting goals already exist on `MeetingRecord` and are persisted through `MeetingAgentViewModel.saveAgenda(for:update:)`. The agenda page has a full `AgendaEditorView` that can edit the meeting name, attendees, topics, schedule, and goal. The meeting detail page currently only renders the goal as a read-only chip in `AgendaContextStrip`.

## Selected Approach

Reuse the agenda editor pattern from the agenda page inside the meeting detail page.

The meeting detail view will expose an edit action from the agenda context strip. Activating it will show the same agenda-style editing surface for the selected meeting, including the goal field. Saving will call the existing `saveAgenda(for:update:)` path so metadata normalization, persistence, selected-meeting refresh, progress-state reset, and coordinator reconfiguration remain centralized.

## Requirements

- The meeting detail page must expose an obvious way to edit the selected meeting's goal.
- The editing flow must preserve existing meeting metadata unless the user changes it.
- Saving an empty goal must clear the persisted goal, matching existing agenda normalization.
- The detail page must update after save so the goal chip reflects the new goal.
- Existing recording, transcript, export, and speaker-edit controls must remain available.

## Non-Requirements

- No new goal objective, required-question, expected-decision, or key-term editor is required.
- No new persistence format is required.
- No live meeting progress algorithm changes are required beyond the existing reset triggered by `saveAgenda`.

## Affected Files

- `Sources/MeetingAgentApp/MainWindowView.swift`
- `Sources/MeetingAgentApp/TodayAgendaView.swift` if small visibility changes are needed to reuse editor helpers
- `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`
- `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift` if a focused save/update regression is missing

## Testing

- Add layout/source coverage that `MeetingDetailView` wires a goal or agenda edit action into the detail page.
- Add coverage that the detail page save path calls `saveAgenda` instead of a separate one-off goal persistence path.
- Reuse existing view-model tests for agenda normalization and persistence where sufficient; add a focused regression only if the current tests do not cover clearing/updating a selected meeting goal via `saveAgenda`.
- Run `make test` as the final verification command.
