# OpenRouter Realtime Translation Design

## Context

GitHub issue #33 asks for a reliable OpenRouter model and trigger timing for real-time translation after hosted STT, especially Deepgram diarized transcript output. The app already has hosted STT settings, an OpenRouter text translation provider, live caption turns, and bilingual transcript rendering, but final caption text is not automatically routed through OpenRouter translation after structured STT updates.

## Decision

Use `google/gemini-2.5-flash` as the default OpenRouter hosted translation model. Keep `openai/gpt-4.1-mini` available as a selectable fallback option. Gemini 2.5 Flash has a large context window and strong general instruction-following while keeping input cost low, which fits short meeting-turn translation requests where output size is controlled.

Trigger translation only after a transcript segment is final. Partial STT text should show as source-only or pending text and should not call OpenRouter. This avoids translating unstable words, reduces request churn, and prevents visible translation rewrites while Deepgram is still revising diarized output.

## Requirements

- Hosted translation defaults to `google/gemini-2.5-flash`.
- Settings expose a hosted translation model picker when OpenRouter hosted translation is active.
- Final live caption turns are eligible for OpenRouter text translation.
- Partial live caption turns are not translated.
- A turn is translated once for a given source text; if the source text changes because final same-speaker segments merge, translation becomes pending again and can be translated again.
- OpenRouter prompts must preserve segment IDs and speaker intent and ask for natural localized meeting language rather than literal word-by-word output.
- Translation failures should mark only translation health, leaving caption health intact.

## Non-Requirements

- Do not add streaming OpenRouter translation.
- Do not replace the existing OpenAI realtime speech translation path.
- Do not add local translation provider implementation.
- Do not add new meeting data file formats.

## Architecture

`SpeechTranscriptionConfiguration` keeps the hosted translation model setting and changes its default to Gemini 2.5 Flash. `BilingualPipelineFactory.hostedTranslationModelOptions` lists Gemini first and GPT-4.1 Mini second.

`SettingsView` adds a hosted translation model picker in the OpenRouter panel. The picker writes `hostedTranslationModelID` and validates it against the factory option list.

`LiveCaptionTranslationAdapter` becomes the boundary for final-turn translation timing. It returns without calling the provider when `turn.isFinal == false`, and it sends a single-segment `TranscriptDocument` for final turns.

`MeetingAgentViewModel` owns when to call the adapter. After refreshing live captions from the structured transcript, it schedules translation for final pending turns only when hosted translation is OpenRouter and an API key/model are configured. The view model tracks translated source text by turn ID so repeated drain cycles do not retranslate unchanged turns. If same-speaker merging clears translated text and changes source text, the pending final turn becomes eligible again.

## Testing

- Unit test the new default hosted translation model.
- Unit test settings source includes the hosted translation model picker.
- Unit test OpenRouter translation prompt uses the configured model and includes natural localized meeting-language instructions.
- Unit test `LiveCaptionTranslationAdapter` skips partial turns without calling the provider.
- Unit test `MeetingAgentViewModel` translates final structured live captions once and uses the configured OpenRouter translation model.
- Run `make test`.
