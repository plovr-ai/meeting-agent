# Reliable MVP Primary Chain Design

## Context

The product should move from a prototype with many experimental provider choices to a reliable meeting asset pipeline. The MVP should prioritize one dependable workflow that records meeting audio, produces a trustworthy transcript, translates the transcript, generates a structured summary, and exports meeting artifacts.

Live translation remains valuable, but it should not be the source of truth for meeting records. It is an in-meeting enhancement that can fail independently without losing the meeting asset.

## Goals

- Make the primary meeting workflow stable enough for real customer meetings.
- Keep STT provider choice pluggable while preserving one downstream transcript format.
- Use Deepgram Nova-3 as the recommended STT provider.
- Add OpenAI Realtime transcription as a lower-latency STT provider option.
- Keep Local Whisper as an offline fallback and retry path.
- Use GPT text models for translation, summary, and manager-facing analysis.
- Preserve the full local WAV recording for every meeting so failed provider work can be retried.

## Non-Goals

- Do not make OpenAI Realtime speech-to-speech the only product pipeline.
- Do not keep OpenRouter audio transcription as a supported primary STT path unless it is replaced with a real audio-upload implementation.
- Do not optimize for many provider choices in the MVP UI.
- Do not implement account billing, team sharing, or cloud sync in this MVP phase.

## Product Architecture

The primary chain is:

```text
Audio Capture + WAV Recording
-> STT Provider
-> Canonical TranscriptDocument
-> GPT Text Translation
-> GPT Summary / Analysis
-> Export / Meeting Record
```

The STT provider is the only major variable in the primary chain:

```text
1. Deepgram Nova-3                 Recommended default
2. OpenAI Realtime Transcription   Low-latency / OpenAI-only option
3. Local Whisper                   Offline fallback and retry option
```

Translation, summary, export, and meeting storage must consume the same canonical transcript representation regardless of which STT provider produced it.

## Model Choices

### STT

Default: Deepgram `nova-3`.

Use it for formal meeting assets because it is designed for meetings, event captioning, multi-speaker audio, multilingual or noisy audio, and batch or streaming inference. For normal single-language meetings, use the selected locale. For code-switching or multilingual meetings, use `language=multi`.

Second option: OpenAI Realtime transcription.

Use it when users want lower latency, want a single OpenAI-provider setup, or cannot use Deepgram. Default model should be `gpt-4o-transcribe`; cost-sensitive mode can use `gpt-4o-mini-transcribe`.

Fallback: Local Whisper.

Use it for offline operation, privacy-first local retry, or hosted-provider outage recovery. It is not the recommended default for polished product UX.

### Text Translation

Default: OpenAI mini-class GPT model for low-latency, high-volume segment translation.

Use the strongest configured GPT model for user-facing localization polish, culturally appropriate manager replies, or final high-quality translation regeneration.

### Summary And Analysis

Default: `gpt-5.5` through the Responses API.

Use Structured Outputs for decisions, action items, risks, open questions, follow-ups, source segment references, and manager suggestions. Start with `reasoning.effort=medium`; evaluate `low` for routine summaries after quality tests exist.

### Live Translation

Default: OpenAI `gpt-realtime`, voice `marin` or `cedar`.

This chain emits target-language text and speech for in-meeting assistance. It does not replace the primary chain's transcript, translation, or summary artifacts.

## Provider Contract

All STT providers must produce `TranscriptDocument` through the same contract. Each segment should preserve:

- `sourceProvider`
- `speaker`
- `startTimeSeconds`
- `endTimeSeconds`
- `text`
- `language`
- `confidence`
- `isFinal`
- `timingSource`

Provider-specific limitations must be represented honestly. If OpenAI Realtime transcription does not provide reliable speaker labels or timestamps, those fields should be `.default`, `nil`, or `.unavailable`; the app should not synthesize fake precision.

## Main Workflow

1. Preflight checks run before recording starts:
   - macOS audio capture permission and runtime support
   - selected STT provider key and configuration
   - OpenAI key for translation and summary
   - network reachability for hosted providers
   - writable meeting storage directory

2. Recording starts:
   - create meeting directory and metadata
   - start system audio capture
   - always write a local WAV file
   - start selected STT provider
   - persist transcript segments incrementally
   - record capture diagnostics and provider status

