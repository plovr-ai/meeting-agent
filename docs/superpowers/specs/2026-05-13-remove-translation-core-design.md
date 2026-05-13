# Remove Translation Core Design

## Context

The product direction no longer includes translation as a core feature. The macOS app should focus on recording, transcription, live captions in the meeting language, meeting progress analysis, summaries, and exports.

Existing translation work is deeply wired through settings, provider descriptors, live caption overlays, persisted `translation-results.jsonl`, replay backfill, realtime unit translation, and tests. Removing it should simplify the active product path without breaking old transcript files that already contain translation fields.

## Decision

Use option B: remove translation from the product/runtime surface while preserving historical transcript JSON compatibility.

## Scope

Remove active translation capability from:

- Settings and app configuration.
- Provider registry and OpenRouter translation provider wiring.
- Live caption runtime scheduling, replay backfill, unit translation runtime, and translation result persistence.
- UI display paths that render translated caption text.
- Tests whose only purpose is translation behavior.
- Documentation and app text that describes the current product as bilingual/translation-first.

Preserve:

- Decoding of historical `TranscriptSegment.translatedText`, `translationTargetLocale`, and `translationIsFinal` fields.
- Summary generation and OpenRouter chat client usage for summaries.
- Transcription model settings and meeting language settings.
- Existing live caption chunking, source caption persistence, meeting progress, summary, and export behavior.

## Architecture

`LiveCaptionPipeline` becomes a caption-only projection pipeline. It still builds visible turns from `TranscriptDocument` and realtime accumulation results, but snapshots report translation health as idle and no longer schedule provider calls or attach translation overlays.

`SpeechTranscriptionConfiguration` becomes transcription and summary focused. Legacy translation fields may remain decodable only if needed for compatibility, but they must not drive validation, settings UI, or provider selection.

Historical transcript compatibility stays at the schema edge: `TranscriptSegment` can decode old translation fields, but new runtime code does not hydrate, persist, or render them.

## Testing

Update tests to assert:

- Settings no longer contain hosted translation model controls.
- Default configuration does not require translation model validation.
- Live caption projection does not call translation providers and exposes no translated text.
- Historical transcript JSON with translation fields still decodes.
- Build and `make test` pass through the required project entrypoint.
