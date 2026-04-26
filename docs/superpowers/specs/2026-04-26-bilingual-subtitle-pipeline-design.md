# Bilingual Subtitle Pipeline Design

## Goal

Add an extensible speech-processing architecture that can produce bilingual subtitles from captured meeting audio:

```text
source speech -> source-language text -> target-language text -> bilingual subtitle
```

The architecture must also support alternative chains, including hosted or local models that can perform speech translation directly, or future models that can produce bilingual subtitle segments from audio in one step.

The first implementation should optimize for experimentation. Managers should be able to compare local and cloud providers, switch chains by configuration, and rely on fallback behavior when one provider is unavailable.

## Scope

In scope:

- Define provider-neutral models for bilingual transcript and subtitle segments.
- Add capability-based provider boundaries for transcription, text translation, speech translation, and direct bilingual subtitle generation.
- Add pipeline profiles that describe ordered provider chains and fallbacks.
- Preserve the existing local Whisper transcription path as one provider in the new architecture.
- Allow each step to be independently configured as local or hosted.
- Record provider provenance so output can be traced back to the chain that produced it.
- Add unit tests for profile resolution, fallback execution, and output normalization.

Out of scope for the first implementation:

- Choosing the final best model chain for all languages.
- Real-time low-latency streaming translation guarantees.
- Full UI redesign for subtitle display.
- Automatic model download or hosted provider account setup.
- Voice-to-voice response generation.

## Architecture

The current `SpeechTranscriptionProvider` boundary is too narrow for bilingual output because it assumes the main operation is transcription. The new architecture should introduce a higher-level pipeline layer above concrete providers:

```text
CapturedAudio
  -> BilingualSubtitlePipelineOrchestrator
      -> Profile A: AudioTranscriptionProvider -> TextTranslationProvider
      -> Profile B: SpeechTranslationProvider
      -> Profile C: BilingualSubtitleProvider
      -> fallbacks
  -> BilingualTranscript
  -> storage, UI, export
```

The pipeline layer owns orchestration, fallback, and output normalization. Concrete providers own model-specific execution only.

Provider capabilities:

- `AudioTranscriptionProvider`: converts audio into source-language transcript segments.
- `TextTranslationProvider`: converts source transcript segments into target-language translated segments.
- `SpeechTranslationProvider`: converts audio into target-language translated transcript segments, optionally also returning source text.
- `BilingualSubtitleProvider`: converts audio directly into bilingual subtitle segments.

`BilingualSubtitleProvider` is the highest-level capability. It can be implemented by a direct model, or by an adapter that composes lower-level providers.

## Provider Protocols

Suggested Swift boundaries:

```swift
public protocol AudioTranscriptionProvider {
    var descriptor: ProviderDescriptor { get }
    func transcribe(audio: AudioInput, options: TranscriptionOptions) async throws -> Transcript
}

public protocol TextTranslationProvider {
    var descriptor: ProviderDescriptor { get }
    func translate(transcript: Transcript, options: TranslationOptions) async throws -> TranslatedTranscript
}

public protocol SpeechTranslationProvider {
    var descriptor: ProviderDescriptor { get }
    func translateSpeech(audio: AudioInput, options: SpeechTranslationOptions) async throws -> TranslatedTranscript
}

public protocol BilingualSubtitleProvider {
    var descriptor: ProviderDescriptor { get }
    func generate(audio: AudioInput, options: BilingualSubtitleOptions) async throws -> BilingualTranscript
}
```

The existing Whisper provider can be adapted into `AudioTranscriptionProvider` first. The existing `SpeechTranscriptionProvider` can remain during migration, but new bilingual work should target the capability-based interfaces.

## Data Model

Audio input should describe the captured artifact without binding providers to the recorder implementation:

```swift
public struct AudioInput: Equatable {
    public var wavURL: URL?
    public var frames: [AudioFrame]
    public var localeIdentifier: String
}
```

Transcript output should remain segmented, not flattened to one string:

