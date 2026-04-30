# Live Caption Snapshot Debounce Design

## Context

Issue #119 asks for display-level throttling for live caption snapshots. The caption pipeline can ingest Deepgram interim updates and draft translation refreshes at provider speed, but SwiftUI does not need every draft-only intermediate state to be published through `@Published liveCaptionTurns`.

## Goals

- Coalesce draft-only live caption snapshot publication before assigning `liveCaptionTurns`.
- Publish final captions, hard boundaries, manual stop flushes, resets, and error-state changes immediately.
- Keep pipeline ingestion, transcript persistence, translation scheduling, summaries, and meeting progress logic on the current immediate data path.
- Record coalesced display updates through the existing performance event stream when a meeting performance log is available.
- Cover draft coalescing, immediate final publication, stop flush publication, and cancellation/reset behavior in tests.

## Non-Goals

- Do not debounce `LiveCaptionPipeline` ingestion or structured transcript writes.
- Do not delay summary, progress, or translation scheduler inputs.
- Do not add user-facing settings for the debounce interval.
- Do not change SwiftUI layout or caption rendering behavior.

## Selected Approach

Add a small presentation-layer coalescer inside `MeetingAgentViewModel`. Existing callers continue to produce `LiveCaptionPipelineSnapshot` immediately. `MeetingAgentViewModel` decides whether that snapshot can be delayed before publishing to `liveCaptionTurns`.

A snapshot is delayable only when all changed visible caption turns are draft display state and no health/error transition requires immediate visibility. The view model stores the latest delayable snapshot and schedules one main-actor task for a short interval, using a default of 75ms. New delayable snapshots replace the pending one. Non-delayable snapshots cancel the pending task and publish immediately.

This keeps the data pipeline immediate and isolates SwiftUI redraw throttling at the boundary where `@Published liveCaptionTurns` changes.

## Publication Rules

- Draft-only updates: debounce and publish only the latest pending snapshot after the interval.
- Final captions and hard boundaries: publish immediately.
- Manual stop flushes: publish immediately for the flush snapshot and for the final translation snapshot that follows.
- Reset/cancel paths: cancel pending display snapshots and clear `liveCaptionTurns` immediately.
- Health changes involving failure, idle, or recovery: publish immediately so visible status does not lag.

## Metrics

When a draft snapshot replaces another pending draft snapshot, log `caption_snapshot_publication_coalesced` through `PerformanceEventLogger` if the selected meeting has a performance event URL. Metadata includes:

- `pendingTurnCount`
- `replacementTurnCount`
- `debounceMilliseconds`

The event does not include raw transcript or translation text.

## Tests

Add focused `MeetingAgentViewModelTests` coverage:

- Draft-only active transcript updates are coalesced before `liveCaptionTurns` changes.
- A final or hard-boundary snapshot cancels pending draft publication and appears immediately.
- `stopRecording()` still flushes and publishes final captions reliably.
- Reset or meeting selection changes cancel pending draft snapshots so stale captions cannot appear later.

Run focused tests with `swift test --filter MeetingAgentViewModelTests`, then run `make test` for the coverage gate.
