# OpenRouter Bilingual Providers Design

## Goal

Implement the hosted transcription and hosted translation providers for the bilingual subtitle pipeline using the existing OpenRouter integration style. Each pipeline step must be independently configurable. A hosted transcription step and a hosted translation step may both use OpenRouter, but they must be able to use different OpenRouter models.

The settings UI should expose this as cascading picker controls, not free-form text input. Local choices should expose local model settings, and hosted choices should expose hosted provider and hosted model settings.

## Existing Context

The project already has these relevant boundaries:

- `AudioTranscriptionProvider` produces a `TranscriptDocument` from captured audio.
- `TextTranslationProvider` translates a `TranscriptDocument` into a `TranslatedTranscript`.
- `BilingualSubtitlePipelineOrchestrator` executes profile steps and fallbacks.
- `WhisperAudioTranscriptionProvider` adapts the local Whisper transcription path into `AudioTranscriptionProvider`.
- `OpenRouterMeetingSummaryProvider` already calls OpenRouter chat completions using `URLSession`.
- `SpeechTranscriptionConfiguration` is the persisted settings model used by the app and recorder.
- `SettingsView` already uses SwiftUI `Picker` controls and avoids manual text input.

There is no package-level OpenRouter SDK dependency today. The reusable implementation should therefore be a shared internal OpenRouter client built from the existing `URLSession` chat-completions code, unless a real SDK dependency is added later.

## Provider Architecture

Introduce a shared OpenRouter chat layer in `MeetingAgentCore`:

- `OpenRouterChatClient`
- `URLSessionOpenRouterChatClient`
- `OpenRouterChatConfiguration`
- shared request and response DTOs

`OpenRouterMeetingSummaryProvider` should be migrated to this shared client instead of owning duplicate HTTP request code. New providers should use the same client.

Add two concrete providers:

- `OpenRouterAudioTranscriptionProvider`
  - descriptor id: `openrouter-transcribe`
  - capability: `.audioTranscription`
  - execution mode: `.hosted`
  - model comes from `SpeechTranscriptionConfiguration.hostedTranscriptionModelID`
  - output is `TranscriptDocument`

- `OpenRouterTextTranslationProvider`
  - descriptor id: `openrouter-translation`
  - capability: `.textTranslation`
  - execution mode: `.hosted`
  - model comes from `SpeechTranscriptionConfiguration.hostedTranslationModelID`
  - output is `TranslatedTranscript`

The two providers may both use OpenRouter, but they should not share a single model field.

## OpenRouter Transcription Behavior

The transcription provider should accept `AudioInput` and produce a segmented `TranscriptDocument`.

For the first implementation, the provider boundary should support audio input through `AudioInput.wavURL`. If no `wavURL` is present, the provider should throw a clear unavailable error. The request-building code should be isolated behind the OpenRouter client so tests can assert model selection and prompt content without requiring network access.

The provider should request JSON output with this shape:

```json
{
  "segments": [
    {
      "id": "segment-1",
      "startTimeSeconds": 0.0,
      "endTimeSeconds": 1.5,
      "speakerID": null,
      "speakerLabel": null,
      "text": "hello",
      "language": "en-US",
      "confidence": null
    }
  ]
}
```

When timing, speaker, or confidence is unavailable, those fields should remain absent or null. The provider should normalize missing IDs to generated IDs and set `sourceProvider` to `openrouter-transcribe`.

If the current OpenRouter chat-completions API cannot support the selected audio model or audio payload shape, the provider should fail with a precise error. Fallback behavior remains the orchestrator's responsibility.

## OpenRouter Translation Behavior

The translation provider should take a `TranscriptDocument`, source locale, and target locale. It should preserve source segment IDs, timing, speaker fields, and confidence where possible.

The provider should request JSON output with this shape:

```json
{
  "segments": [
    {
      "id": "segment-1",
      "targetText": "你好"
    }
  ]
}
```

The provider maps each source segment to a `BilingualSubtitleSegment`:

- `sourceText` comes from the original transcript segment.
- `targetText` comes from the OpenRouter response.
- timing, speaker, confidence, and IDs are copied from the source segment.
- `providerChain` includes `openrouter-translation`.
- missing translations produce `.sourceOnly` segments with an error message.

