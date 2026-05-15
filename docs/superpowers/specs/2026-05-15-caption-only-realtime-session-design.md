# Caption-Only Realtime Session Design

## Context

Active realtime captioning is now caption-only. `MeetingAgentViewModel` constructs realtime caption pipelines without a translation provider, and `AGENTS.md` explicitly forbids active recording from calling realtime translation providers, `TranslationRuntime`, `TranslationExperiencePipeline`, `LiveTranslationScheduler`, replay backfill schedulers, or publishing `caption_translation_*` / `translation_*` overlay events.

Issue #143 asks for the active realtime caption session boundary to expose only caption operations. The user clarified that the product no longer has translation functionality and legacy translation code should be cleaned out rather than preserved behind a helper.

## Success Criteria

- `RealtimeCaptionSession` exposes only caption lifecycle operations: replace the caption pipeline, apply transcript accumulation results, and flush captions.
- `MeetingAgentViewModel` cannot schedule, attach, or backfill translations through the realtime caption session.
- `LiveCaptionPipeline` no longer owns translation scheduling, translation result attachment, replay backfill scheduling, or translation modes.
- Active caption projection continues to render captions, preserve speaker turns, handle interim replacement, and flush final captions.
- Tests assert the active API does not expose translation scheduling or call forbidden active-recording translation components.
- Obsolete isolated legacy translation tests are removed when they only validate deleted product behavior.

## Non-Goals

- Do not remove transcript translation fields from persisted models in this change; old files may still decode them for compatibility.
- Do not change summary generation, export, knowledge package, or transcript rendering behavior unless needed to compile after deleting caption translation code.
- Do not delete historical fixture files solely because they contain translation events; analysis tests may still use historical data.

## Selected Approach

Delete the realtime caption translation path from the active caption boundary and pipeline. Keep caption projection in `LiveCaptionPipeline`, but remove `LiveCaptionTranslationMode`, `scheduleLegacyReplayBackfillTranslations`, `scheduleLivePendingTranslations`, `attachTranslationResults`, `ReplayTranslationBackfillScheduler` ownership, and translation-specific visibility logging from that pipeline. If translation-only source files become unreferenced after this cleanup, delete them with their tests instead of keeping dead public API.

This approach matches the current product direction and reduces the chance that old realtime translation behavior is reintroduced through a still-available API.

## Affected Areas

- `Sources/MeetingAgentCore/RealtimeCaptionSession.swift`
- `Sources/MeetingAgentCore/LiveCaptionPipeline.swift`
- Translation-only core files if they become unreferenced
- `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- `Tests/MeetingAgentCoreTests/LiveCaptionPipelineTests.swift`
- Translation scheduler/runtime/backfill tests that cover deleted behavior
- Source-layout or boundary tests that enforce the active caption-only contract

## Test Strategy

- Add source-level boundary tests that fail if `RealtimeCaptionSession` exposes translation scheduling APIs or if `MeetingAgentViewModel` calls forbidden translation components from active recording.
- Keep focused `LiveCaptionPipeline` tests for caption-only behavior, including legacy translated segment fields not being projected into live captions.
- Remove tests that only exercise deleted legacy caption translation scheduling APIs.
- Run focused XCTest filters first, then run `make test` with a unique coverage scratch path if needed.
