# Translation Unit Pipeline Remaining Optimization Design

## Context

The latest main branch already includes two important fixes:

- Live captions and translation are no longer tightly blocking each other.
- Draft translation triggers are gated so they do not fire on every small caption mutation.

The latest meeting data still shows the remaining translation problem is architectural:

- Realtime caption latency improved, but translation still follows mutable caption turns too closely.
- Final transcript segments have draft translations, but no `translationIsFinal=true` persisted final translations.
- Stop recording still allows a small number of late draft translation events.
- Some translations are poor because the source range is too small or semantically incomplete.

The selected direction is to make `TranslationUnit` the primary translation abstraction. Captions remain the realtime source-language display path. Translation runs from semantic units derived from transcript/caption state at a lower cadence.

## Goals

- Move active-recording translation triggers from caption-turn-level scheduling to unit-level scheduling.
- Treat realtime subtitles as the primary, non-blocking path.
- Avoid fragmented translation requests for tiny or unstable caption segments.
- Preserve visible translation continuity without clearing back to `translating` when old usable translation exists.
- Persist authoritative final translations for stable units.
- Ensure stop recording cancels preview work and only runs finalization work.
- Prove with performance analysis that the new path is better than the previous main branch behavior.

## Non-Goals

- Do not redesign source-language caption rendering.
- Do not remove `CaptionTranslationScheduler` immediately; keep it for legacy, replay, and missing-final backfill while the new path is adopted.
- Do not make live preview translations authoritative meeting records.
- Do not expose tuning controls in the UI in the first implementation.
- Do not migrate old meeting artifacts.

## Approach

Use an incremental main-path migration:

```text
Deepgram protocol events
  -> transcript reconciliation
  -> realtime caption display
  -> TranslationUnitBuilder
  -> LiveTranslationScheduler / AccurateTranslationScheduler
  -> TranslationResultStore
  -> UI overlay / persisted final translations
```

This avoids a risky one-shot rewrite while still solving the observed problems. The existing caption-turn scheduler stays available as a legacy adapter and backfill path, but active recording should route translation through the unit pipeline.

## Architecture

The app will use three separate tracks:

1. `Realtime Caption Track`
   - Owns source-language live captions.
   - Must not wait for translation provider latency.
   - May update at STT/provider frequency.

2. `Translation Unit Track`
   - Builds stable live units and sealed final blocks.
   - Owns translation trigger timing and source text range.
   - Runs slower than captions and ignores unstable tails.

3. `Translation Result Store`
   - Stores live preview and stable final translation results separately.
   - Provides visible result lookup for UI overlay.
   - Provides final result lookup for meeting detail, export, summary, and hydration.

`TranscriptSegment.translatedText` and `translationIsFinal` remain compatibility fields, not the source of truth.

## Translation Unit Lifecycle

### LiveTranslationUnit

`LiveTranslationUnit` is a preview unit for realtime understanding. It represents the stable prefix of current speech, not the latest unstable caption tail.

It should contain:

- unit ID
- lane ID: speaker, source locale, target locale
- stable prefix text
- unstable tail text
- source segment IDs
- revision
- created time
- deadline
- risk flags
- short context before the unit when available

Initial live translation triggers:

- English stable prefix has at least 8 words.
- CJK stable prefix has at least 18 characters.
- Or text reaches a semantic boundary and has at least 12 non-whitespace characters.

Follow-up live translation triggers:

- At least 8 new English words.
- Or at least 32 new characters.
- Or a semantic boundary appears.
- Or the last visible translation is older than 2.5 seconds.
- Or high-risk content changed, such as numbers, negation, dates, named entities, or commitments.

Live units are never persisted as final transcript translations.

### StableTranslationBlock

`StableTranslationBlock` is the authoritative final translation unit for records.

It is sealed by:

- Deepgram `speech_final=true` or an equivalent provider utterance end.
- Speaker change.
- Terminal punctuation with sufficient content.
- Pause or endpoint gap.
- Maximum block duration.
- Maximum block length.
- Manual stop flush.

Deepgram `is_final=true` means the provider has stabilized words. It should advance the stable prefix and open block content, but it must not by itself be treated as a user-facing final translation boundary.

## Scheduling

### Live Scheduler

`LiveTranslationScheduler` uses a lane model. A lane is `speaker + sourceLocale + targetLocale`.

Each lane keeps:

- last visible source prefix
- last requested source prefix
- pending latest unit
- one in-flight request
- last visible translation time
- budget state

Rules:

