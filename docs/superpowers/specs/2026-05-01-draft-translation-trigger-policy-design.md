# Draft Translation Trigger Policy Design

## Context

The latest meeting performance report shows the final translation reliability fix is working:

- `Final Translation Success Rate`: 100.0%
- `Final Visible Attach Rate`: 100.0%
- `Final True Failure Rate`: 0.0%

The remaining translation quality problem is draft waste:

- `Translation Success Rate`: 17.1%
- `Draft Translation Success Rate`: 14.9%
- `caption_translation_scheduled`: 76
- `caption_translation_stale`: 45

The current draft scheduler uses a fixed 200 ms debounce and keys draft requests to the full mutable live caption state. Deepgram interim captions change quickly, while the translation provider takes roughly two seconds at p50. That means many draft requests are already obsolete by the time they return. The product effect is delayed, jumpy, or missing realtime translation even though final translation now works.

## Goals

- Keep the first draft translation fast, targeting a visible translation within roughly two seconds when provider latency allows it.
- Reduce draft stale rate by avoiding translation requests for every small interim caption change.
- Trigger follow-up draft translation on useful semantic moments: pause, punctuation, enough new content, or maximum wait.
- Preserve final translation reliability and priority.
- Add readable telemetry so meeting analysis can explain draft trigger, skip, stale, and visible-update behavior.

## Non-Goals

- Do not change the translation provider.
- Do not implement streaming translation.
- Do not weaken final translation attach, rebind, or persistence behavior.
- Do not redesign `CaptionTurnAssembler` or the whole caption unit model.
- Do not hide stale draft results by attaching them unsafely.

## Selected Approach

Use a draft-specific trigger policy inside the caption translation scheduler.

The policy is a small state machine that decides whether a draft turn is worth translating. It does not call the provider and does not attach translations. It only returns a decision:

- `trigger(reason)`: schedule a draft translation request.
- `skip(reason)`: do not schedule a request and log why.
- `completeWithoutText`: keep existing same-language behavior.

Final turns bypass this policy and continue using the stable final translation path.

## Trigger Strategy

Use a two-phase strategy.

### Phase 1: Fast First Translation

For each live draft turn, the first draft translation should fire quickly:

- `initialDraftDebounce`: 200 ms
- reason: `initial`

This preserves the user's need to see translation quickly instead of waiting for a full sentence.

### Phase 2: Gated Follow-Up Translation

After the first draft request for a turn, the scheduler should stop chasing every interim caption mutation. A follow-up request fires only when at least one useful condition is met:

- A semantic boundary appears: `. ? ! , ; : 。？！、，；：`, newline, or a source segment signal such as `speechFinal`.
- Enough new content has appeared since the last requested draft: default 8 words or 48 characters.
- The user has not seen an updated draft translation for too long: default maximum wait 3.0 seconds.

The scheduler should also enforce:

- `followUpDraftMinimumInterval`: 1.5 seconds.
- One in-flight draft request per turn.
- Final requests always outrank draft requests.

Default values are intentionally conservative and should live in `CaptionTranslationSchedulerConfiguration` so tests and later product tuning can adjust them.

## Draft Policy State

Track lightweight state per live caption turn:

- Whether the first draft request has been sent.
- Last requested draft source text hash.
- Last requested word count and character count.
- Last draft request time.
- Last visible draft translation publish time.
- Whether a draft request is currently in flight for this turn.

The state is scheduler-local. It resets with the existing pipeline reset/generation behavior and should be pruned when turns are removed or superseded by hard final turns.

## Data Flow

1. `LiveCaptionPipeline.apply` receives an interim or final transcript update.
2. `CaptionTurnAssembler` updates the live caption store.
3. `scheduleLiveTranslations()` asks `CaptionTranslationScheduler` for updates.
4. For final turns, the scheduler uses the existing final translation path.
5. For draft turns, the scheduler asks the draft trigger policy for a decision.
6. If the policy triggers, the scheduler creates the existing `ActiveCaptionTranslationRequest`.
7. If the policy skips, the scheduler emits telemetry and does not call the provider.
8. Provider results still pass through the current draft key validation before attachment.
9. If a draft result is stale, it remains stale and must not overwrite newer text.
10. When a hard final turn arrives, draft in-flight state for superseded turns is cancelled or ignored and final translation proceeds.

## Telemetry

Add readable draft policy events:

- `caption_translation_draft_triggered`
  - `reason`: `initial`, `semantic_boundary`, `content_delta`, `max_wait`
