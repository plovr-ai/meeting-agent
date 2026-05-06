# Translation Experience Architecture Design

## Context

The current realtime translation path has been repeatedly tuned, but user experience still oscillates between slow captions, poor boundaries, slow translation, stale translation, and excessive model calls.

Recent performance analysis shows the root issue is architectural rather than a single threshold:

- A 57-58 second meeting can trigger 28-34 hosted translation calls, all draft calls.
- Time to first visible translation has ranged from 3 seconds to 10 seconds.
- Translation provider latency is commonly around 2 seconds and can reach 7 seconds or more at p95.
- Deepgram streaming responses are high-frequency revisions rather than user-facing sentence units. In the latest fixture, 57 raw responses contained 47 interim responses, 10 final responses, and 0 `speech_final=true` responses.
- Existing draft translation keys are tied to the full mutable caption text, so provider results often return after the source caption has already changed.

The product decision is to use a two-layer translation model:

- Realtime translation should help the user understand the meeting immediately, accepting bounded approximate text.
- Stable translation should produce accurate meeting records, exports, summaries, and decisions.

## Goals

- Optimize translation using user-facing experience metrics, not only request success metrics.
- Decouple translation units from visible subtitle rows.
- Provide low-latency live translation without chasing every STT mutation.
- Produce accurate stable translations for records, summaries, decisions, and export workflows.
- Bound hosted model calls with explicit budgets.
- Preserve names, numbers, dates, commitments, uncertainty, and business terms.
- Make failures and degradation recoverable without blocking captions.

## Non-Goals

- Do not redesign the caption rendering path in this spec. Caption/translation decoupling is handled separately.
- Do not require a streaming translation provider for the first implementation.
- Do not remove the existing caption translation scheduler immediately.
- Do not expose tuning controls in the UI during the first implementation.
- Do not migrate or rewrite historical meeting artifacts in this design.

## Experience Metrics

Realtime understanding metrics:

| Metric | Target | Meaning |
| --- | ---: | --- |
| Time to First Live Translation | p50 <= 2.5s, p95 <= 4s | Delay before the user sees useful translated text. |
| Visible Translation Coverage | >= 90% | Share of live-caption-visible time with visible translation text. |
| Visible Translation Gap p95 | <= 2.5s | Longest common visible gaps between translation updates. |
| Translation Freshness p95 | <= 5s | Age of source text represented by visible translation. |
| Live Model Calls | <= 10-15/min | Hosted calls used for live understanding. |
| Bad Visible Translation Rate | <= 5% | Human or evaluator-labeled misleading live translations. |

Accurate record metrics:

| Metric | Target | Meaning |
| --- | ---: | --- |
| Stable Block Translation Success | >= 98% | Stable blocks translated or explicitly recovered. |
| Stable Translation Accuracy Score | Tracked by replay/eval set | Quality of final record translation. |
| Final Translation Rewrite Rate | Report only | Share of live translations replaced by stable final text. |
| Summary/Decision Source Coverage | 100% for key claims | Summaries and decisions trace to original or stable translated blocks. |

Post-stop work must be reported separately from realtime metrics.

## Architecture

The translation architecture is split from subtitle rendering:

```text
STT stream
  -> Caption Renderer
  -> Translation Unit Builder
      -> Live Understanding Translator
      -> Accurate Record Translator
```

Visible subtitle rows may update frequently. Translation units should update at a lower, user-meaningful cadence.

## Translation Units

### LiveTranslationUnit

`LiveTranslationUnit` is for realtime understanding. It represents only the stable prefix of the current speech, not the changing tail.

Suggested fields:

- `unitID`
- `speaker`
- `sourceLocale`
- `targetLocale`
- `stablePrefixText`
- `unstableTailText`
- `sourceSegmentIDs`
- `contextBefore`
- `revision`
- `createdAt`
- `deadline`
- `riskFlags`

The live unit is allowed to be incomplete. It must be safe enough for immediate understanding, not authoritative record keeping.

### StableTranslationBlock

`StableTranslationBlock` is for accurate records. It is emitted when a semantic block is stable enough to translate authoritatively.

Suggested fields:

- `blockID`
- `speaker`
- `sourceLocale`
- `targetLocale`
- `sourceText`
- `sourceSegmentIDs`
- `previousBlockSummary`
- `meetingGoalContext`
- `keyTerms`
- `boundaryReason`
- `createdAt`
- `sourceTextHash`
- `contextHash`

Stable blocks can be longer than visible subtitle rows because their goal is semantic completeness rather than screen readability.

## TranslationUnitBuilder

`TranslationUnitBuilder` owns the boundary between speech text and translation work.

Responsibilities:

- Consume transcript/caption state and produce live units and stable blocks.
- Track stable prefix growth separately from unstable tail text.
- Detect semantic boundaries without depending on Deepgram `speech_final`.
- Detect high-risk source changes such as numbers, negation, dates, names, and commitments.
- Prevent high-frequency interim updates from creating high-frequency translation calls.

