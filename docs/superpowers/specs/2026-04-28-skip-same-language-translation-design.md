# Skip Same-Language Translation Design

## Issue

GitHub issue #43 requests that translation is not called when the original language and target language are the same. The goal is to avoid wasting hosted or local translation capacity when the transcript can be shown directly.

## Success Criteria

- Live caption text translation does not call a translation provider when the source and target languages match.
- The historical bilingual subtitle pipeline does not call a text translation provider when the source and target languages match after transcription.
- Same-language matching is based on language identity, not exact region identity, so `en-US` and `en-GB` are treated as same language.
- Existing cross-language translation behavior is unchanged.
- Regression tests prove provider calls are skipped.

## Requirements

- Normalize locale identifiers by trimming whitespace, lowercasing, replacing `_` with `-`, and comparing the first language subtag.
- Empty or malformed locale values must not be treated as same-language.
- For same-language live captions, final captions should leave `translatedText` empty and mark `translationHealth` as `.live`, letting existing display logic render original-only instead of pending.
- For same-language bilingual pipeline output, produce `BilingualSubtitleSegment` values with `sourceText` copied from the transcript, empty `targetText`, `.sourceOnly` status, and the current provenance without adding translation providers.

## Non-Requirements

- Do not change settings UI or provider configuration.
- Do not skip direct bilingual providers before transcription, because those providers may be doing their own bilingual generation.
- Do not add language-family special cases beyond the primary language subtag comparison.

## Approach Options

### Option A: Shared Locale Predicate

Add a small public helper in `BilingualProvider.swift`, then call it from live captions and the orchestrator. This centralizes the language comparison and keeps provider-specific code unchanged.

Trade-off: one new core API, but it avoids duplicated normalization logic.

### Option B: Inline Checks Per Caller

Add local `source == target` checks in the view model, live caption adapter, and orchestrator.

Trade-off: smallest surface area per file, but it risks drift between live and export paths and would likely miss regional variants.

### Option C: Wrap Translation Providers

Introduce a provider decorator that skips calls when `TranslationOptions` are same-language.

Trade-off: elegant at the provider boundary, but the current code constructs providers in multiple places and the orchestrator still needs to produce source-only output intentionally.

## Selected Design

Use Option A. Add `TranslationOptions.isSameLanguage` backed by a `LocaleLanguageMatcher` helper. The orchestrator uses this before entering the provider loop for text translation. Live caption scheduling filters out same-language work, marks those turns complete, and never constructs a hosted provider for skipped turns. `LiveCaptionTranslationAdapter` also uses the same check so its direct API obeys the same contract.

## Affected Files

- `Sources/MeetingAgentCore/BilingualProvider.swift`
- `Sources/MeetingAgentCore/BilingualSubtitlePipelineOrchestrator.swift`
- `Sources/MeetingAgentCore/LiveMeetingCockpit.swift`
- `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- `Tests/MeetingAgentCoreTests/BilingualProviderRegistryTests.swift`
- `Tests/MeetingAgentCoreTests/BilingualSubtitlePipelineOrchestratorTests.swift`
- `Tests/MeetingAgentCoreTests/LiveCaptionTranslationAdapterTests.swift`
- `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

## Test Plan

- Add unit tests for locale language matching, including case, whitespace, underscore, regional variants, and empty values.
- Add orchestrator coverage proving text translation providers are not called when `sourceLocale` and `targetLocale` share the same language.
- Add live caption adapter coverage proving same-language final turns are marked live without provider calls.
- Add view-model coverage proving same-language live caption scheduling does not instantiate the caption translation provider.
- Run `make test`.