- `caption_translation_draft_skipped`
  - `reason`: `in_flight`, `min_interval`, `not_stable_enough`, `superseded_by_final`

Include metadata where available:

- `wordDelta`
- `characterDelta`
- `millisecondsSinceLastDraftRequest`
- `millisecondsSinceLastVisibleDraftTranslation`
- `hasSemanticBoundary`
- `translationRequestID`
- `turnID`
- `sourceSegmentIDs`

Keep existing request lifecycle events:

- `caption_translation_scheduled`
- `caption_translation_started`
- `caption_translation_finished`
- `caption_translation_attached`
- `caption_translation_stale`
- `caption_snapshot_published`

## Analysis Metrics

Extend `scripts/analyze-meeting-performance.swift` with readable draft metrics:

- `Draft Translation Trigger Rate`
- `Draft Translation Skip Rate`
- `Draft Translation In-Flight Skip Count`
- `Draft Translation Semantic Boundary Trigger Count`
- `Draft Translation Max-Wait Trigger Count`
- `Draft Translation Stale Rate`
- `Time to First Draft Translation`
- `Draft Visible Update Interval p50/p95`

The existing overall translation metrics remain, but the report should make clear that final reliability and draft responsiveness are separate product surfaces.

## Success Criteria

For a new meeting comparable to the latest log:

- `Final Translation Success Rate` remains at least 95%.
- `Final Visible Attach Rate` remains at least 95%.
- `Time to First Translation` does not regress materially; target is no worse than 2.5 seconds when provider latency allows it.
- `Draft Translation Stale Rate` drops materially from the latest baseline and should target less than 25-30%.
- Draft scheduled request count decreases relative to similar caption volume.
- Diagnostics should identify whether remaining delay comes from trigger policy, provider latency, or in-flight suppression.

## Edge Cases

- Long sentence without punctuation: `followUpDraftMaximumWait` triggers a request.
- Short repeated corrections: minimum interval and content delta prevent excessive requests.
- Caption changes while provider is translating: skip with `in_flight`; do not queue redundant draft requests.
- Final arrives quickly: cancel or suppress draft work and let final translation attach.
- Same-language meetings: preserve existing complete-without-text behavior.
- Provider is slow: in-flight skips rise, but request volume stays bounded and telemetry exposes provider latency.
- Locale or pipeline reset: existing generation guard discards old results.

## Alternatives Considered

### Pure Time Throttle

Throttle follow-up draft requests to a fixed interval, such as one request every two seconds. This is simple, but it can still translate mid-thought and does not use available semantic signals. It may reduce cost without improving perceived quality enough.

### Translate Stable Prefix Only

Translate only the stable prefix of a draft caption and ignore the unstable tail until final. This would minimize stale results, but it requires deeper integration with caption chunking and may make translations feel incomplete. It is a good later enhancement, not the first fix.

### Selected Middle Path

Use fast first translation plus semantic gating and maximum-wait fallback. This keeps first translation responsive while substantially reducing obsolete follow-up requests.

## Test Plan

- Scheduler test: first draft request triggers after short debounce.
- Scheduler test: small draft text changes within the minimum interval are skipped.
- Scheduler test: semantic boundary triggers follow-up translation.
- Scheduler test: word or character delta triggers follow-up translation.
- Scheduler test: maximum wait triggers follow-up translation even without punctuation.
- Scheduler test: an in-flight draft request suppresses redundant requests for the same turn.
- Scheduler test: hard final turns bypass draft policy and cancel superseded draft state.
- Pipeline test: replay and flush still do not schedule draft translations.
- Analysis script test: new draft trigger and skip metrics are reported with readable names.
- Regression test: final translation success metrics continue to count attached and persisted final translations correctly.
- Full verification: run `make test`.

## Implementation Boundaries

Expected affected areas:

- `Sources/MeetingAgentCore/CaptionTranslationScheduler.swift`
- `Sources/MeetingAgentCore/LiveCaptionPipeline.swift`
- `scripts/analyze-meeting-performance.swift`
- `Tests/MeetingAgentCoreTests/CaptionTranslationSchedulerTests.swift`
- `Tests/MeetingAgentCoreTests/LiveCaptionPipelineTests.swift`
- `Tests/MeetingAgentCoreTests/MeetingPerformanceAnalysisScriptTests.swift`

Avoid unrelated UI, provider, and transcript storage changes.
