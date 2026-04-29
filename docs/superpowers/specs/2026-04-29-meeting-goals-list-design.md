# Meeting Goals List Design

GitHub issue #111 asks to optimize meeting goals so goals are an array, can be added multiple times, and are tracked in a fixed right-side area. The issue is an enhancement and the selected design is the editor list plus workspace tracker option.

## Goals

- Let managers enter multiple meeting goals for one meeting.
- Show goals as simple title-only rows in the agenda editor, with add and remove controls.
- Keep the live workspace right pane anchored around goal progress by rendering a goals tracker above summary/details.
- Preserve existing analyzer and summary behavior by adapting the new list into the current single-goal progress pipeline for this increment.

## Non-Goals

- No UI for per-goal objectives, required questions, expected decisions, or key terms.
- No LLM-backed multi-goal progress analyzer in this issue.
- No redesign of transcript, summary generation, export, or recording controls beyond goal display changes.

## Data Model

Add `meetingGoals: [MeetingGoal]` to `MeetingRecord` and `MeetingAgendaUpdate`. Keep `meetingGoal` as a compatibility bridge for existing code and persisted data during this increment.

The canonical editable value becomes `meetingGoals`. When loading older records that only have `meetingGoal`, decode that single value into `meetingGoals`. When saving, normalize the title-only list, remove empty rows, and set the legacy `meetingGoal` to the first saved goal so existing progress, summary, and header code keep working.

## Editor UI

Replace the `AgendaDraft.goalText` textarea with `goalTexts: [String]`. `AgendaEditorView` renders a compact list:

- one text field per goal title
- a plus button to append a blank row
- a remove button per row when more than one row exists
- a fallback blank row when a meeting has no goals yet

Agenda rows and workspace header chips summarize the list by showing the first goal title plus a count when more goals exist, such as `Align rollout +2`.

## Workspace Tracker

`InsightPaneView` gets the meeting's goal list and renders `GoalTrackerPanel` at the top of the right pane. The panel shows each goal title with a compact status chip. The first goal can use the existing `MeetingProgressState` status when it belongs to the selected meeting's active progress goal; additional goals show a neutral pending status until a future multi-goal analyzer exists.

This satisfies fixed right-side tracking without pretending the current analyzer evaluates every goal independently.

## Data Flow

1. `AgendaDraft` loads `meeting.meetingGoals`, falling back through `meeting.meetingGoal`.
2. Saving an agenda builds `MeetingAgendaUpdate.meetingGoals` from non-empty title rows.
3. `MeetingAgentViewModel.saveAgenda` persists normalized `meetingGoals` and keeps `meetingGoal` equal to the first goal for compatibility.
4. `MeetingCommandCenterView` passes `meeting.meetingGoals` and `meetingProgressState` into the right pane.
5. `InsightPaneView` renders the fixed tracker before recommended questions, summary, and details.

## Error Handling

Saving keeps the existing agenda save error path. Empty goal rows are ignored. If all rows are empty, no goals are saved and the legacy `meetingGoal` is cleared, which also clears progress state through the existing view-model path.

## Testing

- Add model tests for decoding legacy single-goal records into the new goals array.
- Add view-model tests for saving multiple goals, trimming empty rows, and preserving the first goal as the legacy progress goal.
- Add source-layout tests that verify `AgendaEditorView` renders list-style goal editing controls and `InsightPaneView` renders a goal tracker before summary/details.
- Run `make test` as the required verification entrypoint.