Initial live unit trigger:

- Stable prefix has at least 6 English words.
- Stable prefix has at least 16 CJK characters.
- Source text reaches a semantic boundary.
- Or the first visible draft has existed for at least 900 ms.

Stable block trigger:

- Hard provider boundary when available.
- Speaker change.
- Terminal punctuation plus sufficient content.
- Pause/endpoint gap.
- Maximum semantic block duration or length.
- Manual stop/finalization.

Deepgram `is_final=true` should be treated as stable words, not as a user-facing translation final by itself.

## Live Understanding Translator

The live translator optimizes for continuity and latency.

### Lane Model

Use one lane per `speaker + sourceLocale + targetLocale`.

Each lane keeps:

- `lastVisibleSourcePrefix`
- `lastRequestedSourcePrefix`
- `pendingLatestUnit`
- `inFlightRequest`
- `lastVisibleTranslationAt`
- `rollingContext`
- `budgetState`

### Scheduling Rules

- One live request in flight per lane.
- At most 2 global live requests in flight.
- If a new unit arrives while a lane has an in-flight request, replace `pendingLatestUnit`; do not enqueue multiple stale requests.
- After a request completes, schedule the latest pending unit if it still satisfies trigger rules.
- Follow-up trigger requires at least one of:
  - semantic boundary;
  - at least 8 new English words;
  - at least 24 new characters;
  - visible translation age exceeds 2.5 seconds;
  - high-risk content changed and requires correction.
- Default live call budget: 12 calls per minute.
- When budget is exceeded, downgrade live scheduling to semantic boundaries, long pauses, or stable blocks only.
- Live provider timeout: 4 seconds. Timed-out results are discarded and the next unit can recover.

Live translations are display aids only. They must not become authoritative transcript translations.

## Accurate Record Translator

The accurate translator optimizes for completeness and correctness.

Responsibilities:

- Translate every `StableTranslationBlock`.
- Use richer context and glossary.
- Retry recoverable failures.
- Continue post-stop finalization without contaminating realtime metrics.
- Produce authoritative translations for export, summaries, decisions, and meeting records.

Scheduling rules:

- Global concurrency: 1 by default.
- Stable block translations outrank live translations only during post-stop finalization or when the block is needed for export/summary.
- Accurate provider timeout: 15 seconds.
- Retry once for retryable provider/network failures.
- If adjacent stable blocks are later determined to belong together, retranslate the merged block with a bounded rewrite scope.

## Prompt Strategy

### Live Prompt

Live prompt intent:

```text
You are translating live meeting speech for immediate understanding.
Prefer concise, natural target-language meaning.
The source may be an incomplete stable prefix.
Do not invent unstated decisions.
Preserve names, numbers, product terms.
Return JSON only.
```

Live request input:

- Current stable prefix.
- Previous short stable block summary.
- Recent glossary/key terms.
- Previous visible translation for consistency.
- Source and target locales.
- Speaker label if available.

### Accurate Prompt

Accurate prompt intent:

```text
You are producing the accurate meeting record translation.
Translate the complete stable speech block naturally.
Preserve intent, decisions, obligations, uncertainty, names, numbers, and business terms.
Use the meeting context and glossary.
Return JSON only.
```

Accurate request input:

- Complete stable block.
- Previous 1-2 stable blocks with source and translation.
- Meeting goal.
- Key terms/glossary.
- Speaker label.
- Source and target locales.

## Caching

Use separate caches for live and accurate translation.

`livePrefixCache` key:

- normalized stable prefix
- locale pair
- glossary version

`stableBlockCache` key:

- block source text hash
- locale pair
- context hash

`termCache` key:

- normalized term
- locale pair
- glossary version

Cache hit behavior:

- Live cache hits may display immediately.
- Accurate cache hits may finalize a block only when context hash matches.
- If context changes, accurate translations can be revalidated or retranslated. Live translations can remain visible until replaced.

## Translation State

Visible translation must carry explicit state:

- `none`
- `pending`
- `liveFresh`
- `liveLagging`
- `liveCarried`
- `stableFinal`
- `failedRecoverable`
- `disabledBudget`

State semantics:

- `liveFresh`: corresponds to the current stable prefix.
- `liveLagging`: corresponds to an older but safe prefix.
- `liveCarried`: temporarily carries previous visible text while source updates.
- `stableFinal`: authoritative accurate translation.
- `failedRecoverable`: current request failed; later units can recover.
- `disabledBudget`: live calls are throttled by budget and stable translation remains active.

Display priority:

```text
stableFinal > liveFresh > liveLagging > liveCarried > pending > none
```

## Safety Rules

Do not carry forward or approximate attach if any high-risk source change is detected:

- numbers, amounts, percentages;
- dates or times;
- negation or modality changes;
- obligations or commitments;
- names, companies, products, or locations;
- speaker change;
- source locale or target locale change.

When a high-risk change occurs, prefer `pending` or no visible translation over misleading text.

