# Translation Runtime Finalization Design

## Context

The main branch now has the unit translation pipeline connected to active recording:

- `TranslationUnitBuilder` builds lane-scoped live units and stable blocks.
- `LiveTranslationScheduler` schedules latest-pending live preview work.
- `AccurateTranslationScheduler` translates stable blocks.
- `TranslationResultStore` and `TranslationResultPersistenceStore` store visible and persisted stable results.
- Active recording can attach unit translation results back into the realtime caption overlay.

The remaining problem is ownership clarity. The old `CaptionTranslationScheduler` still exists with broad responsibilities, and `MeetingAgentViewModel` still owns too much translation lifecycle state directly. That leaves room for stop-time races, late preview publication, mixed telemetry, and unclear replay behavior.

The next step is to complete the new active-recording translation chain and explicitly shrink the old caption scheduler into a legacy/backfill adapter.

## Goals

- Make `TranslationExperiencePipeline` the only active-recording translation path.
- Add a small runtime boundary that owns translation lifecycle, generation checks, stop behavior, and stale result handling.
- Prevent preview translations from publishing after recording stops.
- Preserve visible translation continuity without jumping back to empty text or `translating`.
- Persist stable final translations as the authoritative record.
- Hydrate stable persisted translations on replay before any legacy backfill.
- Reduce `CaptionTranslationScheduler` to a clearly named compatibility role.
- Prove the new path is better with repeatable performance metrics.

## Non-Goals

- Do not redesign source-language caption rendering.
- Do not introduce streaming translation in this phase.
- Do not migrate historical meeting artifacts.
- Do not expose translation tuning controls in the UI.
- Do not delete `CaptionTranslationScheduler` until replay/backfill coverage is explicitly replaced or bounded.

## Selected Approach

Complete the current unit pipeline incrementally instead of rewriting the translation stack.

```text
Active recording:
Transcript updates
  -> LiveCaptionPipeline source captions
  -> TranslationRuntime
  -> TranslationExperiencePipeline
  -> TranslationResultStore
  -> realtime overlay / stable final persistence

Replay:
Transcript document + translation-results.jsonl
  -> hydrate stable unit results
  -> caption replay overlay
  -> optional legacy backfill only when stable unit results are missing
```

This keeps the successful work already merged into main, while moving lifecycle decisions out of the ViewModel and away from mutable caption-turn scheduling.

## Component Boundaries

### TranslationRuntime

Add a lifecycle boundary around `TranslationExperiencePipeline`. This can be a struct owned by `MeetingAgentViewModel`, or an actor if async races remain hard to reason about. The first implementation should prefer a small type with explicit generation checks; promote to actor only if tests show concurrency ambiguity.

Responsibilities:

- Hold current meeting ID, source locale, target locale, generation, and recording state.
- Own one `TranslationExperiencePipeline` per active recording.
- Accept realtime transcript documents and return visible translation overlay results.
- Flush and finalize stable blocks on stop.
- Drop late live preview results after stop.
- Drop results for old generations.
- Log lifecycle telemetry.
- Expose hydrate helpers for persisted stable results.

It should not:

- Build caption turns.
- Decide UI layout.
- Call legacy caption translation scheduling during active recording.
- Persist source transcript files.

Public shape:

```swift
struct TranslationRuntime {
    mutating func start(context: TranslationRuntimeContext)
    mutating func apply(document: TranscriptDocument, generation: Int, now: Date) async -> TranslationRuntimeSnapshot
    mutating func stopAndFinalize(generation: Int, now: Date) async -> TranslationRuntimeSnapshot
    mutating func hydrate(records: [TranslationResultPersistenceRecord]) -> [TranslationResult]
}
```

### TranslationExperiencePipeline

This remains the translation work engine:

- `TranslationUnitBuilder` decides live unit and stable block boundaries.
- `LiveTranslationScheduler` handles live preview scheduling and budget.
- `AccurateTranslationScheduler` handles stable final translation.
- `TranslationResultStore` decides visible result priority.
- `TranslationResultPersistenceStore` receives stable final records.

