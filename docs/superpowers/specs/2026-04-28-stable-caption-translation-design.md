# Stable Caption Translation Design

## Context

GitHub issue #35 reports that when one speaker keeps talking, already translated text disappears while a new translation is triggered, then reappears after the fuller translation completes. The current live caption store merges adjacent final transcript segments from the same speaker. During that merge it clears `translatedText` and marks translation as pending so the expanded source turn can be translated again.

## Goal

Keep the previously visible translation on screen while a same-speaker turn is being retranslated with newly appended source text. The expanded turn should still request a fresh full-turn translation, and the completed result should replace the preserved older translation.

## Non-Goals

- Do not add streaming OpenRouter translation.
- Do not debounce translation until speaker changes.
- Do not change provider APIs or transcript file formats.
- Do not redesign the caption UI.

## Selected Approach

Preserve non-empty `translatedText` in `LiveCaptionStore.mergedTurn` when a same-speaker final segment is appended. Set `translationHealth` back to `.pending` so the view model still schedules a full-turn translation for the changed source text. `LiveCaptionDisplayState` already prioritizes non-empty translated text, so keeping the existing value prevents the visible blank state while retranslation is in flight.

When `MeetingAgentViewModel.translateCaptionTurns` receives the new full-turn translation, it continues to call `attachTranslation`, replacing the preserved text and marking the turn live. The existing `captionTranslationKey` includes merged source segment IDs and original text, so expanded turns remain eligible for one new translation request per changed source turn.

## Affected Files

- `Sources/MeetingAgentCore/LiveMeetingCockpit.swift`
  - Update same-speaker merge behavior to preserve the last visible translation while marking translation pending.
- `Tests/MeetingAgentCoreTests/LiveCaptionStoreTests.swift`
  - Update the stale-translation merge regression to expect preserved pending text.
- `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`
  - Add a regression test proving an expanded same-speaker turn keeps the old translation during the new provider request and replaces it when the request completes.

## Test Plan

- Run `swift test --filter LiveCaptionStoreTests/testMergingSameSpeakerPreservesTranslationWhileRetranslating`.
- Run `swift test --filter MeetingAgentViewModelTests/testExpandingTranslatedCaptionKeepsVisibleTranslationUntilFullTurnTranslationCompletes`.
- Run `make test`.

