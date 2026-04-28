# Translation UI Order Design

## Issue

GitHub issue #42 asks to adjust the live bilingual transcript UI order. The current app shows translated text above the original/source text. The requested behavior is to show the original language above the translated language.

## Success Criteria

- Live bilingual transcript rows render original/source text first.
- Translated text remains visible directly below the source text when translation is available.
- Pending and failed translation states continue to show source text above their status labels.
- Transcript storage, translation scheduling, exports, and summary behavior are unchanged.
- A focused regression test protects the order in `BilingualTranscriptRow`.

## Selected Approach

Use a UI-only change in `BilingualTranscriptRow`. `LiveCaptionDisplayState` can keep describing the translation as the primary translated text plus source text because other core tests already cover that state contract. The SwiftUI row should decide visual hierarchy by rendering `sourceText` first and `primaryText` second for translated rows.

This is the smallest change that directly addresses the issue without changing model semantics or persisted artifacts.

## Alternatives Considered

1. Change `LiveCaptionDisplayState` so source text is the primary value. This would make the display-state contract match the new visual hierarchy, but it changes core semantics for a UI-specific order decision.
2. Add a configurable order setting. This is more flexible, but issue #42 requests one product behavior and the settings surface does not need another option yet.

## Affected Files

- `Sources/MeetingAgentApp/MainWindowView.swift`
- `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

## Test Plan

- Add a source-layout regression test that finds the `.translated` switch branch and asserts `Text(sourceText)` appears before `Text(primaryText)`.
- Run `make test`.

