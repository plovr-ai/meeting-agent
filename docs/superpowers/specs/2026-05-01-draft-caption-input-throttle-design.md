# Draft Caption Input Throttle Design

## Context

The latest meeting performance analysis showed that Deepgram first response is not the primary bottleneck. The first live caption appears in about one second, and the first unique caption segments appear quickly. The visible experience still feels delayed because Deepgram interim updates enter the live caption pipeline too frequently, causing repeated draft caption publication, excessive `caption_turn_visible` logging, and draft translation requests that become stale before they can attach.

The current `liveCaptionSnapshotDebounceNanoseconds` default is 75 ms and runs after `LiveCaptionPipeline.apply(...)`. It only coalesces publication to `@Published liveCaptionTurns`. It does not reduce pipeline work, `caption_turn_visible` events, or draft translation scheduling. The source of pressure is earlier: active recording transcript updates should be coalesced before entering the live caption pipeline.

## Goal

Add a source-level draft caption input throttle for active recordings. The throttle should reduce high-frequency Deepgram interim churn before it reaches `LiveCaptionPipeline.apply(...)`, while preserving fast first captions and immediate final/flush behavior.

This should reduce:

- repeated draft `LiveCaptionPipeline.apply(...)` calls
- `caption_turn_visible` volume
- draft translation trigger pressure
- draft translation stale rate
- UI refresh churn

It must not delay:

- the first visible draft caption
- hard final captions
- manual stop flush
- translation attachments
- historical meeting replay

## Non-Goals

- Do not change transcript persistence semantics.
- Do not throttle replay or selected-meeting refresh paths.
- Do not replace the draft translation semantic trigger policy.
- Do not tune Deepgram endpointing or provider configuration in this change.
- Do not remove the existing UI snapshot debounce logic.

## Chosen Approach

Use a ViewModel-level source input coalescer. Add a small `DraftCaptionInputThrottler` around `MeetingAgentViewModel.drainRecordingFrames()` after `recorder.drainTranscriptUpdates()` and before `applyTranscriptAccumulationResultsToLiveCaptions(...)`.

This is preferred over throttling inside `LiveCaptionPipeline` because the pipeline already owns caption state progression, logging, and translation scheduling. Throttling before the pipeline directly reduces the work and event volume that caused the performance issue.

## Configuration

- Add `draftCaptionInputThrottleNanoseconds`, default `200_000_000`.
- Change `liveCaptionSnapshotDebounceNanoseconds` default from `75_000_000` to `0`.
- Keep `liveCaptionSnapshotDebounceNanoseconds` as an optional UI-layer guard for tests or future tuning.

The 200 ms default is a product tradeoff: it caps ordinary draft input at about five updates per second, which is stable enough for reading and significantly lower than Deepgram interim frequency, while still feeling live. Values below 150 ms are unlikely to reduce enough churn. Values above 300 ms risk making captions feel sluggish.

## Throttle Behavior

The throttler receives the latest `[TranscriptSegmentAccumulationResult]` batch and active apply context.

Rules:

1. The first visible draft in an active recording is applied immediately.
2. Subsequent delayable draft updates use trailing coalescing with a 200 ms window.
3. If multiple delayable draft updates arrive in the window, only the newest result is retained.
4. When the window fires, the retained result is applied once if its context is still current.
5. Any non-delayable result cancels or supersedes pending draft input and applies immediately.
6. Manual stop, reset, meeting selection changes, and pipeline resets cancel pending throttled input.

## Delayable Draft Definition

A transcript update batch is delayable only when all of these are true:

- The app is in active recording flow.
- The batch has no `plainTextReplacement`.
- The latest result has changed segments.
- Every changed segment is draft/interim, not a hard final segment.
- The update does not need to remove or replace hard-final caption state.
- The active apply context still matches the current active meeting and selected meeting.

Hard final and stop flush paths are never delayed. Soft boundaries may still be delayable because they are not final translations, but they can be used as a reason to flush a pending draft promptly if implementation needs that to preserve readability.

## Data Flow

Current flow:

```text
recorder.drainTranscriptUpdates()
  -> LiveCaptionPipeline.apply(...)
  -> caption_turn_visible logs
  -> draft translation scheduling
  -> ViewModel snapshot debounce
  -> @Published liveCaptionTurns
```

New flow:

```text
recorder.drainTranscriptUpdates()
  -> DraftCaptionInputThrottler
      -> immediate apply for first draft, final, flush, replay-excluded paths
      -> trailing 200 ms coalescing for subsequent draft-only updates
  -> LiveCaptionPipeline.apply(...)
  -> caption_turn_visible logs
  -> draft translation semantic trigger policy
  -> immediate ViewModel snapshot publication by default
  -> @Published liveCaptionTurns
```

## Logging

Add source-throttle telemetry so future meeting analysis can separate source coalescing from translation throttling:

- `caption_input_throttle_scheduled`
- `caption_input_throttle_coalesced`
- `caption_input_throttle_fired`
- `caption_input_throttle_cancelled`

Metadata should include:

- `delayMilliseconds`
- `changedSegmentCount`
- `latestChangedSegmentID`
- `reason` for cancellation or immediate bypass
- active meeting and selected meeting IDs when available

No raw transcript text should be logged.

## Interaction With Translation Trigger Policy

The source input throttle and draft translation trigger policy solve different problems:

- Source input throttle reduces how often draft captions enter the caption pipeline.
- Draft translation trigger policy controls when a visible draft is stable enough to translate.

Both should remain active. The source throttle should reduce stale translations indirectly by reducing intermediate draft states, but translation should still prefer first draft, semantic boundary, content delta, and maximum-wait triggers.

## Interaction With UI Snapshot Debounce

After adding source input throttling, the UI snapshot debounce default should become zero. Source throttling is the primary control for high-frequency draft churn. The UI debounce remains available as a guard for future UI-only refresh pressure, but should not add default latency on top of the 200 ms source window.

Translation attachment snapshots should still publish immediately.

## Testing

Add focused unit coverage around `MeetingAgentViewModel` and/or the new throttler:

- First draft update applies immediately.
- Multiple draft-only updates within 200 ms apply only the latest result.
- A final update bypasses the throttle and cancels pending draft input.
- Manual stop flush bypasses the throttle and cancels pending draft input.
- Reset or meeting switch cancels pending draft input.
- Translation attachments still publish without source throttle delay.
- `liveCaptionSnapshotDebounceNanoseconds` defaults to zero while non-zero injected values still coalesce UI snapshots.

Run the full project test suite with `make test`.

## Performance Verification

After implementation, record a short meeting and analyze it with `scripts/analyze-meeting-performance.swift`.

Expected movement:

- `caption_turn_visible` count should drop materially.
- `caption_input_throttle_coalesced` should be non-zero during rapid speech.
- Draft translation stale rate should drop from the recent `45%+` level.
- Draft in-flight skip count should drop.
- Time to first live caption should remain near the current one-second range.
- Time to first draft translation should not regress materially.

The recent stop-after-replay log growth is a separate issue. This design reduces live input churn, but does not by itself fix post-stop or replay publication loops.
