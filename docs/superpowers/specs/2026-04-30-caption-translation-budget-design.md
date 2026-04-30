# Caption Translation Budget Design

## Context

Issue #118 extends the live caption translation work from PR #117. Draft caption translation improves responsiveness, but high-frequency interim transcript updates can produce too many translation requests during real meetings. The app also needs enough performance telemetry to diagnose subtitle latency, redundant translation requests, stale completions, queue pressure, and user-visible translation delays after real meeting runs.

## Goals

- Bound draft translation network load during rapid interim updates.
- Keep final translation durable and prompt, even when draft text matches the final text.
- Make stale draft completions harmless.
- Limit global caption translation concurrency.
- Emit performance events that support real meeting analysis of latency, request redundancy, debounce effectiveness, and concurrency pressure.

## Non-Goals

- No UI dashboard for aggregate performance metrics in this issue.
- No provider-specific retry policy changes.
- No changes to transcript persistence format.

## Selected Approach

Implement throttling and concurrency budgeting inside `CaptionTranslationScheduler`. This keeps translation request policy close to the existing draft/final ownership logic and avoids pushing request semantics into `LiveCaptionPipeline` or the provider layer.

Draft requests use a short debounce window. A newer pending draft for the same turn replaces the older pending draft, and only the latest pending draft can fire. Final requests bypass debounce, are never dropped for capacity, and are scheduled before draft work. The scheduler enforces a small global concurrency limit while preserving final priority. Draft work is droppable when superseded by newer draft text or hard-final caption state.

## Performance Telemetry

The existing JSONL `PerformanceEventLogger` remains the sink. Caption translation events must consistently carry:

- `translationKind`: `draft` or `final`
- `translationRequestID`
- `turnID`
- `sourceSegmentID`
- `sourceSegmentIDs`
- `sourceLocale`
- `targetLocale`
- `translationRevision`
- `translationKeyHash`
- `sourceTextHash`
- `sourceTextLength`
- `requestOrdinalForTurn`

Budget-related events also carry `queueDepth`, `inFlightCount`, `concurrencyLimit`, `debounceMilliseconds`, and a reason field where applicable.

Required event families:

- `caption_translation_debounce_scheduled`
- `caption_translation_debounce_replaced`
- `caption_translation_debounce_fired`
- `caption_translation_enqueued`
- `caption_translation_started`
- `caption_translation_finished`
- `caption_translation_attached`
- `caption_translation_dropped`
- `caption_translation_cancelled`
- `caption_translation_stale`
- `caption_translation_skipped`

The existing `caption_translation_started`, `finished`, and `attached` events must set top-level `isFinal` from the actual translation kind. Draft events must not be marked final.

## Analysis Supported

After a real meeting, the JSONL stream should support these calculations:

- Subtitle latency: audio time to caption ingestion and transcript write events.
- Translation end-to-end latency: scheduled or enqueued to attached.
- Queue wait: enqueued to started.
- Provider latency: started to finished.
- Attach latency: finished to attached.
- Redundant request rate: requests per `turnID + translationKind`, stale completions, cancellations, and drops.
- Debounce effectiveness: replaced vs fired draft debounce counts.
- Final reliability: final dropped count must be zero; final stale/cancelled events require explicit reasons.

## Testing

Unit tests focus on `CaptionTranslationScheduler` because it owns the new policy. Tests must cover:

- Rapid draft updates for the same turn debounce into one provider request.
- A newer draft replaces an older pending draft.
- Final requests bypass draft debounce.
- Final requests still run when draft text equals final text.
- Global concurrency caps simultaneous provider calls.
- Final requests are not dropped under concurrency pressure.
- Stale draft completions cannot overwrite newer draft or final translation.
- Draft events are not top-level `isFinal == true`.
- Budget telemetry includes queue, debounce, request ordinal, and source text hash fields.

Full verification remains `make test`.
