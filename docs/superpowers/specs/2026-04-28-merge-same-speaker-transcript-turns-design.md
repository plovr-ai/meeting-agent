# Merge Same-Speaker Transcript Turns Design

## Context

GitHub issue #28 reports that the updated transcript module now displays every model-recognized segment as its own block with speaker, original text, and translation. This splits a single user's sentence across multiple visible modules. Earlier UI behavior merged adjacent dialogue from the same user, and the issue asks to restore that behavior.

## Goal

Consecutive live caption segments from the same speaker should display as one transcript turn. Different speakers should remain separated. Existing duplicate segment updates, translation state, editing, auto-scroll, and analysis behavior should stay coherent.

## Non-Goals

- Do not merge non-adjacent turns from the same speaker.
- Do not change transcript file persistence or export formatting in this issue.
- Do not add language-specific sentence segmentation.
- Do not redesign the transcript row UI.

## Selected Approach

Merge at the `LiveCaptionStore` boundary. `UnifiedTranscriptView` already consumes `liveCaptionTurns`, and downstream live meeting analysis also reads `LiveCaptionTurn` values. Keeping the merge in store state makes the transcript UI, edit actions, translation status, auto-scroll, and progress analysis use the same turn model.

The store should continue to update an existing turn when a segment with the same `sourceSegmentID` arrives. That duplicate-segment update path must run before same-speaker merging so revised provider output does not create duplicate text.

When a new final segment has the same speaker as the latest final turn, append the new segment text to that turn instead of adding a new turn. The merged turn should keep the first turn's stable `id`, update `sourceSegmentID` to the latest segment for "last analyzed" tracking, preserve the original speaker, source locale, target locale, final state, and newest creation timestamp. Because the source text changed, stale translation must be cleared and translation health should return to `.pending`.

Different speakers, partial segments, and empty text should continue to create or update separate turns according to existing behavior.

## Affected Files

- `Sources/MeetingAgentCore/LiveMeetingCockpit.swift`
  - Update `LiveCaptionStore.append(_:)`.
  - Add small private helpers if needed for turn merging and text joining.
- `Tests/MeetingAgentCoreTests/LiveCaptionStoreTests.swift`
  - Add regression tests for same-speaker merging, different-speaker separation, duplicate updates, and stale translation clearing.

## Test Plan

- Add a failing unit test proving consecutive final segments from the same speaker become a single turn with combined text.
- Add a unit test proving consecutive final segments from different speakers remain separate turns.
- Preserve existing duplicate segment update behavior.
- Verify merged source text clears old translated text and sets translation health to `.pending`.
- Run `swift test --filter LiveCaptionStoreTests`.
- Run `make test` for full repository verification.

## Risks

Merging changes the meaning of `sourceSegmentID` for a displayed turn. The chosen behavior is to keep `id` stable for UI identity and update `sourceSegmentID` to the latest merged segment so progress analysis can advance past merged content. Editing a merged turn currently uses `turn.id`, which remains the first source segment ID; editing all merged source segments is outside this issue's scope.