Low-confidence STT text should reduce live translation frequency or wait for a stable prefix. Accurate translation can still process stable blocks after finalization.

## UI Semantics

The UI should communicate uncertainty without distracting the user:

- `liveFresh` and `stableFinal` display normally.
- `liveLagging` and `liveCarried` may use a subtle status indicator or weaker style.
- `pending` should not show a prominent spinner in the main caption area.
- Stable final replacement should be quiet unless the text changes substantially.
- A visible translation should update at most once every 1.5 seconds, except for `stableFinal` or high-risk correction.

The user should experience a steady translation stream, not rapid text churn.

## Storage Semantics

Persist live and stable translations separately:

- `liveTranslations`: optional display-layer artifacts for replay and telemetry.
- `stableTranslations`: authoritative translations for transcript, export, summary, and decisions.

Export behavior:

- Prefer `stableFinal`.
- Fall back to source text if stable translation is missing.
- Live approximate translation may be used only for explicitly marked preview/replay modes.
- Summaries and decision extraction must not use live approximate translation as factual source.

## Components

### TranslationUnitBuilder

Produces `LiveTranslationUnit` and `StableTranslationBlock`.

### LiveTranslationScheduler

Handles live lane scheduling, budgets, in-flight suppression, stale result classification, cache lookup, and display state.

### AccurateTranslationScheduler

Handles stable block queueing, accurate context construction, retries, finalization, and authoritative result writes.

### TranslationContextStore

Stores rolling context:

- recent stable source blocks;
- recent stable translations;
- glossary/key terms;
- speaker labels;
- meeting goal context;
- context hashes.

### TranslationResultStore

Stores live and stable translation results separately and exposes display projection for the UI.

### TranslationPerformanceAnalyzer

Extends current performance analysis with experience-first metrics:

- first live translation;
- visible coverage;
- visible gap;
- freshness;
- live calls per minute;
- stable success rate;
- post-stop backlog;
- cache hit rate;
- high-risk correction count.

## Migration Plan

1. Add translation unit and result models plus telemetry events.
2. Implement `TranslationUnitBuilder` behind tests and replay existing Deepgram fixtures.
3. Implement `LiveTranslationScheduler` with a mock provider and replay tests.
4. Connect `LiveTranslationScheduler` to the existing OpenRouter provider.
5. Implement `AccurateTranslationScheduler` and stable result storage.
6. Update UI projection to use explicit translation state.
7. Add post-stop finalization for stable translations.
8. Keep existing `CaptionTranslationScheduler` as a legacy adapter for replay/historical paths.
9. Remove legacy realtime caption translation once new realtime path is verified.

## Testing

Unit tests:

- `TranslationUnitBuilderTests`
  - interim churn does not create excessive live units;
  - stable prefix grows predictably;
  - high-risk content changes are detected;
  - stable blocks are generated without `speech_final=true`;
  - speaker changes produce stable block boundaries.

- `LiveTranslationSchedulerTests`
  - one in-flight request per lane;
  - pending latest replaces older pending units;
  - global and per-minute budgets work;
  - provider timeout recovers on the next unit;
  - old prefix result can attach as `liveLagging` when safe;
  - high-risk changes prevent carry-forward.

- `AccurateTranslationSchedulerTests`
  - stable blocks include context and glossary;
  - retry and timeout behavior is correct;
  - final translation overwrites live display projection;
  - post-stop backlog is reported separately.

- `TranslationContextStoreTests`
  - context hash changes trigger accurate revalidation;
  - glossary version affects cache keys;
  - meeting goal and speaker labels are available to prompt construction.

Replay tests:

- Replay latest Deepgram fixture and recent performance logs.
- Compare old and new metrics:
  - first live translation;
  - visible coverage;
  - visible gap p95;
  - freshness p95;
  - calls per minute;
  - hidden stale rate;
  - stable block success.

## Acceptance Criteria

- A 57 second meeting produces no more than 12-15 live hosted translation calls by default.
- First live translation reaches p50 <= 2.5s and p95 <= 4s on comparable meetings.
- Visible translation coverage is at least 90%.
- Visible translation gap p95 is <= 2.5s.
- Stable block translation success is at least 98%.
- Stable translations, not live approximate translations, feed summary, decision, and export workflows.
- Post-stop translation work is excluded from realtime metrics.
- High-risk source changes do not show stale or carried translations.

## Risks

- Live translation may feel too conservative if stable prefix detection is too strict.
  - Control: use replay metrics for first translation and coverage.
- Accurate translation may lag behind during long meetings.
  - Control: separate post-stop backlog and show finalization state outside the live caption area.
- Users may misinterpret live approximate translations as final.
  - Control: explicit state model and subtle UI semantics.
- Model call budget may under-serve fast multi-speaker meetings.
  - Control: lane-aware budgeting and stable block fallback.
- Context-rich prompts may increase latency.
  - Control: keep live prompt small and reserve richer context for accurate translation.
