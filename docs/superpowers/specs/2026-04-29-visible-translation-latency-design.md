# Visible Translation Latency Design

## Goal

Reduce perceived bilingual caption latency by making draft translation serve the latest visible caption turn first. Source captions should remain high-frequency and independent from translation. Final translations should not wait behind stale draft work.

## Current Behavior

`MeetingAgentViewModel.refreshLiveCaptionTurnsFromSelectedMeeting()` runs after recording drains frames. It reads `transcript.json`, ingests final and interim segments into `LiveCaptionStore`, updates `liveCaptionTurns`, attaches realtime translations, then calls `scheduleCaptionTextTranslationIfNeeded()`.

The scheduler currently finds all pending draft and final candidates. Draft candidates are scheduled when a turn is pending, is not final, and either has never been translated, grew enough text, or crossed the draft retry interval. Final candidates are hard-sealed turns from `speechFinal` or `speakerChanged` boundaries. Draft requests are per-turn cancellable tasks, while final requests are processed serially in one task.

This reduced stale completion after issue #63, but the latest meeting still showed many started and finished draft requests that did not attach. The remaining waste comes from eager draft triggering and from no unified prioritization across draft and final work.

## Product Choice

Optimize for lowest visible latency. It is acceptable for intermediate draft revisions to never be translated. It is not acceptable for current visible captions or hard-final captions to wait behind stale draft work.

## Proposed Design

Introduce a small translation work scheduler inside `MeetingAgentViewModel`. Keep source caption ingestion as-is. Replace direct task creation in `scheduleCaptionTextTranslationIfNeeded()` with a scheduler that tracks pending intents, running tasks, and completion.

The scheduler keeps:

- `pendingDraftRequestsByTurnID`: latest draft request per turn.
- `runningDraftTurnIDs`: draft turns currently inside provider work.
- `runningFinalTurnIDs`: final turns currently inside provider work.
- `maxConcurrentCaptionTranslations = 2`.
- `maxConcurrentDraftTranslations = 1`.

Final requests are priority work. When a hard final candidate appears, it cancels superseded draft requests for the same turn or previous same-speaker turns, then enters the pending final queue. Draft requests are replacement work. A newer draft request for the same turn replaces older pending draft work and cancels older not-yet-started task state.

`pumpCaptionTranslationWork()` starts work while capacity is available:

1. Start pending final requests first, up to total capacity.
2. Start at most one draft request if a draft slot and total capacity are available.
3. Choose the latest visible draft request by caption order and creation time.
4. After any task finishes, clear running state and pump again.

Draft provider calls still validate before start and before attach. Final provider calls validate before attach. Stale draft completions are logged with a stale reason and never mutate visible state.

## Trigger Policy

`scheduleCaptionTextTranslationIfNeeded()` remains the only entrypoint after caption store updates and manual flushes. It will:

- Complete same-language turns without provider work.
- Build final candidates from hard-sealed pending turns.
- Build draft candidates from pending draft or soft-sealed turns.
- Submit candidates to scheduler instead of immediately starting provider calls.

Draft eligibility changes:

- The first visible draft can translate immediately only if it is the newest visible draft turn.
- Existing visible draft translations refresh only when the turn remains the newest visible draft and either grows by at least 120 characters or has no current translated text.
- Soft-sealed turns remain eligible, but lose priority to hard-final work.

## Observability

Every translation request gets a `translationRequestID`. The same ID is logged on scheduled, started, finished, attached, cancelled, and stale events. Metadata also includes `translationRevision`, `translationKeyHash`, and `staleReason` when relevant.

Performance analysis should use request IDs instead of matching by segment ID and text length. This makes started-to-finished and finished-to-attached measurements reliable even when text length changes or repeated captions share IDs.

## Tests

Add focused `MeetingAgentViewModelTests` coverage:

- Rapid updates to the same draft turn keep only the latest pending provider request.
- Draft requests for older turns do not start while the latest visible draft is pending.
- Hard-final requests start before draft requests and are not blocked by draft work.
- Different speaker hard-final requests can run concurrently up to total capacity.
- Scheduled, started, stale, and attached logs share request IDs.

## Non-Goals

- Do not change STT or Deepgram segment mapping.
- Do not add UI settings for thresholds yet.
- Do not introduce a standalone scheduler target unless the view model implementation becomes hard to test.
- Do not optimize post-stop refresh behavior in this pass, except by making logs distinguish stale/cancelled work.

## Success Metrics

On a live Deepgram meeting:

- `caption_translation_attached / caption_translation_started` should improve from about 0.23 toward at least 0.45.
- `caption_translation_attached / caption_translation_finished` should improve from about 0.42 toward at least 0.65.
- `caption_translation_schedule_to_start` p90 should stay below 0.5s for final requests.
- Latest visible draft translation should attach within about 2s p50 when the provider responds in that range.