New constraints:

- It should not know about recording stopped state.
- It should return enough metadata for `TranslationRuntime` to decide whether a result may publish.
- It should persist only stable final and final recoverable failure records.

### MeetingAgentViewModel

The ViewModel should become an orchestrator, not the translation state machine.

Allowed responsibilities:

- Feed transcript updates into `LiveCaptionPipeline`.
- Feed transcript documents into `TranslationRuntime`.
- Attach returned visible translation results into `RealtimeCaptionSession`.
- Publish caption overlay snapshots.
- Own app-level telemetry logger and stores.

It should stop directly managing:

- Whether a late preview should publish.
- Whether a stop-time translation is final or preview.
- Which generation a translation result belongs to.
- How stable final records are converted into persistence records.

### CaptionTranslationScheduler

Shrink to legacy/backfill only.

Allowed responsibilities:

- Replay/backfill old meetings that do not have `translation-results.jsonl`.
- Translate historical caption turns when no unit stable result exists.
- Maintain compatibility tests for legacy transcript segment translation fields.

Disallowed responsibilities:

- Active recording live preview translation.
- Active recording final translation.
- Stop-recording finalization.
- Active realtime overlay publication.
- New trigger policy for mutable live captions.

Add explicit call-site naming so this is visible in code. Acceptable first-step names:

- `legacyCaptionTranslationScheduler`
- `LiveCaptionTranslationMode.legacyReplayBackfill`
- `scheduleLegacyReplayTranslations()`

Longer-term, rename the type to `LegacyCaptionTranslationScheduler` once call sites are reduced.

## Translation Trigger Policy

### Live Preview

Live preview is helpful but non-authoritative. It should fire only when the source has enough stable meaning:

- stable prefix has at least the configured minimum words or characters;
- or a semantic boundary appears;
- or visible translation age exceeds the freshness budget;
- or high-risk content changed and the previous preview would mislead.

Live preview should never trigger for tiny isolated fragments unless they are flushed into a stable block.

Scheduling rules:

- One in-flight preview per lane.
- Same-lane pending work is latest-only.
- Duplicate stable prefix is skipped.
- Budget exhaustion returns a non-visible disabled-budget result.
- Failed preview does not clear prior visible translation.

### Stable Final

Stable final translation is authoritative. It is sealed by:

- provider hard boundary such as `speech_final`;
- terminal punctuation with sufficient text;
- maximum block length;
- maximum block duration;
- speaker or locale lane change;
- manual stop flush.

Deepgram `is_final=true` advances stable text but does not by itself seal a user-facing translation final.

### Stop Finalization

Stop recording has strict ordering:

1. Mark runtime as stopping/stopped.
2. Block new live preview publication.
3. Flush open translation blocks with `.manualStop`.
4. Run accurate stable translation for flushed blocks.
5. Persist stable final results.
6. Attach only stable final visible results to the overlay.
7. Log late preview completions as dropped if they arrive after stop.

Post-stop live preview publication must be zero.

## Display Rules

`TranslationResultStore` remains the display authority.

Priority:

1. stable final
2. live fresh
3. live carried
4. live lagging
5. failed or disabled states, only for health/telemetry

UI rules:

- New preview requests do not clear existing visible translation.
- `translating` should mean no usable translation has ever been visible for that turn.
- Stable final replaces preview and cannot be overwritten by preview.
- Empty translations are not attached as visible text.
- Stop-time overlay publishes stable final only.
- Replay first hydrates stable unit results; legacy backfill only fills missing translations.

## Persistence

`translation-results.jsonl` is the source of truth for final translations.

Persisted records include:

- meeting ID
- result ID
- source/block ID
- lane ID
- source segment IDs
- source text hash
- source text
- translated text
- display state
- boundary reason
- provider ID
- created time
- finalized time

Rules:

