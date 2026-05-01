# Draft Translation Visible Continuity Design

## Context

The latest Deepgram meeting data shows that the 200 ms draft caption input throttle is working. Visible caption churn and total performance events dropped substantially, but user-visible translation latency remains high.

Latest meeting findings:

- Time to first live caption: about 1 second.
- Time to first visible translation: about 9 seconds.
- Draft translation stale rate: about 41%.
- Translation provider latency is commonly around 2 seconds.
- Several early draft translations finished successfully but were discarded because the source caption had changed before the provider returned.

The current draft apply rule is too strict for live meeting UX. A draft translation must still match the current mutable draft key before it can attach. This protects correctness, but it also creates long visible translation gaps when Deepgram updates the source text faster than the translation provider can return.

## Product Principle

Prefer continuous, slightly lagging draft translation over long periods with no translation.

Draft translation is allowed to represent a stable prefix or near-current version of the current source caption, as long as it is clearly bounded, observable, and always superseded by fresher draft or final translation. Final translation remains authoritative.

## Goals

- Reduce time to first visible translation from the latest 9 second baseline to a target p50 under 3 seconds and p95 under 5 seconds for similar meetings.
- Maintain visible translation coverage for at least 85% of the time when live source captions are visible.
- Keep visible translation gap p95 under 3 seconds.
- Reduce provider-successful but hidden draft stale outcomes to less than 20%.
- Preserve final translation reliability and priority.
- Make the analysis script report user-facing translation visibility, not only internal request success.

## Non-Goals

- Do not change the translation provider in this design.
- Do not require streaming translation.
- Do not increase source caption input throttle beyond the existing 200 ms default.
- Do not let approximate draft translation overwrite final translation.
- Do not expose tuning controls in the UI yet.

## Result Metrics

These metrics describe what the user experiences.

| Metric | Target | Meaning |
| --- | ---: | --- |
| Time to First Visible Translation | p50 <= 3s, p95 <= 5s | Time from meeting audio/caption start to first visible translation text. |
| Visible Translation Coverage | >= 85% | Share of live-caption-visible time that also has visible translation text. |
| Visible Translation Gap p95 | <= 3s | p95 duration between visible translation updates or coverage periods. |
| Draft Translation Hidden Stale Rate | <= 20% | Provider-successful draft results that still cannot be shown. |
| Draft Translation Approximate Attach Rate | Report only | Share of stale draft results safely used as visible translation. |
| Translation Freshness p50/p95 | p50 <= 2s, p95 <= 5s | Age difference between current source caption and the source text represented by visible translation. |
| Final Translation Success Rate | >= 95% | Final requests that attach or persist successfully. |
| Final Overrides Draft Rate | Report only | Final translations replacing draft/approximate/carry-forward text. |

The most important product metrics are first visible translation, visible coverage, and visible gap. Request volume is a process metric, not the primary success definition.

## Process Metrics

These metrics explain why the result metrics changed.

- Draft Translation Scheduled Count.
- Draft Translation Provider Latency p50/p95.
- Draft Translation Source Change During Provider Time.
- Draft Translation Exact Attach Rate.
- Draft Translation Approximate Attach Rate.
- Draft Translation Hidden Stale Rate.
- Draft Translation Carry Forward Count.
- Visible Translation Source Lag in characters, words, and milliseconds.
- Draft Trigger Reason Distribution: `initial`, `semantic_boundary`, `content_delta`, `max_wait`.
- Draft Skip Reason Distribution: `in_flight`, `min_interval`, `not_stable_enough`.

The analysis should answer whether the remaining delay came from no request, queue wait, provider latency, source churn during provider work, hidden stale rejection, or final attach failure.

## Selected Approach

Add a visible-continuity layer for draft translations.

The scheduler should no longer treat draft provider completion as a binary exact attach or discard. Instead, it should classify the completion:

1. `exact_attach`: request source still matches the current draft key and can attach normally.
2. `approximate_attach`: request source is older than the current draft but safely represents the current text's stable prefix or near-current meaning.
3. `hidden_stale`: request source is too old or unrelated and must not be shown.

In addition, when the source caption changes and no fresher translation is available yet, the live caption may carry forward the last visible draft translation for the same turn. Carry-forward is display continuity, not final correctness.

## Draft Trigger Policy Changes

Keep the existing 200 ms source caption input throttle.

Draft translation triggering should be separate from source caption rendering:

- Do not immediately translate very short first drafts.
- Initial draft translation becomes eligible when at least one condition is true:
  - normalized source text length is at least 32 characters;
  - source text has at least 6 words;
  - source text ends at a semantic boundary;
  - the first visible draft has existed for at least 800 ms.
- Follow-up draft translation continues to use semantic boundary, content delta, and maximum wait.
- Consider lowering follow-up maximum wait from 3 seconds to 2-2.5 seconds if coverage gaps remain high after approximate attach is implemented.

This avoids wasting the first request on fragments such as a 16-character draft while preserving a bounded path to first visible translation.

## Draft Completion Classification

When a draft result returns, evaluate it against the current live turn.

Exact attach requires the existing strict draft key match.

Approximate attach is allowed only when all required constraints hold:

- Same live turn ID.
- Same source locale and target locale.
- Current turn is still draft or soft-sealed, not hard-final.
- Request source text is not too short: at least 24 characters or at least 5 words.
- Result age is not too old: default maximum 6 seconds from request creation to attach decision.
- Current normalized source text still contains the request source text as a stable prefix, or normalized source similarity is at least 0.75.
- Speaker has not changed in a way that would make the turn represent a different participant.

If any required constraint fails, classify as `hidden_stale`.

