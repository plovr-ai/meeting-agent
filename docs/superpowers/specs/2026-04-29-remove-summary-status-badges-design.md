# Remove Summary Status Badges Design

GitHub issue #108 asks to remove the recorded and summary-ready badges from the summary area. The scope is limited to the right-side meeting summary panel in the main workspace. Agenda and library list artifact badges, including `Summary ready`, remain unchanged because they are outside the summary area and still help scan meeting cards.

## Requirements

- Remove the two chip badges currently rendered under the summary overview in `InsightPaneView.phaseSummary`.
- Remove both recording state text (`ACTIVE` / `RECORDED`) and summary artifact state text (`Summary pending` / `Summary ready`) from that summary area.
- Preserve the `Summary` heading, summary overview text, pending-summary fallback text, and details list below it.
- Preserve all summary generation, copy, export, agenda, and meeting-list behavior.
- Preserve summary-ready artifact text in `TodayAgendaView`.

## Approach

Update `Sources/MeetingAgentApp/MainWindowView.swift` only in `InsightPaneView.phaseSummary`, deleting the `HStack` that contains the two `CommandCenterChip` instances. This keeps the visual structure simple and avoids adding a configuration switch for a one-surface removal.

Add a source-layout regression in `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift` that scopes assertions to `InsightPaneView`. The test verifies the summary pane no longer contains the removed chip titles while the broader agenda-card `Summary ready` text remains covered by the existing agenda test.

## Testing

- Run a focused layout test for `MainWindowViewLayoutTests`.
- Run `make test` from the worktree as the required full unit-test entrypoint.
