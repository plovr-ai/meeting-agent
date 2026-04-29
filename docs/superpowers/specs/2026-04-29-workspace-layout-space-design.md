# Workspace Layout Space Design

## Context

Issue #112 asks to optimize the meeting workspace layout:

- Reduce the navigation width.
- Remove the fixed top `Meeting Agent` header.
- Remove the empty band below the back row.
- Let the transcript area use the full available space instead of sitting inside a framed panel.

The current implementation is concentrated in `Sources/MeetingAgentApp/MainWindowView.swift`. The sidebar uses a fixed `260/300` width and renders a custom `sidebarHeader`. The workspace renders a top command row, a separate `AgendaContextStrip`, and then a two-pane content area. The transcript content is wrapped by `UnifiedTranscriptView`, which currently renders its own `CommandCenterPanel`.

## Goals

- Make the workspace feel denser and give more space to transcript reading.
- Keep existing workspace navigation and action behavior intact.
- Preserve the current dark command-center visual system.
- Cover the layout change with source-layout tests, matching existing project test conventions.

## Non-Goals

- Do not redesign the whole workspace information architecture.
- Do not add new meeting data, new actions, or new transcript behavior.
- Do not change recording, export, summary, or translation logic.
- Do not remove the back button or existing action menu.

## Selected Approach

Use a focused shell layout trim:

1. Narrow the left sidebar from the current `minWidth: 260, idealWidth: 300` to a compact width near `180/210`.
2. Remove the custom `sidebarHeader` from the sidebar stack so the fixed `Meeting Agent` title no longer consumes vertical space.
3. Remove the workspace `AgendaContextStrip` band. The top command row already carries the back action plus goal and attendee chips, so it remains the compact workspace context surface.
4. Remove the `CommandCenterPanel` wrapper from `UnifiedTranscriptView`, leaving the transcript header and transcript groups directly in the transcript scroll content.
5. Update `MainWindowViewLayoutTests` to assert the new layout contract and prevent regressions.

## Affected Files

- `Sources/MeetingAgentApp/MainWindowView.swift`
- `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

## Testing

Run focused layout tests first:

```sh
swift test --filter MainWindowViewLayoutTests
```

Then run the repository-required verification:

```sh
make test
```

## Risks

- Source-layout tests are string-based, so they must be updated carefully to check the intended structure without becoming brittle.
- Removing `AgendaContextStrip` must not remove the only visible way to edit goal or attendees. The top command row retains those edit affordances.
