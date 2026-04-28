# Speaker Name Menu Design

## Context

Issue #27 asks to reduce visual noise in the transcript row speaker-name editing interaction. The current UI shows a dedicated speaker edit icon on every row, so every caption line has a persistent control even when the user is mainly reading meeting content.

## Goal

Make speaker-name editing feel lighter by attaching the edit affordance to the displayed speaker label, such as `User A`, instead of rendering a separate edit button on every row.

## Requirements

- Show the speaker label as a compact menu trigger with a dropdown indicator.
- The menu contains one action: `Edit name`.
- Selecting `Edit name` opens the existing speaker edit sheet.
- Keep the existing save path through `updateSpeakerLabel`.
- Keep caption text correction unchanged.
- Do not add speaker reassignment, known-speaker quick choices, or new persistence behavior.

## Selected Approach

Use a SwiftUI `Menu` for rows whose speaker has an identifier. The menu label renders the current speaker label and a small downward chevron, e.g. `User A v`. Its only item is `Edit name`, which invokes the existing `editSpeaker` closure.

Rows without an editable speaker identifier continue to show plain speaker text.

This approach follows the issue wording directly, removes the persistent person-edit icon, and avoids adding new behavior beyond the requested edit entry point.

## Alternatives Considered

- Keep plain text plus a standalone chevron button. This is more explicit but still adds a separate visual element to each row.
- Show the current edit icon only on hover. This would make the idle state clean, but it is less discoverable and adds hover-state complexity for a narrow change.

## Affected Files

- `Sources/MeetingAgentApp/MainWindowView.swift`
- `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

## Testing

- Add or update a layout regression test that verifies the transcript row uses a speaker menu with `Edit name`.
- Verify the old `person.crop.circle.badge.pencil` speaker edit icon is removed from `MainWindowView.swift`.
- Preserve tests that assert caption correction still uses the pencil icon and the existing edit sheets remain wired.
- Run `make test`.
