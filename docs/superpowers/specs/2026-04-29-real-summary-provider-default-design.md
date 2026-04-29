# Real Summary Provider Default Design

## Context

Issue #67 asks to remove the mock meeting summary provider default and make summary generation match the real model configuration shown in Settings. The app already stores an OpenRouter API key and hosted summary model in `SpeechTranscriptionConfiguration`, and `OpenRouterMeetingSummaryProvider` records generated summaries as `openrouter:<model>`.

## Goals

- Make the default meeting summary provider OpenRouter-backed.
- Use the Settings OpenRouter API key and hosted summary model without requiring `MEETING_AGENT_SUMMARY_PROVIDER=openrouter`.
- Remove `ExtractiveMeetingSummaryProvider` from production code and tests.
- Keep deterministic title normalization because OpenRouter summaries still need a local fallback when the model omits or returns a noisy title.

## Non-Goals

- Add another summary provider.
- Change the OpenRouter summary JSON schema.
- Add network model discovery.
- Remove deterministic goal-oriented summaries for meetings with progress snapshots.

## Selected Approach

`MeetingAgentViewModel.summaryProvider(for:)` will always construct `OpenRouterMeetingSummaryProvider` from `SpeechTranscriptionConfiguration`, using the configured OpenRouter API key and hosted summary model, with the existing environment variables as developer fallback values. `MEETING_AGENT_SUMMARY_PROVIDER` will no longer select the extractive provider.

`ExtractiveMeetingSummaryProvider` and its heuristic summary-section tests will be removed. Tests that need successful summary generation will inject a deterministic test provider through the existing `summaryProviderFactory`, while default-provider tests will assert the OpenRouter provider and missing-credential failure behavior.

## Testing

- Add coverage that the default summary provider is `openrouter:<hostedSummaryModelID>` when settings contain an API key and model.
- Add coverage that `MEETING_AGENT_SUMMARY_PROVIDER=extractive-local` no longer switches away from OpenRouter.
- Update view-model summary artifact tests to inject a deterministic provider where the test is about view-model artifact behavior rather than provider selection.
- Keep OpenRouter request/parse tests for real provider behavior.