```swift
public struct Transcript {
    public var sourceLocale: String
    public var segments: [TranscriptSegment]
    public var provenance: PipelineProvenance
}

public struct TranscriptSegment: Identifiable, Equatable, Codable {
    public var id: UUID
    public var startTime: TimeInterval?
    public var endTime: TimeInterval?
    public var speakerID: String?
    public var text: String
    public var confidence: Double?
}
```

Bilingual output should preserve source text, target text, timing, speaker identity, and provenance:

```swift
public struct BilingualTranscript: Equatable, Codable {
    public var sourceLocale: String
    public var targetLocale: String
    public var segments: [BilingualSubtitleSegment]
    public var provenance: PipelineProvenance
}

public struct BilingualSubtitleSegment: Identifiable, Equatable, Codable {
    public var id: UUID
    public var startTime: TimeInterval?
    public var endTime: TimeInterval?
    public var speakerID: String?
    public var sourceText: String
    public var targetText: String
    public var confidence: Double?
    public var status: BilingualSubtitleSegmentStatus
    public var errorMessage: String?
    public var providerChain: [String]
}

public enum BilingualSubtitleSegmentStatus: String, Codable {
    case complete
    case sourceOnly
    case targetOnly
    case failed
}
```

When a provider cannot supply timing, speaker, or confidence, those fields remain `nil`. Output consumers must not infer missing metadata.

## Provider Registry

Providers should be registered through descriptors:

```swift
public struct ProviderDescriptor: Equatable, Codable {
    public var id: String
    public var displayName: String
    public var capability: ProviderCapability
    public var executionMode: ProviderExecutionMode
    public var supportedSourceLocales: [String]
    public var supportedTargetLocales: [String]
    public var requiresNetwork: Bool
    public var requiresAPIKey: Bool
}

public enum ProviderCapability: String, Codable {
    case audioTranscription
    case textTranslation
    case speechTranslation
    case bilingualSubtitle
}

public enum ProviderExecutionMode: String, Codable {
    case local
    case hosted
}
```

The registry lets the app and CLI list available providers, validate profiles, and hide unavailable chains when required configuration is missing.

## Pipeline Profiles

A pipeline profile describes how to produce bilingual subtitles. Profiles are configuration, not code:

```json
{
  "id": "local-whisper-hosted-translation",
  "displayName": "Local Whisper + Hosted Translation",
  "steps": [
    {
      "capability": "audioTranscription",
      "primary": "whisper-local",
      "fallbacks": ["openai-transcribe"]
    },
    {
      "capability": "textTranslation",
      "primary": "openai-translation",
      "fallbacks": ["qwen-local-translation", "nllb-local"]
    }
  ]
}
```

A direct provider profile is also valid:

```json
{
  "id": "direct-hosted-bilingual",
  "displayName": "Direct Hosted Bilingual Subtitles",
  "steps": [
    {
      "capability": "bilingualSubtitle",
      "primary": "hosted-audio-bilingual",
      "fallbacks": ["local-whisper-hosted-translation"]
    }
  ]
}
```

Fallbacks may reference either provider IDs or another profile ID. Profile-level fallback allows a failed direct model to fall back to a traditional transcription-plus-translation chain.

Resolution should be explicit in code even if JSON stays compact: the resolver first looks for a provider with the requested capability, then looks for a profile ID. If both exist with the same ID, profile validation should fail and require renaming. This keeps fallback behavior deterministic.

## Orchestration

`BilingualSubtitlePipelineOrchestrator` should:

1. Resolve the selected profile.
2. Validate required providers and configuration.
3. Execute each step in order.
4. Try provider fallbacks for the failed step before failing the whole profile.
5. Try profile fallbacks when a whole chain cannot produce bilingual output.
6. Normalize all successful outputs to `BilingualTranscript`.
7. Preserve partial results when possible.
8. Record provenance for diagnostics and chain comparison.

For the traditional chain, orchestration is:

```text
AudioInput
  -> AudioTranscriptionProvider
  -> Transcript
  -> TextTranslationProvider
  -> TranslatedTranscript
  -> BilingualTranscript
```

For speech translation:

```text
AudioInput
  -> SpeechTranslationProvider
  -> TranslatedTranscript
  -> BilingualTranscript
```

