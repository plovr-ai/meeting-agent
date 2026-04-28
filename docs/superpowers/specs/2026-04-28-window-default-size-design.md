# Window Default Size Design

## Issue

GitHub issue #31 requests a better startup window size for the macOS app. The current default window is too small to show the full application, and the left meetings navigation is narrow enough that meeting titles are often truncated.

## Goals

- Start the main app window at a size based on the current screen so the prototype opens with enough room for the full command-center layout.
- Cap the startup width at 1400 points so large or ultrawide displays do not produce an unnecessarily wide window.
- Use the visible screen frame so the default size respects the menu bar and Dock.
- Widen the meetings sidebar so meeting titles are more likely to display fully.
- Keep the existing minimum window size and all recording, transcription, settings, summary, and export behavior unchanged.

## Non-Goals

- Do not add persistent window-size restoration.
- Do not redesign meeting rows or the detail layout.
- Do not introduce custom AppKit window controllers unless SwiftUI scene sizing is insufficient.

## Selected Approach

Add a small app-layer sizing helper that computes the default main window size from `NSScreen.main?.visibleFrame`. The default width is the lesser of the visible screen width and 1400 points. The default height is the visible screen height. If no screen is available, the helper falls back to the existing usable baseline size.

Apply the computed size to the main `WindowGroup` with SwiftUI's scene default sizing API. Keep the existing `MainWindowView` minimum size so users cannot shrink the app below the current supported layout.

For the meetings navigation, add explicit width constraints to the sidebar root view in `MainWindowView`, with a larger minimum and ideal width. This preserves the existing `NavigationSplitView` behavior while giving the meetings list more room by default.

## Alternatives Considered

1. Use a larger fixed default size, such as 1400 by 900. This is simpler, but it does not adapt to smaller laptop screens or taller displays.
2. Implement persistent window frame restoration. This is a fuller product behavior, but it is larger than the issue asks for and can be added later after the default startup strategy is settled.

## Affected Files

- `Sources/MeetingAgentApp/MeetingAgentApp.swift`
- `Sources/MeetingAgentApp/MainWindowView.swift`
- `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

## Test Plan

- Add layout/source tests that verify the app uses a computed default window size with a 1400-point width cap.
- Add layout/source tests that verify the sidebar has wider minimum and ideal width constraints.
- Run `make test`.

