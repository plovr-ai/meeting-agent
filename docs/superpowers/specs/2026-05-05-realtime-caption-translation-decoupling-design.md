# Realtime Caption Translation Decoupling Design

## Context

The latest meeting performance data showed that original captions and translated captions are conceptually separate, but the current realtime execution path still couples them. `LiveCaptionPipeline.apply(_:)` builds the original caption turn projection, then awaits `scheduleLiveTranslations()` before returning a snapshot. `MeetingAgentViewModel` publishes realtime caption UI only after that await completes.

This means a slow translation provider can delay original caption publication even though the original text is already available. In the latest meeting, OpenRouter translation requests had provider latency around 2-9 seconds, and many draft translation attempts were skipped because prior requests were still in flight. Original captions must be the primary realtime path and must not wait on translation.

## Goal

Make the realtime original-caption path independent from the translation path. A transcript update should publish original captions as soon as caption projection completes. Translation should run asynchronously and later overlay translated text onto the current caption turns when it is still safe to do so.

## Non-Goals

- Do not rewrite the UI layout.
- Do not replace `CaptionTranslationScheduler` or provider selection.
- Do not introduce a fully separate durable translation database in this iteration.
- Do not guarantee translated text appears in lockstep with original captions.

## User Experience

Original captions appear first and are treated as the live source of truth. Translations may appear later on the same turn. If a translation response is stale because the source turn changed, the meeting changed, or the caption pipeline reset, the response is ignored or persisted only when it can be safely mapped to a transcript segment.

The acceptable behavior is:

- Original text updates immediately even if translation is slow, offline, or failing.
- Translation can lag by seconds.
- Existing visible translated text may be carried forward only under the existing freshness and approximate-attach rules.
- A stale translation must never overwrite a newer caption or a different meeting.

## Recommended Architecture

Use a "caption projection plus translation overlay" model.

The primary path remains responsible for transcript accumulation, caption turn assembly, and immediate snapshot publication. It must not await network translation work.

The translation path receives immutable work derived from the latest caption snapshot, executes asynchronously, and returns updates through a narrow overlay entry point. The overlay entry point applies results to the current caption store only after validating generation, active meeting context, turn identity, source text, revision, and the scheduler's existing stale/approximate attach rules.

## Component Boundaries

### RealtimeCaptionSession

`RealtimeCaptionSession` should expose two distinct operations:

- Apply transcript/caption updates synchronously enough to return a caption snapshot without awaiting translation provider calls.
- Schedule or apply translation overlay work independently.

It should own the active `LiveCaptionPipeline` instance and remain the boundary used by `MeetingAgentViewModel`.

### LiveCaptionPipeline

`LiveCaptionPipeline.apply(_:)` should become caption-only for realtime transcript updates:

1. Apply removals for missing segments.
2. Apply changed transcript segments to `CaptionTurnAssembler`.
3. Hydrate any cached translations already present on the transcript segment.
4. Return a snapshot immediately.

It should no longer call `await scheduleLiveTranslations()` in the realtime caption path.

The pipeline should keep a separate method for applying translation work to the current store. That method can continue using `CaptionTranslationScheduler.apply(_:to:)` so that exact attach, approximate attach, stale rejection, final translation persistence, and failure handling remain centralized.

### CaptionTranslationScheduler

Keep the scheduler as the owner of translation request policy:

- debounce
- minimum draft delta
- max concurrent provider requests
- stale update detection
- approximate draft attach
- final translation persistence
- performance events tied to translation request IDs

The scheduler may still execute provider calls asynchronously. The important change is that callers must not await it before publishing original captions.

### MeetingAgentViewModel

`MeetingAgentViewModel` should publish original realtime snapshots before starting translation work.

When a transcript update arrives:

1. Build and publish the caption snapshot.
2. Record it as the latest realtime snapshot.
3. Start or replace a background translation task for the current context.
4. When translation completes, validate the same context and publish a translation overlay snapshot.

Meeting selection, recording stop, pipeline reset, and active target changes must cancel pending translation overlay tasks and advance a generation token. If a task completes after cancellation, generation/context validation prevents it from mutating UI state.

## Data Flow

### Original Caption Flow

```text
Audio/STT update
  -> RecordingTranscriptUpdateSink
  -> TranscriptSegmentAccumulationResult
  -> RealtimeCaptionSession.applyCaptionUpdate
  -> LiveCaptionPipeline.applyCaptionOnly
  -> LiveCaptionPipelineSnapshot
  -> publishRealtimeCaptionPipelineSnapshot
```

This flow must not call a translation provider and must not await translation scheduling.

### Translation Overlay Flow

```text
Published caption snapshot
  -> enqueue translation work for pending turns
  -> CaptionTranslationScheduler live/final translation updates
  -> validate active caption context and generation
  -> LiveCaptionPipeline.applyTranslationUpdates
  -> overlay snapshot
  -> publishRealtimeCaptionPipelineSnapshot
```

This flow may be slow. Its completion must not block the original caption flow.

## Persistence

Continue using the existing `persistTranslation` callback to write safe translation patches into transcript storage. This preserves existing replay hydration behavior and avoids introducing a new durable store in this iteration.

Rules:

- Fresh or accepted approximate translations attached to current turns can be persisted through the existing callback.
- Final translations can be persisted when the scheduler can bind them to the final transcript target.
- Stale translations should not update live captions.
- A stale result may be persisted only if the scheduler can safely identify the intended transcript segment and source text. Otherwise it is dropped.

## Performance Events

Keep existing translation request events and request IDs.

Add or clarify events so analysis can separate original-caption latency from translation latency:

- `caption_original_snapshot_published`: emitted when the original caption snapshot is published to UI.
- `caption_translation_overlay_published`: emitted when translated text changes are published to UI.

Existing `caption_turn_visible` should remain a pipeline/projection event, not the final UI-visible latency metric.

Performance analysis should filter replay events separately from realtime events. Replay events after `recording_stopped` must not be counted as live subtitle latency.

## Error Handling

Translation failure must degrade only translation state. Original captions remain live.

If translation provider creation fails, turns can remain pending or move to degraded/failed according to existing behavior, but original caption publication continues.

If translation work finishes for an old meeting, old selection, old pipeline generation, or old source text, it is discarded and logged as stale.

## Testing Strategy

Add focused unit tests around the decoupling contract:

1. A slow translation provider must not delay publication of original realtime captions.
2. A completed translation overlay updates the already visible turn.
3. Stale translation results from an older source revision do not overwrite newer original text or newer translation state.
4. Stopping recording cancels or invalidates pending translation overlay work.
5. Switching selected meetings prevents pending overlay work from mutating the new meeting's captions.
6. Persisted translation hydration still works when reopening or replaying a meeting.
7. Performance events distinguish original snapshot publication from translation overlay publication.

Run `make test` before claiming completion.

## Success Criteria

- The realtime caption path has no await on provider-backed translation work.
- Original caption UI updates remain responsive when a fake translation provider sleeps for several seconds.
- Translation still appears later when provider work completes.
- Existing translation persistence and replay hydration behavior continue to pass tests.
- Performance logs make original-caption latency and translation overlay latency separately measurable.
