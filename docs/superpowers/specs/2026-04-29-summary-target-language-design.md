# Summary Target Language Design

## Goal

Meeting summaries should default to the current settings target language. If the manager sets the app's main/target language to Chinese, English, Japanese, or another supported locale, generated summaries should be written in that language while still using the transcript language as source context.

## Requirements

- Summary generation must read the target language from `SpeechTranscriptionConfiguration.targetLocaleIdentifier`.
- The summary provider input must keep transcript/source language separate from output target language.
- OpenRouter summary prompts must explicitly ask for all returned JSON text fields to be written in the target language.
- Existing summary model selection must remain independent from translation model selection.
- Existing meeting progress context must still be available to summary providers instead of forcing a fixed English deterministic summary path.

## Selected Approach

Add a `targetLanguage` field to `MeetingSummaryInput`. `MeetingAgentViewModel.generateSummary(for:generatedAt:)` will pass `speechConfiguration.targetLocaleIdentifier` when it builds the summary input. `OpenRouterMeetingSummaryProvider` will include that target language in the user prompt and state that all generated JSON string content should use it.

This preserves the existing `language` field as the transcript/source language. If a matching meeting progress snapshot exists, the view model will pass its goal/status/follow-up context through `meetingGoal` so the configured provider can generate a localized summary with that context.

## Alternatives Considered

- Replace `language` with the target language. This is smaller but loses source-language context and makes the field ambiguous.
- Add target-language instructions only inside the OpenRouter provider without changing `MeetingSummaryInput`. This avoids a public input change but makes the view-model behavior harder to test and less reusable.

## Affected Files

- `Sources/MeetingAgentCore/MeetingSummary.swift`
- `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- `Sources/MeetingAgentCore/OpenRouterMeetingSummaryProvider.swift`
- `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`
- `Tests/MeetingAgentCoreTests/MeetingSummaryProviderTests.swift`

## Testing

- Add a view-model regression test proving the configured target locale is passed into `MeetingSummaryInput`.
- Add a view-model regression test proving meeting progress context is still passed into `MeetingSummaryInput`.
- Add an OpenRouter provider regression test proving the prompt includes the target output language instruction.
- Run the focused XCTest filters and `make test`.
