# Live Caption Latency Metrics Design

## Context

Issue #120 asks for explicit realtime caption metrics after the caption lifecycle moved into `LiveCaptionPipeline`, `CaptionTurnAssembler`, and `CaptionTranslationScheduler`. The existing `PerformanceEventLogger` already writes JSONL events and the caption scheduler already logs request lifecycle events, but the pipeline does not yet expose all latency checkpoints or count/failure payloads needed to compare scheduler and provider changes.

## Goals

- Emit STT segment to caption visible latency without logging raw transcript text.
- Emit caption translation lifecycle metrics for scheduled, started, finished, attached, stale, cancelled, skipped, and failed paths.
- Include enough non-sensitive context to debug latency: turn IDs, source segment IDs, provider ID, locale pair, draft/final state, boundary metadata, request ordinal, queue depth, in-flight count, and duration in milliseconds where the code can measure it directly.
- Cover representative draft, final, stale, and failure payloads in tests.

## Non-Goals

- Do not add a second metrics sink or aggregated metrics database.
- Do not log raw transcript or translated text.
- Do not change user-visible caption or translation behavior.

## Selected Approach

Extend the existing `PerformanceEventLogger` JSONL event stream. `LiveCaptionPipeline` records when a changed transcript segment is received, then logs `caption_turn_visible` when the corresponding live caption turn is inserted or updated. `CaptionTranslationScheduler` continues to own translation lifecycle events and adds duration/count/error fields to the existing request events.

This keeps metrics co-located with the code that knows the timing boundary, avoids duplicate persistence, and lets tests assert event payload shape with the current JSONL decoder helpers.

## Event Shape

All new metadata values are strings to preserve the existing `PerformanceEvent.metadata` contract.

- `durationMilliseconds`: integer elapsed wall-clock milliseconds for a directly measured interval.
- `providerID`: translation provider identifier when a provider-backed request runs.
- `turnID`, `sourceSegmentID`, `sourceSegmentIDs`: caption identity without text.
- `sourceLocale`, `targetLocale`: language pair.
- `translationKind`: `draft` or `final`.
- `boundaryStrength`, `boundaryReason`: included when known.
- `requestOrdinalForTurn`, `queueDepth`, `inFlightCount`, `concurrencyLimit`: scheduler context.
- `failureReason`: sanitized provider error category for failure events.
- `count`: `1` on count events so downstream tooling can aggregate draft/final schedules, completions, stale discards, provider errors, and retries.

## Implementation Plan

1. Add duration helper support to `PerformanceEventLogger` without changing the encoded model.
2. Track segment receive times inside `LiveCaptionPipeline` and log `caption_turn_visible` when turns are upserted, appended, or replaced.
3. Log `caption_snapshot_published` after translation updates are applied, keyed to the translation request that attached text to a turn.
4. Extend scheduler metadata with provider ID and count events.
5. Add provider failure logging in `performTranslation`.
6. Add focused tests for pipeline event shape and scheduler draft/final/stale/failure payloads.

## Test Plan

- Run focused `swift test --filter LiveCaptionPipelineTests`.
- Run focused `swift test --filter CaptionTranslationSchedulerTests`.
- Run `make test` for the project coverage gate.
