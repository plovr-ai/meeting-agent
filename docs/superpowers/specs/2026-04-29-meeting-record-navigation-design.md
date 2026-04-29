# Meeting Record Navigation Design

## Issue

GitHub issue #91 asks to align the app around the meeting model instead of showing agenda data as meetings while the adjacent navigation still presents recordings. The current app already stores agenda, recording, transcript, summary, and export artifact paths on `MeetingRecord`, but the shell still exposes a `Recordings` destination and a `Recent Recordings` sidebar list.

## Goal

Make `MeetingRecord` the visible entity across the main navigation. Meetings should appear under `Today`, `This Week`, and `History`; recording artifacts should remain associated with the selected meeting and appear only in the existing detail/workspace flow.

## Selected Direction

Use a `MeetingRecord`-driven three-section navigation:

- `Today` shows meetings scheduled or started today.
- `This Week` shows meetings from the current calendar week excluding today.
- `History` shows meetings before the current calendar week.

This was selected over a text-only rename because the issue explicitly calls out `Today`, `This Week`, and `history`. It was selected over a new `Recording` model because the current persistence model already treats recordings as artifacts of `MeetingRecord`; introducing a separate recording entity would require migration and broader changes to transcription, summary, export, and compatibility paths.

## Requirements

- Keep `MeetingRecord` as the single list entity.
- Replace the `Recordings` navigation entry with `This Week` and `History`.
- Remove recording-centric navigation copy such as `Recent Recordings`.
- Filter left-side meeting rows by the active meeting bucket.
- Keep `TodayAgendaView` focused on today's meetings.
- Keep the existing workspace/detail view for selected meetings.
- Preserve recording start, stop, retry transcription, summary generation, export, speaker label edit, transcript edit, and settings behavior.
- Keep Settings as a fixed bottom entry.
- Use calendar-aware day and week comparisons based on each meeting's scheduled start when present, otherwise `startedAt`.
- Show useful empty states for meeting buckets with no rows.

## Non-Requirements

- No new persisted `Recording` model.
- No storage migration.
- No change to `MeetingRecord` fields.
- No changes to audio capture, transcription, summary, or export artifacts.
- No new search, calendar picker, or advanced filters.
- No redesign of the meeting detail command center beyond routing and navigation copy.

## Approach

`MainWindowDestination` will replace the recordings destination with `thisWeek` and `history`, while retaining `today`, `workspace`, and `settings`.

The sidebar will render `Today`, `This Week`, and `History` as first-class navigation buttons. Below the buttons, the existing meeting list will become bucket-aware. The list will use a helper that filters `viewModel.meetings` into the active bucket using `scheduledStartAt ?? startedAt`. Selecting a row will call `viewModel.selectMeeting(_:)` and route to `workspace`, preserving the existing detail flow.

`TodayAgendaView` will receive only today's meetings from `MainWindowView`. It will continue to edit and create agenda meetings, start a pending recording for a meeting, and open the workspace. This keeps agenda preparation specific to the Today surface while the broader shell handles week and history navigation.

For empty buckets, the sidebar list header and placeholder text will describe meetings rather than recordings. The detail pane will still show `No Meeting Selected` when a bucket has no selected row.

## Data Flow

`MeetingAgentViewModel` remains the source of truth. The view layer computes calendar buckets from `viewModel.meetings`; no bucket state is persisted. The selected meeting ID remains unchanged unless the user selects a row, creates a meeting, or starts a recording.

Recording artifacts remain fields on the selected `MeetingRecord`. The workspace/detail view continues to receive `viewModel.selectedMeeting` and existing callbacks, so artifact behavior is unchanged.

## Edge Cases

- A meeting with `scheduledStartAt` uses that date for bucket placement.
- A recorded ad hoc meeting without `scheduledStartAt` uses `startedAt`.
- `This Week` excludes today to avoid duplicate rows across `Today` and `This Week`.
- A selected meeting can remain selected when the user changes buckets; if it is not visible in the active bucket, the sidebar list simply has no selected row until the user opens the workspace or selects another meeting.
- Meetings later than today but inside the current week appear in `This Week`.

## Testing

Use existing source-layout regression tests for SwiftUI structure and focused view-model tests where behavior is model-level.

Tests should assert:

- `MainWindowDestination` includes `today`, `thisWeek`, `history`, `workspace`, and `settings`.
- The sidebar renders `Today`, `This Week`, and `History`, and no longer renders the `Recordings` navigation button.
- The sidebar list no longer uses `Recent Recordings`.
- Bucket filtering uses `scheduledStartAt ?? startedAt`.
- `This Week` excludes today's meetings and `History` excludes current-week meetings.
- `TodayAgendaView` is passed the today-filtered meeting list.
- Existing detail routing, settings routing, and detected meeting start routing remain present.

Run `make test` before completion.

## Risks

- Date bucketing can become surprising around locale week boundaries. Use `Calendar.current.isDate(_:equalTo:toGranularity:)` and week-of-year/year-for-week-of-year comparisons instead of raw intervals.
- Routing changes can accidentally hide the detail workspace. Keep `workspace` as an explicit destination and route list selections there.
- Source-layout tests can become brittle if they assert broad snippets. Keep new assertions focused on stable symbols and labels.
