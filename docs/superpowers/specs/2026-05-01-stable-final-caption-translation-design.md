# Stable Final Caption Translation Design

## Context

Recent meeting performance analysis showed the translation pipeline is not failing mainly because of provider errors. The latest meeting had provider errors at zero, but `Final Translation Success Rate` was 0%. Final requests were scheduled and finished, then rejected as stale with reasons such as `final_no_longer_current`.

The recent caption translation budget work correctly bounded draft work and prioritized final requests, but real logs show that priority alone is not enough. A final result can return after the live caption turn has been merged, rebound, reclassified, or revised. The current apply path treats that normal live-caption churn as a stale final result and discards usable translation text.

## Goals

- Make final caption translation durable: if the provider successfully returns a final translation, the app must attach it to the current live caption or persist it to the matching transcript segment.
- Prove the design fixes the latest meeting failure mode where final completions became `final_no_longer_current`.
- Keep draft translation stale handling safe: old draft translations must not overwrite newer draft or final text.
- Reduce draft waste after final reliability is fixed.
- Improve performance logs and analysis so final success includes both visible attach and transcript persistence.

## Non-Goals

- Do not replace the translation provider.
- Do not introduce streaming translation in this design.
- Do not redesign the entire caption and translation unit model.
- Do not make broad UI layout changes.
- Do not change Deepgram API options as part of this work.

## Success Criteria

Phase 1 focuses on final reliability:

- A replay or fixture based on the latest meeting proves final completions that previously became `final_no_longer_current` now attach or persist.
- `Final Translation Success Rate` is at least 95% for provider-successful final requests.
- `final_no_longer_current` is no longer a primary final failure reason.
- Provider success is not discarded only because `displayState`, `boundaryStrength`, `boundaryReason`, `translationRevision`, or the live turn ID changed.

Phase 2 focuses on draft responsiveness and waste:

- Draft stale rate drops materially from the latest meeting baseline.
- Time to first translation does not regress materially.
- Replay, flush, and batch paths do not schedule draft translation work.

## Selected Approach

Use stable final request identity plus source-segment-based attachment.

Final translation must no longer be keyed by the mutable live caption turn. Instead, final request identity should be based on stable semantic inputs:

```text
translationKind=final
sourceSegmentIDs
normalizedFinalSourceTextHash
sourceLocale
targetLocale
provider/configuration fingerprint
```

The final key must not include:

- `displayState`
- `boundaryStrength`
- `boundaryReason`
- `translationRevision`

Draft requests can continue to use stricter current-turn identity because stale draft responses are expected and safe to drop.

## Request Identity And Attachment Target

Each final request carries two separate concepts.

Request identity is used for dedupe, in-flight tracking, retry tracking, and telemetry. It is stable for the same final source text and locale even if the live caption store reshapes the visible turn.

Attachment target is used after provider completion. It records:

- original turn ID
- primary source segment ID
- all source segment IDs represented by the request
- final source text
- speaker
- source locale
- target locale
- request creation time

When a final result returns, the app attempts attachment in this order:

1. Attach to the original live turn if it still exists and still represents the request source segments.
2. Rebind to the current live turn that contains the request source segment IDs.
3. Persist the translation to the matching transcript segment cache if no live turn can receive it.

Only after attach or persistence succeeds should the pipeline emit a success outcome.

## Data Flow

1. Deepgram emits stable transcript data and the caption pipeline identifies a hard final translation candidate.
2. `CaptionTranslationScheduler` builds a stable final request key and an attachment target.
3. The provider translates the final source text.
4. The apply path receives the translated text.
5. The apply path attaches by original turn ID or rebinds by source segment IDs.
6. If no live turn can receive the result, the persistence path writes the translation to the transcript segment cache.
7. The live caption store and transcript cache mark the translation as final when applicable.
8. Performance logs record whether the result attached, rebound, persisted, failed, or was truly stale.

## Error Handling