- Only one in-flight live request per lane.
- At most two global live requests in flight.
- If a new unit arrives while a lane has an in-flight request, replace `pendingLatestUnit`; do not queue multiple old units.
- When a request completes, schedule the latest pending unit only if it still satisfies trigger rules.
- Provider timeout is 4 seconds by default.
- If a result returns for an obsolete revision, do not publish it over the current UI. Log stale telemetry.
- If budget is exceeded, downgrade to boundary-only live translation until the budget recovers.
- Previous visible translation can be carried forward until a newer valid translation replaces it.

### Accurate Scheduler

`AccurateTranslationScheduler` translates sealed stable blocks.

Rules:

- Translate every stable block unless same-language mode makes translation unnecessary.
- Use lower concurrency than live preview, default 1.
- Retry once for recoverable provider failures.
- Timeout is 15 seconds by default.
- During active recording, final block translation must not block captions or live preview.
- During stop finalization, accurate translation is the only allowed translation work.
- Failed final blocks remain retryable and visible to backfill tooling.

## Stop Recording Semantics

Stop recording runs in this order:

1. Close live preview scheduling.
   - Cancel pending debounce/timers.
   - Prevent new live preview publication.
   - Late preview responses are logged but not displayed or persisted.

2. Flush open units.
   - Each lane seals its current open block as `manualStop`.
   - Empty or filler-only blocks are skipped.

3. Finalize stable translations.
   - Run accurate translation for sealed blocks.
   - Persist final results in the unit result store.
   - Optionally mirror final text to transcript compatibility fields.

Expected post-stop preview/draft event count is zero.

## Persistence

Add a unit-level translation artifact named `translation-results.jsonl`.

Each record should include:

- meeting ID
- result ID
- unit or block ID
- lane ID
- source segment IDs
- source text hash
- source text
- translated text
- display state
- boundary reason
- provider ID
- created time
- finalized time when available

Persistence rules:

- The first implementation persists stable final results and final failure records only.
- Live preview results stay in memory and telemetry; they are not persisted to transcript or `translation-results.jsonl`.
- Preview results must not set `translationIsFinal=true`.
- Stable final results are authoritative for translated records.
- Multi-segment final translations are stored as unit results and must not be forced into one segment as the only source of truth.
- Transcript segment compatibility fields are populated only when a stable final result maps cleanly to one source segment. Multi-segment blocks are read from the unit store by updated downstream paths.

## Downstream Impact

### UI

The UI reads visible translation from `TranslationResultStore`, not from current mutable caption text alone.

- New translation requests do not clear an existing visible translation.
- `translating` should appear only when no usable previous result exists.
- Stable final results outrank live preview results.
- Late stale preview results do not overwrite current visible text.

### Meeting Detail And Hydration

Meeting detail hydration loads stable final results first. If final results are absent, it falls back to legacy transcript compatibility fields and does not trigger live preview translation during hydration.

### Export

Export should prefer stable blocks and final translations. It should not assume one transcript segment equals one translation segment.

### Summary And Decisions

Summaries and decisions continue to trace claims to final source transcript text. When translated context is needed, use stable final translations, not live preview text.

### Existing Scheduler

`CaptionTranslationScheduler` remains for:

- legacy meetings
- replay paths
- missing-final backfill
- compatibility during phased migration

It should not own active-recording draft trigger policy once the unit pipeline is enabled.

## Component Changes

### TranslationUnitBuilder

Upgrade from per-segment output to lane-stateful unit building.

Responsibilities:

- Maintain open blocks per lane.
- Track stable prefix separately from unstable tail.
- Track source segment membership.
- Use provider protocol fields correctly: `is_final` advances stable words, `speech_final` seals a block.
- Detect speaker change, pause, terminal punctuation, max duration, max length, and manual stop boundaries.
- Emit live units only when trigger conditions are met.
- Emit stable blocks exactly once.

### TranslationExperiencePipeline

Become the active-recording translation entry point.

Responsibilities:

- Apply transcript/caption state updates.
- Call the unit builder.
- Route live units to the live scheduler.
- Route stable blocks to the accurate scheduler.
- Attach results to the result store.
- Expose UI overlay updates and persistence events.
- Provide `flushAndFinalize()` for stop recording.

### LiveTranslationScheduler

Adopt pending-latest scheduling per lane.

Responsibilities:

- Enforce one in-flight request per lane.
- Replace old pending work with the latest eligible unit.
- Enforce global and per-minute budgets.
- Cache source prefix translations.
- Return stale/timeout/failure outcomes without clearing previous visible results.

### AccurateTranslationScheduler

