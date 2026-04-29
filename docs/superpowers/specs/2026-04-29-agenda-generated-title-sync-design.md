# Agenda Generated Title Sync Design

## Context

GitHub issue #77 reports that recent meetings now use the summary-generated title, while the agenda can still show a generic process title such as "Google Chrome". Issue #61 already persists successful generated titles to `MeetingRecord.name`; this issue is about keeping the agenda UI's local editor state in sync with that persisted title.

## User Intent And Success Criteria

Managers should see the same useful meeting title in both Recent meetings and the Agenda after summary generation. The agenda editor should refresh from the updated meeting record when the user is not actively editing, and it should not discard unsaved agenda edits.

## Requirements

- Refresh the agenda editor draft title when the selected meeting record changes from a generic name to the generated summary title.
- Preserve unsaved user edits in the agenda editor when background meeting updates arrive.
- Keep the existing summary title persistence behavior unchanged.
- Keep the change local to agenda UI state unless verification shows a deeper model issue.

## Non-Requirements

- No new title-generation provider.
- No new UI control for accepting or rejecting generated titles.
- No overwrite of user-authored agenda titles.
- No changes to summary JSON or markdown artifact formats.

## Approaches Considered

### Selected: Clean Draft Refresh

Track the last record-backed agenda draft. When `TodayAgendaView` receives a `meetings` update for the same selected meeting, refresh the draft only if the current draft still equals the last record-backed draft. This updates stale generated titles while preserving in-progress edits.

### Alternative: Always Refresh On Meeting Updates

Always rebuilding the draft from the selected meeting is simple, but it can discard unsaved attendee, topic, date, or goal edits when transcription or summary metadata changes.

### Alternative: Display-Only Title Helper

The agenda row could display a derived title while the editor keeps its draft untouched. That would make part of the agenda look correct, but the editable title field could still show "Google Chrome".

## Architecture

`TodayAgendaView` already owns `AgendaDraft` and resets it when the selection changes. Add a second state value that stores the latest record-backed draft. `resetDraftFromSelection()` updates both the visible draft and this baseline.

On `meetings` changes:

- If the selected meeting changed, reset from selection as before.
- If the selected meeting is unchanged and the visible draft equals the baseline, reset from the updated selected record.
- If the visible draft differs from the baseline, keep the user's unsaved edits.

## Data Flow

1. Summary generation persists a generated title to `MeetingRecord.name`.
2. The view model publishes the updated `meetings` array.
3. `TodayAgendaView` observes the `meetings` change.
4. If the selected agenda draft is clean, it rebuilds from the updated selected meeting and shows the generated title.
5. If the draft is dirty, it keeps the user's in-progress edit.

## Error Handling

No new fallible operation is introduced. If no selected meeting exists, the agenda draft resets to an empty state. If a dirty draft exists, the background update is intentionally deferred until the user saves, cancels, or changes selection.

## Testing

- Add a focused layout/source regression test that verifies `TodayAgendaView` tracks a record-backed draft baseline and only refreshes clean drafts on `meetings` changes.
- Run the focused test.
- Run `make test` for full project verification.
