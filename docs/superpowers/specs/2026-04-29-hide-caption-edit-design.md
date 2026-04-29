# Hide Caption Edit Design

Issue #80 asks to hide the subtitle edit feature in the UI. The clarified scope is narrow: remove only the per-caption pencil edit affordance for correcting caption text, while preserving speaker-name editing.

## Goal

Managers should no longer see a caption-level pencil button or caption correction sheet from the live transcript. Speaker-name editing remains available through the existing speaker label menu.

## Non-Goals

- Do not remove speaker-name editing.
- Do not remove transcript text selection, translation display, fallback transcript rendering, or export behavior.
- Do not change lower-level transcript correction APIs unless they are no longer referenced by the UI change.
- Do not add a setting or feature flag for caption editing.

## Selected Approach

Remove the caption edit closure from the unified transcript view hierarchy and stop rendering the pencil button in `BilingualTranscriptBlock`. This hides the feature at the UI surface and avoids dead sheet state in `TranscriptPaneView`.

Alternatives considered:

- Hide the pencil with styling or conditional visibility. This leaves correction wiring in place and is easier to regress accidentally.
- Add a user setting for edit visibility. This is unnecessary for the issue and expands product surface area.

## Affected Files

- `Sources/MeetingAgentApp/MainWindowView.swift`
  - Remove caption edit state and sheet wiring from the transcript pane.
  - Remove the optional `editText` path from `UnifiedTranscriptView`, `BilingualTranscriptGroup`, and `BilingualTranscriptBlock`.
  - Keep speaker edit menu and `CaptionEditSheet` for speaker labels.
- `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`
  - Update layout assertions so caption correction UI is absent.
  - Keep assertions that speaker editing remains available.

## Test Plan

- Add or update a layout regression test that asserts `Correct Caption`, `Save Caption`, and the caption pencil button are absent.
- Preserve assertions for `Button("Edit name")`, `Image(systemName: "chevron.down")`, `Save Speaker`, and `updateSpeakerLabel`.
- Run `swift test --filter MainWindowViewLayoutTests`.
- Run `make test` before final handoff.

