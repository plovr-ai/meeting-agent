# Current Pipeline Hover Design

## Goal

Move current pipeline details out of the visible metadata tags and into the native hover tooltip on the warning/info icon beside "Current Pipeline".

## Context

The meeting detail metadata area already has a "Current Pipeline" label, an `exclamationmark.circle` icon, and a native SwiftUI `.help(pipelineDebugHelpText)` tooltip. It also still renders `pipelineDisplayName` as a visible chip. Issue #73 asks for the pipeline information shown in tags to stop being duplicated there and to be consolidated in hover. The hover should include the meeting model chain, concrete models, transcript latency, and translation latency.

Performance events are already written to `performance-events.jsonl` through `PerformanceEventLogger`. Existing event names include transcription events such as `stt_segment_received` and `transcript_segment_written`, and caption translation events from the latency work. The UI can read this file on demand for a lightweight summary without changing recording or provider behavior.

## Requirements

- Keep the native macOS tooltip behavior using SwiftUI `.help(...)`.
- Keep the right-side `exclamationmark.circle` icon as the hover target.
- Remove the visible pipeline name chip from the metadata tag row.
- Include these details in the tooltip:
  - Pipeline display name.
  - Actual STT source.
  - Transcription link.
  - Transcription model.
  - Preflight status.
  - Transcript latency summary.
  - Translation latency summary.
- If latency data is missing, show an explicit unavailable state instead of hiding the row.
- Do not add new user settings or provider behavior.

## Non-Requirements

- Do not build a custom popover or hover panel.
- Do not change the pipeline selection model.
- Do not change performance event logging semantics.
- Do not add live polling for tooltip updates beyond the existing view refresh cycle.

## Selected Approach

Use the existing native tooltip and expand `pipelineDebugHelpText`. Add a small formatting helper in `MainWindowView.swift` that reads the current meeting's `performanceEventsURL`, decodes line-delimited `PerformanceEvent` values, and computes simple latest-latency summaries.

The metadata row will keep status and meeting time chips. The pipeline name chip will be removed, because the issue asks for tag-displayed pipeline information to live only in hover.

## Latency Semantics

Transcript latency should use the latest final transcript segment with both audio time and wall time available. It should report the wall-clock delay from meeting start plus audio timestamp to event wall time, using `transcript_segment_written` when available and falling back to `stt_segment_received`.

Translation latency should use caption translation events where possible. It should prefer attached events, because that is what the user sees. Since caption translation events do not carry audio timestamps, calculate this as wall-clock time from the matching `caption_translation_scheduled` event to `caption_translation_attached` using `translationRequestID`, falling back to `caption_translation_started` when scheduled is absent. If attached events are not available, or if the matching start event cannot be found, the tooltip should report that visible attach latency is unavailable.

## Files

- `Sources/MeetingAgentApp/MainWindowView.swift`: remove visible pipeline chip and expand tooltip text.
- `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`: update layout guard tests so the removed chip stays removed and the new tooltip rows stay covered.
- `docs/superpowers/plans/2026-04-29-current-pipeline-hover.md`: implementation plan.

## Tests

Use source-layout tests because the current UI tests already guard this SwiftUI layout by source scanning. Add assertions that:

- The metadata section still contains the icon and `.help(pipelineDebugHelpText)`.
- The metadata section no longer contains `CommandCenterChip(title: pipelineDisplayName`.
- `pipelineDebugHelpText` includes pipeline name and latency rows.
- Tooltip construction references `performanceEventsURL` and `PerformanceEvent`.

Run `make test` after implementation.
