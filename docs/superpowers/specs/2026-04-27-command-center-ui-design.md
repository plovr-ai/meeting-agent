# Command Center UI Design

## Context

Issue #22 requests updating the macOS app UI to match a supplied dark meeting command-center reference. The current app is a functional SwiftUI prototype with a plain `NavigationSplitView`, a meeting detail scroll view, and a standard `Form` settings view.

The approved direction is to keep the current product behavior and restyle the main app surface around the reference: dark window chrome, a dense transcript-first left pane, a summary/coaching right pane, muted separators, status chips, and teal action accents.

## Success Criteria

- The main meeting window visually resembles the supplied reference: dark background, two-panel command-center layout, compact typography, subtle borders, and teal primary actions.
- Existing workflows remain available: meeting selection, recording stop, transcription retry, live translation start/stop, summary copy, transcript export, meeting data export, readiness report export, and settings.
- Meeting metadata, live translation status, summaries, and transcripts are easier to scan in a live-meeting context.
- The settings surface uses the same visual language instead of the default plain form styling.
- The change is UI-only; no recording, transcription, translation, summary, or export behavior changes.

## Non-Goals

- Do not add new AI reply generation behavior beyond the existing live translation turns and summary content.
- Do not implement custom window controls or replace the app's macOS window management.
- Do not add image or network assets.
- Do not change persistence formats or meeting data models.

## Approach

Use a focused SwiftUI restyle rather than a larger app architecture rewrite. Add a small app-level design system abstraction so the reference style is consistent and not scattered across views. The design system will provide named palette colors, typography helpers, chip styles, panel containers, and button styles.

`MainWindowView.swift` will keep the existing view-model contract and actions, but reorganize the detail area into reusable private subviews for:

- dark app background and sidebar styling
- meeting header with live status, elapsed time, language direction, and progress
- transcript/live translation area
- action composer/export controls
- right-side summary/status panels

`SettingsView.swift` will keep the existing bindings and validation logic while adopting dark grouped panels and compact controls from the same design system.

This approach limits risk because the view model and core package behavior stay untouched. It also matches the issue's visual goal while avoiding invented product features.

## UI Structure

The main window uses a two-column command center:

- Left rail: meeting list and settings entry, styled as a dark sidebar.
- Main transcript pane: selected meeting title, recording status, progress, metadata chips, transcript text, live translation turns, and primary meeting actions.
- Right insight pane: phase-style summary, status indicators, export actions, and summary sections.
- Bottom composer/action row: a dark input-like surface with live translation and export controls mapped to existing actions.

When no meeting is selected, the empty state should still use the dark panel treatment.

## Design System

Create a dedicated app-target design system file, `CommandCenterDesignSystem.swift`, rather than defining colors and styles independently in each view. The file owns:

- `CommandCenterPalette` for named reference colors.
- reusable panel and chip modifiers.
- `CommandCenterButtonStyle` for primary, secondary, and danger actions.
- compact typography helpers for eyebrow labels, mono metadata, and body text.

View files may still compose layout locally, but repeated visual decisions must go through this design system.

## Testing

This is a SwiftUI styling change with limited testability in the existing XCTest suite. Add source-inspection tests only where useful to lock in key structural expectations, and run the repo-required `make test`. Also run `swift build --product MeetingAgentApp` to catch SwiftUI compile issues.

Manual verification should confirm the app builds and the affected views compile with the existing view model contract.