Translate stable blocks and produce final results.

Responsibilities:

- Retry recoverable failures.
- Record failed final blocks for backfill.
- Call final persistence hooks.
- Avoid draft/live publication after stop.

### TranslationResultStore

Become the query boundary for translation display and records.

Required queries:

- `visibleResult(for laneID)`
- `stableResults(for meetingID)`
- `resultsForSourceSegmentIDs(_ ids)`
- `hydrate(from persisted results)`

Result priority:

```text
stableFinal > liveFresh > liveLagging > liveCarried > pending > failedRecoverable > disabledBudget > none
```

## Error Handling

- Live timeout or provider failure keeps the old visible translation and records recoverable failure telemetry.
- Final timeout or provider failure creates a retryable failed block.
- Source revision mismatch discards preview publication.
- Same-language units complete without provider calls.
- Stop-after-preview responses are logged but not shown.
- Draft/live text is never promoted to final.
- Multi-segment final translations persist only through the unit store as the authoritative mapping.

## Performance And Regression Analysis

Use both the latest meeting artifact and regression wav fixtures.

Compare against the previous main branch metrics:

- Caption lag p50/p95/max.
- Time to first translation.
- Translation lag p50/p95/max.
- Visible translation coverage.
- Live request count per minute.
- Draft/live trigger rate.
- Stale visible translation rate.
- Hidden stale rate.
- Post-stop preview/draft events.
- Final translation persisted count and coverage.
- Provider latency distribution.

Acceptance targets:

- Caption p50/p95 must not regress because captions do not wait for translation.
- Live request rate should be at most 10-15 calls per minute under normal speech.
- Post-stop preview/draft events must be 0.
- Final translation persisted coverage should be at least 90% of stable blocks, with a target near 100%.
- Stale visible translation rate should be below 5-10%.
- Visible translation coverage should remain at least 90%.
- Time to first translation may be slightly slower than aggressive draft translation, but p95 should stay below 6 seconds.

## Test Plan

### Unit Tests

- `TranslationUnitBuilderTests`
  - `is_final` advances stable prefix but does not seal a block.
  - `speech_final` seals a provider boundary block.
  - Speaker change seals the previous block.
  - Pause gap seals a block.
  - Max length and max duration seal blocks.
  - Manual stop flush emits `manualStop`.
  - Short fragments do not trigger live preview.
  - High-risk changes trigger follow-up live units.

- `LiveTranslationSchedulerTests`
  - One in-flight request per lane.
  - Pending work is replaced by latest eligible unit.
  - Old pending units are not queued.
  - Budget overflow degrades to boundary-only.
  - Stale result does not overwrite visible result.
  - Timeout preserves previous visible result.

- `AccurateTranslationSchedulerTests`
  - Stable blocks translate to `stableFinal`.
  - Recoverable failure retries once.
  - Final failure is persisted as retryable.
  - Same-language block completes without provider call.

- `TranslationResultStoreTests`
  - Final result outranks live result.
  - Live carried result remains visible when a new request is pending.
  - Hydration restores stable final results.
  - Source segment ID mapping works for multi-segment blocks.

### Integration Tests

- Active recording uses the unit pipeline for translation.
- Source captions publish without waiting for translation.
- Stop recording prevents late preview publication.
- Stop recording flushes open blocks and runs final translation.
- Meeting reopen hydrates final translations without provider calls.
- Legacy caption translation backfill still works for older meetings.

### Performance Tests

- Replay regression wav through the old and new paths.
- Replay latest meeting data through the analyzer.
- Assert no caption latency regression.
- Assert live request rate reduction.
- Assert post-stop preview count is zero.
- Assert final translation persisted coverage improves from the latest observed zero-final baseline.

## Rollout

1. Build unit-level tests and lane-stateful `TranslationUnitBuilder`.
2. Add pending-latest live scheduler behavior.
3. Add unit result persistence and hydration.
4. Wire `TranslationExperiencePipeline` into active recording behind an internal switch.
5. Stop routing active-recording draft translation through `CaptionTranslationScheduler`.
6. Add stop `flushAndFinalize()`.
7. Run regression wav and latest meeting performance comparison.
8. Keep legacy scheduler/backfill path until the new metrics are stable.

## Open Decisions Resolved

- Primary direction: unit pipeline replaces caption-turn draft trigger policy for active recording.
- Realtime captions remain the main path and cannot be blocked by translation.
- Live translation may trade some immediacy for stability.
- Final translation is unit-level authoritative data.
- Preview/live translation is not authoritative and must not be promoted to final.
