# Meeting Action Row Design

## Issue

GitHub issue #103 asks to optimize the meeting page action layout. The current workspace spreads actions across the page: Back is alone in the top row, recording and retry transcription controls live below pipeline metadata, and export/debug actions appear as a visible exports block in the insight pane.

## Goal

Consolidate meeting workspace actions into the same top command row so the page has one predictable action surface:

- Back remains on the left.
- Recording control moves to the right side of the same row.
- Retry Transcription is removed as a first-class visible button.
- Export/debug actions move behind a three-dot overflow menu.

## Selected Approach

Use a compact top command bar. Keep the existing top row in `MeetingCommandCenterView`, but extend it so Back stays left while the right side contains a record/stop action and a three-dot menu.

This approach preserves the current page structure: the agenda strip remains below the command bar, the transcript pane keeps its live status header and pipeline metadata, and the insight pane stays focused on summary and recommended questions. It avoids merging too much state into the transcript header and avoids leaving important actions split across multiple page regions.

## Alternatives Considered

### Title-centered command bar

The command row could also contain the meeting title and live status. This would reduce vertical chrome but creates a dense row and duplicates information already handled by the transcript header.

### Transcript-local recording control

Recording could remain beside transcript context while only Back and debug actions move up. This keeps recording close to live transcript state, but it fails the issue goal of converging actions into the Back row.

## UI Behavior

The command row contains:

- `Back` with `chevron.left`, using the existing return destination behavior.
- A recording button on the right:
  - Shows `Stop Recording` with a danger style while recording.
  - Shows `Record` disabled when the workspace is not currently recording, because the workspace does not currently own a start-recording callback.
- A three-dot overflow menu using `ellipsis.circle`.

The overflow menu contains:

- `Copy Summary`, disabled while recording or when no summary exists.
- `Export Transcript`, disabled while recording or when no transcript exists.
- `Export Meeting JSON`.
- `Export SRT`.
- `Export VTT`.
- `Retry Transcription`, disabled while recording or when no audio exists.

The visible `Retry Transcription` row is removed from `TranscriptPaneView`. The visible `Exports` panel is removed from `InsightPaneView`.

## Affected Files

- `Sources/MeetingAgentApp/MainWindowView.swift`
- `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

## Testing

Update source-layout tests to verify:

- The meeting workspace top row contains Back, recording control, and overflow actions.
- `TranscriptPaneView` no longer renders the old visible `Retry Transcription` action row.
- `InsightPaneView` no longer renders the old visible `Exports` panel.
- Overflow menu entries include export/debug actions and retry transcription with the expected disabled conditions.

Run `make test` as the required verification entrypoint.
