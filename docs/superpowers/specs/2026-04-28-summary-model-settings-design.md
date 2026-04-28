# Summary Model Settings Design

## Context

Issue #57 asks for real meeting summary model configuration in Settings. Summary generation should continue to use the OpenRouter provider, but the selected model must be independent from the translation model. The app already stores speech, transcription, translation, provider credential, and Deepgram settings in `SpeechTranscriptionConfiguration`.

## Goals

- Add an independent OpenRouter summary model setting.
- Show the summary model in Settings separately from the translation model.
- Persist the selected summary model across app launches.
- Use the configured summary model when OpenRouter summary generation runs.
- Keep the existing environment-variable fallback for development and existing users.

## Non-Goals

- Add a new summary provider.
- Change the translation model setting.
- Change the summary JSON schema.
- Add network model discovery.

## Selected Approach

Add `hostedSummaryModelID` to `SpeechTranscriptionConfiguration`, with `openai/gpt-4.1-mini` as the default. This keeps summary configuration separate from transcription and translation while following the existing app settings pattern. `BilingualPipelineFactory` will expose a small curated `hostedSummaryModelOptions` list for Settings.

`MeetingAgentViewModel` will pass the selected summary model to `OpenRouterMeetingSummaryProvider` when `MEETING_AGENT_SUMMARY_PROVIDER=openrouter`. The provider will still fall back to `MEETING_AGENT_OPENROUTER_MODEL` when no app configuration model is supplied, preserving current environment-driven behavior.

## Model Options

The default summary model is `openai/gpt-4.1-mini`. It is already documented in the repository for OpenRouter summaries and is a reasonable low-cost default for structured JSON meeting summaries.

Initial options:

- `openai/gpt-4.1-mini` - GPT-4.1 Mini
- `google/gemini-2.5-flash` - Gemini 2.5 Flash

## UI

The OpenRouter Settings panel will contain:

- `SecureField("OpenRouter API Key", ...)`
- `Picker("Hosted Translation Model", ...)`
- `Picker("Hosted Summary Model", ...)`

This keeps all OpenRouter-backed settings together while making summary and translation model choices visibly distinct.

## Data Flow

1. Settings edits `draft.hostedSummaryModelID`.
2. Saving Settings persists `SpeechTranscriptionConfiguration`.
3. `MeetingAgentViewModel.generateSummary` reads the current app configuration.
4. If `MEETING_AGENT_SUMMARY_PROVIDER=openrouter`, the view model creates `OpenRouterMeetingSummaryProvider` with the configured API key and summary model.
5. The summary artifact records the provider as `openrouter:<model>`.

## Testing

- Add default and round-trip coverage for `hostedSummaryModelID`.
- Add backward decoding coverage so older saved settings get the default summary model.
- Add a Settings source-layout assertion for `Picker("Hosted Summary Model"`.
- Add summary provider/view-model coverage proving the selected model is used independently from translation.

