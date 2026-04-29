# Navigation Title Design

## Issue

GitHub issue #115 asks to remove the topmost "Meeting Agent" title and restore "Meeting Agent" at the top of the navigation area.

## User Intent

The app should avoid a duplicated or overly prominent top application title while keeping a clear product label in the left navigation column.

## Requirements

- Show a compact `Meeting Agent` title at the top of the sidebar navigation in `MainWindowView`.
- Keep the title above `Today`, `Meetings`, and `Library`.
- Do not use `.navigationTitle("Meeting Agent")` for the main window, because that renders through the system navigation chrome and can reintroduce a top title.
- Preserve the existing sidebar destinations, selected styles, settings placement, and `NavigationSplitView` structure.

## Non-Requirements

- Do not rename the app bundle, menu bar app, or `WindowGroup`.
- Do not redesign the sidebar navigation rows.
- Do not change meeting routing, agenda filtering, or workspace behavior.

## Selected Approach

Add a small `Text("Meeting Agent")` header inside the existing sidebar `VStack` before the navigation buttons. This directly matches the requested nav-top placement and avoids changes to macOS window chrome.

## Alternatives Considered

- Window title only: too subtle and does not restore a nav-top label.
- Toolbar title: risks recreating the topmost title the issue asks to remove.
- Sidebar title: closest to the requested placement and lowest risk.

## Affected Files

- `Sources/MeetingAgentApp/MainWindowView.swift`
- `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

## Test Plan

- Update the source-layout regression so it proves the sidebar title exists before the first navigation button.
- Keep a regression assertion that `.navigationTitle("Meeting Agent")` is absent.
- Run the focused layout test class and the required `make test` verification.
