# OpenRouter Translation E2E Test Architecture

## Context

The meeting-agent regression fixtures already preserve real meeting artifacts:

- `audio.wav`
- `transcript.json`
- `transcript-events.jsonl`
- `performance-events.jsonl`
- `translation-results.jsonl`
- `expected-ui.json`
- `manifest.json`

The current offline tests validate analyzer behavior and UI projection against fixture translation results. They do not prove that the active translation pipeline still works with the real OpenRouter provider, and they do not provide a clean opt-in gate for paid network-backed translation.

## Goal

Add an E2E test architecture that keeps speech recognition deterministic while validating real translation behavior.

The E2E suite must:

1. Use fixed fixture `audio.wav` and fixed Deepgram transcript outputs.
2. Validate caption UI correctness and caption performance offline.
3. Optionally call real OpenRouter translation against stable translation units.
4. Validate translated subtitle UI correctness and translation performance.
5. Keep default `make test` offline, deterministic, and free.

## Non-Goals

- Do not call OpenRouter during default unit tests.
- Do not use OpenRouter for STT in this E2E path.
- Do not commit model-generated OpenRouter text as exact golden output.
- Do not require exact translated phrasing from live model calls.

## Test Layers

### Offline Fixture E2E

This layer runs by default.

Inputs:

- Existing fixture transcript and performance events.
- Existing `translation-results.jsonl` for golden UI projection.

Assertions:

- Caption turns match expected `sourceSegmentIDs`.
- Bilingual and translation-only display modes match `expected-ui.json`.
- Analyzer passes expected caption and translation E2E status for golden fixtures.
- Caption KPIs remain within fixture expectations:
  - time to first live caption,
  - caption lag p50/p95/max,
  - caption stability,
  - batch/flush caption lag exclusion behavior.

This layer remains deterministic and belongs in `make test`.

### OpenRouter Translation E2E

This layer is opt-in and may use network and paid API calls.

Activation:

```sh
MEETING_AGENT_RUN_OPENROUTER_E2E=1 \
MEETING_AGENT_OPENROUTER_API_KEY=<key> \
MEETING_AGENT_OPENROUTER_E2E_MODEL=google/gemini-2.5-flash \
swift test --filter OpenRouterTranslationE2ETests
```

If `MEETING_AGENT_RUN_OPENROUTER_E2E` is not `1`, tests skip with `XCTSkip`.
If the API key is missing, tests skip with `XCTSkip`.
If the model is missing, tests use the existing configured default or a conservative default.

Inputs:

- Fixture `transcript.json` from Deepgram output.
- Fixture metadata for source and target locales.
- Existing caption chunking and unit translation runtime.

Flow:

1. Load a golden fixture transcript.
2. Rebuild realtime caption turns from the fixed transcript.
3. Build stable translation blocks with the active unit translation path.
4. Call `OpenRouterTextTranslationProvider` for those stable blocks.
5. Persist temporary `translation-results.jsonl` and `performance-events.jsonl` in a temp meeting directory.
6. Attach translation results back to the rebuilt caption UI.
7. Run `scripts/analyze-meeting-performance.swift --assert-translation-e2e` on the temp meeting directory.

Assertions:

- Provider calls start and finish.
- No provider failures or unavailable events occur.
- Stable translation results attach exactly to visible caption turns.
- No `translation_unit_projection_mismatch` events occur.
- Persisted translation records exactly match visible non-replay caption turn `sourceSegmentIDs`.
- No duplicate stable result persistence occurs.
- No realtime translation runtime snapshot is published after stop.
- Translation UI is not pending for translated turns.
- Bilingual display has translated primary text and original source text.
- Translation-only display has translated primary text and no source text.
- Translated text is non-empty.
- Translated text is not identical to source text after whitespace normalization.
- For `zh-CN`, translated text contains CJK characters.
- First live or stable visible translation latency is under the configured E2E budget.
- Stable coverage meets or exceeds the existing analyzer floor.

## Fixture Manifest Extensions

Add optional manifest fields:

```json
{
  "captionPerformanceBudgets": {
    "timeToFirstLiveCaptionSeconds": 2.0,
    "captionLagP95Seconds": 3.0,
    "captionStabilityMaxUpdatesPerFinal": 10.0
  },
  "openRouterTranslationE2E": {
    "enabled": true,
    "modelEnvironmentKey": "MEETING_AGENT_OPENROUTER_E2E_MODEL",
    "firstTranslationLatencySeconds": 4.0,
    "stableCoverageFloor": 0.8
  }
}
```

The fields are optional so existing fixtures continue to decode. Defaults match the current analyzer budgets where possible.

## Components

### Regression Fixture Support

Extend `RegressionFixtureManifest` with optional budget fields.

Add helpers to:

- load fixture artifacts into a temp meeting directory,
- project source caption turns without fixture translations,
- run analyzer against temp directories,
- assert caption performance budgets from analyzer output or parsed events.

### OpenRouter E2E Test

Add `OpenRouterTranslationE2ETests`.

Responsibilities:

- Skip unless explicitly enabled.
- Choose fixture(s) marked for OpenRouter translation E2E.
- Use real `OpenRouterTextTranslationProvider`.
- Generate temporary translation records and performance events.
- Assert UI projection and analyzer E2E success.

### Analyzer Contract

Reuse the existing analyzer as the final gate. Do not fork its translation E2E rules into the test. Unit assertions may inspect direct UI state for clearer failure messages, but the analyzer remains the authoritative performance and projection gate.

## Error Handling

- Missing opt-in env var: skip.
- Missing API key: skip.
- Network/API/model error: fail the opt-in E2E test with the provider error body if available.
- Malformed model JSON: fail, because the provider contract requires JSON output.
- Budget exceeded: fail with the specific metric name and observed value.

## Success Criteria

Default path:

- `make test` remains offline.
- Existing fixture analyzer and UI projection tests continue to pass.

Opt-in path:

- With valid OpenRouter credentials, `OpenRouterTranslationE2ETests` calls real OpenRouter translation.
- The generated translated UI has exact caption-turn projection.
- The analyzer E2E gate passes for the temp meeting directory.
- Failures identify whether the break is provider output, projection, persistence, UI display, or performance budget.