Provider success with a changed live turn is not an error. It should rebind or persist.

Provider success with deleted source segments is a true stale result. Log `caption_translation_stale` with `reason=source_segment_deleted`.

Provider failure remains `caption_translation_provider_error`. Final requests that fail due to provider error should remain retryable.

Target locale or provider configuration changes can invalidate an in-flight final request. Log a specific stale reason such as `target_locale_changed` or `provider_configuration_changed`.

Draft completions that no longer match the current draft key remain stale and should not overwrite visible text.

Replay, flush, and batch paths must not schedule draft translation. They may run a missing-final backfill pass.

## Telemetry

Keep existing caption translation events, but refine final outcomes.

Add or use these outcome events:

- `caption_translation_attached`: translation became visible in the live caption store.
- `caption_translation_rebound`: final result attached to a different current live turn than the original request turn.
- `caption_translation_persisted`: final result was written to transcript cache without a live attach.
- `caption_translation_stale`: true stale only, with explicit final reasons such as `source_segment_deleted`, `target_locale_changed`, or `provider_configuration_changed`.
- `caption_translation_retry_scheduled`: final retry after provider error or a recoverable persistence/attachment failure.

Analysis should treat final success as:

```text
final attached + final persisted
```

The report should include:

- Final Translation Success Rate
- Final Visible Attach Rate
- Final Persist-Only Rate
- Final Rebind Count
- Final True Failure Rate
- Draft Waste Rate

## Draft Optimization

Draft work is optimized after final reliability is fixed.

The draft scheduler should use adaptive debounce rather than a fixed aggressive window. The latest meeting showed provider latency around two seconds, so a 200 ms debounce still allows too many obsolete drafts to reach the provider.

Draft translation should fire when at least one of these is true:

- a pause or punctuation suggests the text is briefly stable
- the text changed enough since the last request
- a maximum wait threshold has elapsed since the last visible translation

Draft translation should not fire for replay, flush, or batch events. Those paths should only backfill missing final translations.

## Alternatives Considered

### Minimal Apply Relaxation

Allow final results to attach whenever the original turn ID still exists. This is small, but it does not solve turn merge, rebind, or source segment reshaping. It would not fully address the latest meeting failure mode.

### Full Translation Unit Model

Introduce a separate `TranslationUnit` lifecycle independent of caption turns. This is cleaner long term, but it touches chunking, store, scheduler, persistence, hydration, and UI behavior. It is too broad for the current reliability fix.

### Selected Middle Path

Stable final identity plus source-segment-based attachment directly addresses the observed 0% final success rate while keeping scope inside the scheduler, pipeline apply path, persistence, telemetry, and tests.

## Test Plan

- Scheduler test: final request key is unchanged by `displayState`, `boundaryStrength`, `boundaryReason`, and `translationRevision` changes.
- Scheduler test: final provider result returns after original turn changes, then rebinds by source segment IDs and attaches.
- Scheduler test: draft provider result returns after a newer draft or final state and is still discarded as stale.
- Persistence test: final provider result persists to transcript cache when no live turn can receive it.
- Pipeline test: replay, flush, and batch paths do not schedule draft translation and only run missing-final backfill.
- Analysis script test: final `caption_translation_persisted` counts toward final success and appears with readable metric names.
- Real-log fixture test: reproduce the latest meeting pattern with final requests of long source text returning after live turn changes; expected outcome is attach or persist instead of `final_no_longer_current`.
- Full verification: run `make test`.

## Implementation Boundaries

Expected affected areas:

- `Sources/MeetingAgentCore/CaptionTranslationScheduler.swift`
- `Sources/MeetingAgentCore/LiveCaptionPipeline.swift`
- transcript translation persistence helpers already used for caption translation cache
- `scripts/analyze-meeting-performance.swift`
- focused tests in `Tests/MeetingAgentCoreTests/`

The implementation should avoid unrelated UI changes and provider changes.