3. Recording stops:
   - close WAV writer
   - finish STT provider
   - preserve partial transcript if provider failed
   - mark meeting status with explicit failure or success state

4. Post-processing runs:
   - translate canonical transcript into the target language
   - generate structured summary and analysis
   - write JSON and Markdown artifacts
   - make export actions available

5. Retry flow:
   - use existing WAV as the source of truth
   - retry STT with the same or another provider
   - invalidate downstream translation and summary if transcript changes
   - allow translation and summary retry without rerunning STT

## Live Translation Workflow

Live translation is a separate opt-in enhancement:

```text
Audio Capture
-> OpenAI gpt-realtime
-> Target-language text
-> Target-language voice
```

It should show explicit states:

- idle
- connecting
- connected
- degraded
- failed

Realtime failure must not stop audio recording or primary STT. The UI should make clear that live translation is for in-meeting assistance, while the final transcript and summary come from the primary chain.

The implementation must account for Realtime session duration limits. If live translation approaches the session limit, the app should either reconnect cleanly or warn the user before the session expires.

## Settings UX

The MVP settings should expose product-level choices, not provider internals:

- Source language
- Target language
- STT mode:
  - Recommended: Deepgram Nova-3
  - Low-latency OpenAI: Realtime Transcription
  - Offline: Local Whisper
- API keys managed through Keychain-backed fields
- Summary quality:
  - Standard
  - High quality
- Live translation:
  - enabled/disabled
  - target language
  - voice

Hardcoded local paths and experimental provider names should not appear in the default product flow.

## Data And Privacy

API keys must move from `UserDefaults` to Keychain. Existing keys in `UserDefaults` should be migrated once and removed after successful migration.

Meeting artifacts remain local by default:

- audio WAV
- structured transcript JSON
- plain transcript text
- translated transcript JSON/text
- summary JSON/Markdown
- diagnostics JSON

The app should provide meeting deletion and should clearly communicate which providers receive audio or text.

## Error Handling

Failures should be isolated by stage:

- capture failure
- WAV write failure
- STT provider failure
- translation failure
- summary failure
- export failure
- live translation failure

Each failure should have a user-readable status and a diagnostic detail. STT, translation, and summary should be retryable independently when their inputs are available.

## Testing And Verification

Unit coverage remains required through `make test`.

Additional MVP verification should include:

- fake Deepgram streaming server contract tests
- fake OpenAI Realtime transcription server contract tests
- fake OpenAI Responses API contract tests for translation and summary
- 30, 60, and 90 minute simulated recording tests
- provider interruption tests for network drop, bad key, rate limit, and malformed events
- transcript mutation tests that invalidate downstream translation and summary
- app build verification
- release package smoke test after signing and notarization are introduced

## Acceptance Criteria

The reliable MVP is ready when:

- Deepgram Nova-3 can produce usable transcript segments during a real meeting.
- OpenAI Realtime transcription can be selected as STT provider and produces the same canonical transcript shape.
- Local WAV is always saved even if STT fails.
- Translation and summary run from the canonical transcript, independent of STT provider.
- Failed STT, translation, and summary steps can be retried.
- API keys are stored in Keychain.
- Meeting artifacts can be exported as transcript, translated transcript, summary, and readiness diagnostics.
- Long-running meeting tests pass for at least 90 minutes without losing audio.
- Live translation can fail without corrupting or stopping the primary meeting record.

## Rollout Plan

Phase 1: Primary chain hardening.

- Deepgram Nova-3 as default STT.
- OpenAI Realtime transcription as optional STT.
- Local Whisper as fallback.
- Keychain credentials.
- WAV-first retryable artifacts.

Phase 2: Meeting asset quality.

- terminology/keyterms
- speaker label editing
- transcript correction
- translation and summary regeneration
- SRT/VTT/Markdown/JSON exports

Phase 3: Live translation enhancement.

- `gpt-realtime` target-language text and voice
- voice selection
- latency/status display
- session rollover handling

Phase 4: Product release stability.

- signed and notarized app
- permission onboarding
- crash and diagnostic reporting
- long-meeting soak tests
- release CI