## Configuration Model

Extend `SpeechTranscriptionConfiguration` with step-level hosted and local model settings:

- `transcriptionExecutionMode`
- `translationExecutionMode`
- `localTranscriptionProviderID`
- `localTranslationProviderID`
- `hostedTranscriptionProviderID`
- `hostedTranslationProviderID`
- `hostedTranscriptionModelID`
- `hostedTranslationModelID`

Keep existing fields for compatibility:

- `provider`
- `localeIdentifier`
- `targetLocaleIdentifier`
- `bilingualPipelineProfileID`
- `whisperBinaryPath`
- `whisperModelPath`

Existing saved configurations should decode successfully with defaults:

- transcription: local Whisper
- translation: hosted OpenRouter
- hosted transcription model: built-in default
- hosted translation model: built-in default

Validation should remain conservative:

- Local Whisper validates binary and model paths.
- Hosted OpenRouter validates that an API key is configured.
- Hosted model fields are required when the corresponding hosted step is selected.

## Built-In Provider and Model Options

Replace the placeholder OpenAI provider IDs with OpenRouter-specific provider IDs:

- `openrouter-transcribe`
- `openrouter-translation`

Keep local provider IDs:

- `whisper-local`
- `macos-speech-local`
- local translation placeholders can remain until implemented.

Add built-in model option descriptors for settings pickers. Initial options can be static:

- hosted transcription models: OpenRouter-capable audio/transcription model candidates
- hosted translation models: OpenRouter chat model candidates
- Whisper models: existing path candidates from configuration and environment

The static list is intentionally a first step. A later implementation can populate it from the OpenRouter models API without changing the settings layout or provider boundary.

## Settings UI

The settings page should remain picker-only for editable fields.

Layout:

- Speech section
  - source locale
  - target locale

- Transcription Chain section
  - execution mode: Local / Hosted
  - if Local: local provider picker
  - if Local + Whisper: Whisper binary path picker and Whisper model path picker
  - if Hosted: hosted provider picker and hosted transcription model picker

- Translation Chain section
  - execution mode: Local / Hosted
  - if Local: local translation provider picker
  - if Hosted: hosted provider picker and hosted translation model picker

- Pipeline section
  - profile picker remains available for fallback experiments, but should be derived or reconciled with the step-level selections.

Changing an upstream picker should update dependent defaults when the current downstream option is invalid. For example, choosing hosted transcription should default the hosted provider to OpenRouter and select the first hosted transcription model if no hosted transcription model is saved.

## Orchestration and Fallback

`BilingualPipelineFactory` should expose OpenRouter provider descriptors and built-in profiles that reference OpenRouter IDs.

Provider construction should be configuration-driven:

- local transcription provider is built from the configured local provider and local model settings.
- hosted transcription provider is built from the configured OpenRouter model.
- hosted translation provider is built from the configured OpenRouter model.

Fallbacks continue to live in pipeline profiles. The initial hosted-hosted profile should use:

```text
openrouter-transcribe -> openrouter-translation
```

with local Whisper as a transcription fallback where appropriate.

## Testing

Add or update unit tests for:

- `SpeechTranscriptionConfiguration` round-trips all new fields and decodes older saved data.
- hosted validation requires OpenRouter API key and selected hosted model.
- `OpenRouterTextTranslationProvider` sends the configured translation model and maps JSON output to bilingual segments.
- `OpenRouterAudioTranscriptionProvider` sends the configured transcription model and maps JSON output to transcript segments.
- `OpenRouterMeetingSummaryProvider` still works through the shared OpenRouter chat client.
- `BilingualPipelineFactory` descriptors use `openrouter-transcribe` and `openrouter-translation`.
- `SettingsView` uses picker-only cascading controls and contains no `TextField`.

Network calls must be tested with fake clients. No test should require a real OpenRouter API key.

## Out Of Scope

- Dynamic OpenRouter model discovery.
- Automatic local Whisper model download.
- Fully validating which OpenRouter model supports audio input.
- Real-time streaming transcription from hosted models.
- Implementing local translation models.
