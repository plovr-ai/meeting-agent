# Live Translation Settings Key Design

## Goal

Users should be able to configure the OpenAI Realtime API key used by Live Translation from the macOS app Settings page.

## Design

Add a dedicated `Live Translation` section to `SettingsView` with a secure `OpenAI Realtime API Key` field. This key is separate from the existing OpenRouter key because Live Translation connects directly to OpenAI Realtime, while OpenRouter remains the hosted text/transcription provider configuration.

Persist the value on `SpeechTranscriptionConfiguration` as an optional normalized string. Existing saved settings must continue to decode successfully when the field is absent.

When starting Live Translation, `MeetingAgentViewModel` should build `RealtimeTranslationConfiguration` using the saved OpenAI Realtime key first. If the Settings field is empty, it should keep the current environment-variable fallback through `MEETING_AGENT_OPENAI_API_KEY`.

## Validation

The main Settings validation should not require this key because recording, local STT, and the hosted text translation chain can run without Live Translation. Missing key errors should remain scoped to Live Translation start-up.

## Testing

Add focused tests for configuration persistence/decoding, Settings layout coverage, and the Live Translation start path using the configured key.