- Persist stable final results.
- Persist failed recoverable final records only if they represent a sealed stable block.
- Do not persist live preview.
- Do not force multi-segment stable translations into a single transcript segment.
- Single-segment stable results may mirror into transcript compatibility fields.
- Replay should read persisted unit results before looking at transcript segment translation fields.

## Telemetry

Keep legacy and unit metrics separate.

Unit events:

- `translation_unit_live_scheduled`
- `translation_unit_live_stale`
- `translation_unit_live_dropped_after_stop`
- `translation_unit_final_scheduled`
- `translation_unit_final_persisted`
- `translation_unit_final_failed`
- `translation_runtime_snapshot`

Legacy events remain under the existing `caption_translation_*` names.

Performance script sections should report:

- live unit scheduled count;
- live unit stale/dropped count;
- stable unit persisted count;
- post-stop preview published count;
- post-stop unit final count;
- replay legacy backfill count;
- caption p50/p95/max unchanged from source-caption path;
- translation freshness and visible coverage from unit results.

## Performance Gates

Use the latest known old-link metrics as the baseline until a new meeting is recorded on the new runtime:

- latest old-link meeting: `Post-Stop Translation Events: 7`;
- latest old-link translation lag p95: `13.89s`;
- latest old-link translation success: `65.0%`;
- latest old-link live unit metrics: unavailable because the old run did not use the unit pipeline.

New runtime acceptance targets:

- `Preview Published After Stop Count = 0`.
- `translation_unit_live_dropped_after_stop` may be nonzero, but visible post-stop preview publication must be zero.
- Caption lag p95 must not regress relative to the same fixture/replay path.
- Live unit scheduled count should be materially lower than old draft scheduled count for the same meeting shape.
- Stable unit persisted count should be greater than zero for recordings with translatable final speech.
- Replay should make zero active-recording unit calls.
- Legacy backfill count should be zero for meetings that have complete stable unit results.

Verification inputs:

- `Tests/MeetingAgentCoreTests/Fixtures/latest-source-caption-regression.wav`
- `Tests/MeetingAgentCoreTests/Fixtures/latest-meeting-deepgram-x.log`
- latest local `performance-events.jsonl` before and after the change
- synthetic tests for stop-time late preview completion

## Testing Strategy

Unit tests:

- `TranslationRuntime` generation mismatch drops stale results.
- `TranslationRuntime` stop finalization only publishes stable final.
- Late preview completion after stop logs dropped and does not attach overlay text.
- Hydrated stable final results outrank transcript compatibility translations.
- Legacy scheduler is not invoked in active recording mode.

Integration tests:

- Active recording transcript update flows through unit runtime into overlay.
- Stop recording flushes open blocks, persists final results, and does not publish preview.
- Replay hydrates `translation-results.jsonl` without provider calls.
- Replay falls back to legacy scheduler only when unit results are missing.

Performance tests:

- Run existing Deepgram reconciliation fixture.
- Run `scripts/analyze-meeting-performance.swift` on synthetic unit events.
- Compare latest local meeting old-link metrics with a newly recorded new-runtime meeting.

## Migration Plan

1. Add `TranslationRuntime` with tests and no UI behavior change.
2. Move active-recording translation lifecycle from `MeetingAgentViewModel` into `TranslationRuntime`.
3. Add hard guards so `CaptionTranslationScheduler` cannot run for active recording.
4. Rename call sites to mark legacy replay/backfill intent.
5. Add stop-after-preview race tests and telemetry.
6. Update performance analysis to distinguish dropped previews from published post-stop previews.
7. Record a new meeting on main and compare metrics against the old-link baseline.
8. If legacy backfill remains unused for new recordings, create a follow-up removal spec.

## Open Decisions

These decisions are fixed for the first implementation:

- No streaming translation provider in this phase.
- Runtime may start as a non-actor type; promote only if tests expose concurrency risk.
- Legacy scheduler remains available for replay/backfill, but active recording must not call it.
- Stable final unit persistence is authoritative over transcript segment compatibility fields.

