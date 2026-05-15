# Remove Historical Translation Assets Design

## Context

The active realtime caption path is now caption-only. New recordings should capture audio, transcribe speech, reconcile realtime transcript events, project captions, summarize meetings, and export source-language artifacts without compiling translation providers or bilingual pipelines into the product target.

The repository still contains older translation and bilingual architecture: pipeline profiles, bilingual transcript stores, text translation providers, translation schedulers, translation result stores, translation unit builders, and script/test fixtures for `translation-results.jsonl` and `caption_translation_*` / `translation_unit_*` events.

## Decision

Remove translation and bilingual architecture from the active core product target. Keep compatibility only at explicit data boundaries where old meeting artifacts may still contain translation-shaped fields. Tooling may tolerate old fixture files, but it must not require or analyze translation behavior as part of the current product path.

## Requirements

- Remove active `Bilingual*` pipeline, store, orchestrator, provider, and profile types from `Sources/MeetingAgentCore`.
- Remove `TextTranslationProvider`, `AccurateTranslationScheduler`, `TranslationUnitBuilder`, `TranslationResultStore`, `TranslationContextStore`, `TranslationExperienceModels`, and OpenRouter translation provider code from active sources.
- Remove configuration fields and tests that still expose bilingual pipeline profile or hosted translation provider selection.
- Keep app settings focused on STT provider, meeting language, Deepgram/OpenAI transcription configuration, and summary provider/model settings.
- Make regression fixture capture and performance analysis scripts caption-only by default. They may ignore historical translation files but must not require `translation-results.jsonl` for new fixtures.
- Delete tests whose only purpose is removed translation or bilingual behavior.
- Preserve existing transcript/caption, summary, export, meeting knowledge, and caption-only active recording behavior.
- Document a final grep over the forbidden symbols named in #151.

## Non-Requirements

- Do not delete historical design documents or plans. They are archived product history.
- Do not remove OpenRouter summary support or the shared `OpenRouterChatClient`.
- Do not remove legacy transcript decoding compatibility unless the active schema no longer references those fields.
- Do not add replacement translation abstractions under a new name.

## Approach

Use direct removal rather than moving translation code into a new legacy module. This keeps the active Swift package honest: if product code references translation architecture, the compiler will fail. Scripts will be simplified to caption/transcript analysis only, with fixture capture producing expected UI from transcript and captions instead of translation result lookup.

Configuration cleanup happens before deleting source files so the remaining app code has a clear caption-only surface. Tests then shift from translation behavior tests to removal guards and existing caption-only behavior.

## Verification

- Run targeted Swift tests while iterating on configuration, fixture, and script changes.
- Run `swift build --product MeetingAgentApp`.
- Run `make test` from the worktree root.
- Run a final `rg` over active source, tests, and scripts for:
  `TranslationRuntime`, `TranslationExperiencePipeline`, `LiveTranslationScheduler`, `ReplayTranslationBackfill`, `BilingualPipeline`, `BilingualTranscript`, `TextTranslationProvider`, `AccurateTranslationScheduler`, `TranslationUnitBuilder`, `translation-results.jsonl`, `caption_translation_`, and `translation_unit_`.