If speech translation produces only target text, the source text field should be empty and the segment should be marked with provenance that makes the limitation clear. Product UI may choose to hide unavailable source text or show an explicit unavailable state.

## Fallback Behavior

Fallback should be deterministic and visible in diagnostics.

Rules:

- If transcription fails, try the next transcription provider before running translation.
- If translation fails but transcription succeeded, keep source transcript output and mark target translation as failed.
- If a direct bilingual provider fails, fall back to the next direct provider or a full profile fallback.
- If a provider is not configured, treat it as unavailable and skip to fallback.
- If all providers fail, persist a clear failure reason without deleting captured audio.

Partial bilingual output is valid when some segments translate and others fail. Failed target segments should keep the original source text, include an empty target text, set `status` to `.sourceOnly` or `.failed`, and store the failure reason in `errorMessage`.

## Configuration

User-facing configuration should separate language intent from provider choice:

- Source language: meeting language or auto-detect where supported.
- Target language: user-selected subtitle language.
- Pipeline profile: selected chain and fallback policy.
- Provider settings: model paths, binary paths, API keys, hosted model IDs.

The app can start with a small set of built-in profiles:

- `local-whisper-hosted-translation`
- `local-whisper-local-translation`
- `hosted-transcribe-hosted-translation`

Direct audio-to-bilingual profiles should be represented in the profile system from the start, but can remain unavailable until a concrete provider is implemented.

## Output Format

The text subtitle file should remain human-readable. A simple bilingual text rendering can be:

```text
User A:
Source: 오늘 회의는 여기까지 하겠습니다.
Target: 今天的会议先到这里。
```

Structured output should also be stored for app display and future exports. JSON is the preferred internal interchange format because it preserves timing, speaker, and provenance.

Existing plain transcript files remain readable. New bilingual output should use a new artifact name, such as `bilingual-transcript.json` and `bilingual-transcript.txt`, to avoid breaking existing transcript consumers.

## Initial Provider Mapping

Initial providers can map onto existing and planned capabilities:

- `whisper-local`: local `whisper.cpp`, capability `audioTranscription`.
- `macos-speech-local`: macOS Speech framework, capability `audioTranscription`.
- `openai-transcribe`: hosted audio transcription, capability `audioTranscription`.
- `openai-translation`: hosted text translation and localization, capability `textTranslation`.
- `qwen-local-translation`: local LLM translation, capability `textTranslation`.
- `nllb-local`: local translation model, capability `textTranslation`.

Provider IDs should be stable because profiles and saved meeting records may reference them.

## Error Handling

Errors should distinguish:

- Provider unavailable: missing model file, missing binary, missing API key, no network.
- Provider failed: process exit, API error, invalid response, timeout.
- Unsupported route: provider does not support the requested source or target locale.
- Output incomplete: provider returned text without expected segment structure.

The recorder should continue saving WAV whenever audio capture succeeds. Bilingual subtitle failure should not invalidate audio or source transcript artifacts.

## Testing

Add focused XCTest coverage for:

- Provider registry lookup by capability and ID.
- Profile validation succeeds for known provider chains.
- Profile validation reports missing providers and unsupported locales.
- Orchestrator executes `audioTranscription -> textTranslation` in order.
- Orchestrator falls back from a failed primary transcription provider.
- Orchestrator falls back from a failed primary translation provider.
- Orchestrator falls back from a failed direct bilingual profile to a traditional chain.
- Translation failure preserves source transcript segments.
- Bilingual output keeps segment IDs, timing, speaker IDs, and provider chain provenance.

Tests must use fake providers. `swift test` should not require hosted credentials, real local models, or network access.

## Migration Plan

The first implementation should be incremental:

1. Add the shared data models, provider descriptors, and profile models.
2. Add fake-provider tests around orchestration and fallback.
3. Wrap the existing Whisper transcription provider behind `AudioTranscriptionProvider`.
4. Add one text translation provider.
5. Write bilingual JSON and text artifacts alongside the existing transcript.
6. Add app and CLI controls for selecting target language and pipeline profile.

This preserves the current recording and transcription behavior while creating a flexible path for model-chain experiments.