Approximate attach must not mark the translation final. A later exact draft or final translation can replace it.

## Visible Translation Freshness

Each live caption turn needs display metadata for translation freshness.

Suggested states:

- `fresh`: visible draft translation corresponds to the current source text.
- `approximate`: visible draft translation corresponds to an older but safe source prefix or near-current source.
- `carried`: source caption changed after a visible translation, and the same translation is being held until fresher text arrives.
- `final`: final translation has attached and is authoritative.

Display priority:

```text
final > fresh draft > approximate draft > carried draft > no translation
```

Carry-forward happens only within the same turn and locale pair. It is cleared when the turn is hard-final and no final translation is available, when the speaker/source identity changes, when the translation age exceeds its maximum, or when a fresher translation attaches.

## Data Flow

1. Deepgram emits draft transcript updates.
2. The existing 200 ms source input throttle coalesces high-frequency draft caption updates before they enter the live caption pipeline.
3. The draft trigger policy decides whether the current draft text is worth sending to the provider.
4. The provider returns a draft translation.
5. The scheduler compares request source text with the current turn.
6. The result becomes exact attach, approximate attach, or hidden stale.
7. The live caption turn records visible translation text plus freshness metadata.
8. If source text changes before a fresher translation arrives, the previous visible draft can be carried forward.
9. Final translation always overrides draft, approximate, and carried text.
10. Performance analysis reports visible coverage and freshness rather than only scheduled/attached/stale request counts.

## Telemetry

Keep existing request lifecycle events and add visibility-specific outcomes:

- `caption_translation_exact_attached`
- `caption_translation_approximate_attached`
- `caption_translation_hidden_stale`
- `caption_translation_carried_forward`
- `caption_translation_freshness_changed`
- `caption_translation_visibility_gap_started`
- `caption_translation_visibility_gap_ended`

Important metadata:

- `translationFreshness`: `fresh`, `approximate`, `carried`, `final`.
- `sourceTextLength`.
- `currentTextLength`.
- `sourceLagCharacters`.
- `sourceLagWords`.
- `sourceLagMilliseconds`.
- `sourceSimilarity`.
- `attachDecision`: `exact_attach`, `approximate_attach`, `hidden_stale`.
- `attachRejectReason`.
- `visibleTranslationAgeMilliseconds`.
- `translationRequestID`.
- `turnID`.
- `sourceSegmentIDs`.

The existing `caption_translation_attached` event can remain for backwards-compatible success counting, but the new exact/approximate events should make the attach type explicit.

## Analysis Script Updates

`scripts/analyze-meeting-performance.swift` should add a user-experience section:

- Time to First Visible Translation.
- Visible Translation Coverage.
- Visible Translation Gap p50/p95/max.
- Translation Freshness p50/p95/max.
- Exact Draft Attach Rate.
- Approximate Draft Attach Rate.
- Hidden Draft Stale Rate.
- Carry Forward Count.
- Final Override Count.

The report should distinguish:

- provider success but hidden stale;
- provider success shown approximately;
- carried-forward visibility without a new provider result;
- final attach or persist success.

This makes stale rate less misleading. A draft result can be stale relative to the latest source key but still improve user-visible coverage if it safely attaches approximately.

## Safety Rules

- Approximate draft translation never attaches across different turn IDs.
- Approximate draft translation never attaches after a hard final for the turn.
- Approximate or carried draft translation never overwrites final translation.
- Same-language meetings preserve complete-without-text behavior.
- Provider errors remain failures and do not trigger carry-forward by themselves.
- Locale or provider configuration changes invalidate all approximate and carried draft state.
- Replay, flush, and batch paths should not create new draft approximate attaches; they may still report final backfill outcomes.

## Validation Plan

Use the latest meeting as a replay or comparison target.

Baseline from the latest recording:

- Time to first visible translation: 9 seconds.
- Draft stale rate: about 41%.
- Overall translation success rate: about 35%.
- Final transcript translations exist for some final segments, but final visible metrics need clearer event classification.

Expected improvement:

- Time to first visible translation drops to 3-5 seconds for similar provider latency.
- Visible translation coverage reaches at least 85%.
- Visible translation gap p95 is under 3 seconds.
- Hidden stale rate drops below 20%.
- Exact attach plus approximate attach visible success reaches at least 65%.
- Final translation success remains at least 95% after script metric correction.

## Test Plan

- Scheduler test: a provider result with an exact current draft key logs exact attach and marks freshness `fresh`.
- Scheduler test: a provider result whose source text is a stable prefix of the current draft logs approximate attach and marks freshness `approximate`.
- Scheduler test: a short stale source text does not approximate attach and logs hidden stale with a reject reason.
- Scheduler test: a low-similarity stale source text does not approximate attach.
- Scheduler test: approximate draft does not attach after a hard final.
- Store/pipeline test: source text changes after approximate attach carries the visible translation forward within the same turn.
- Store/pipeline test: final translation overrides fresh, approximate, and carried draft states.
- Analysis script test: visible translation coverage and gap metrics are computed from visibility events.
- Regression test: final attach/persist metrics still count final success correctly.
- Full verification: run `make test`.

## Implementation Boundaries

Expected affected areas:

- `Sources/MeetingAgentCore/CaptionTranslationScheduler.swift`
- live caption turn/store translation metadata in `Sources/MeetingAgentCore/`
- `Sources/MeetingAgentCore/LiveCaptionPipeline.swift`
- `scripts/analyze-meeting-performance.swift`
- focused tests in `Tests/MeetingAgentCoreTests/`

Avoid unrelated UI redesign, provider replacement, Deepgram configuration changes, and broader transcript schema churn unless the existing live caption model cannot represent freshness metadata safely.
