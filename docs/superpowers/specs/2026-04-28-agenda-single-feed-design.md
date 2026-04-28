# Agenda Single Feed Design

## Issue

GitHub issue #39 asks to optimize the agenda page UI. The current app uses a left meeting list and a right detail area, which makes meeting meta information hard to scan directly from the agenda.

## Goal

Replace the meeting list/detail agenda with a single feed that makes meeting schedule and metadata visible at a glance. Today's meetings should be the primary section. Recent historical meetings should remain available without dominating the first screen.

## Selected Direction

Use a single agenda feed. This was selected over a today-first dashboard and date-navigation layout because it removes the split view most directly and lets each meeting card carry its own metadata.

The feed structure is:

- `Today`: always first, showing today's meetings with fuller cards.
- `Recent`: meetings from the previous seven calendar days, grouped by non-empty date sections.
- Older meetings: not expanded in the agenda page for this issue.

The UI should not render an empty `Yesterday` section. A dedicated `Yesterday` label is too brittle for low-frequency meeting histories and cross-time-zone use. Date sections should appear only when at least one meeting exists for that day.

## Requirements

- Remove the meeting list/detail split from `MainWindowView`.
- Keep Settings reachable as a fixed command in the same left-side app shell.
- Show the agenda as the default main content when settings are not open.
- Render each meeting as a self-contained card with:
  - meeting name
  - start date and time
  - duration or live elapsed time
  - transcription status
  - locale
  - whether summary/export artifacts are available
- Selecting a meeting opens the existing detail experience for transcript, summary, export, and correction workflows.
- Today cards should be visually richer than recent-history cards, but both must expose core metadata.
- Recent history should include only meetings from the previous seven days and should be grouped by actual meeting date.
- Preserve existing recording, retry transcription, export, speaker edit, transcript edit, and settings behavior.

## Non-Requirements

- No new persisted fields.
- No search, filtering, or calendar picker in this issue.
- No expansion of meetings older than seven days.
- No redesign of `MeetingCommandCenterView`, `TranscriptPaneView`, or `InsightPaneView` beyond what is necessary to route from the agenda.
- No changes to meeting storage or transcription behavior.

## Approach

`MainWindowView` will keep the current command-center theme and settings destination but replace the `NavigationSplitView` meeting list with a custom shell. The shell has a narrow left rail for app identity and Settings, and a main content area that shows either `AgendaFeedView`, `MeetingDetailView`, or `SettingsView`.

`AgendaFeedView` receives `viewModel.meetings`, the selected meeting ID, and selection callbacks. It computes `todayMeetings` and `recentMeetingsByDate` using calendar-day comparisons. It renders Today as prominent cards and Recent as compact cards grouped by formatted date headers.

`AgendaMeetingCard` is a focused presentational view for one meeting card. It computes status text, duration text, summary availability, transcript availability, and locale chips from `MeetingRecord` only.

## Data Flow

`MeetingAgentViewModel` remains the source of truth. The agenda reads `meetings` and calls `viewModel.selectMeeting(_:)` when a card is opened. The existing detail view reads `viewModel.selectedMeeting` exactly as it does today.

Settings remains controlled by `showSettings`. Opening Settings clears the agenda/detail destination visually but does not mutate the selected meeting. Selecting a meeting sets `showSettings = false`.

## Testing

Add source-layout regression coverage because existing UI tests in this repository verify SwiftUI structure by inspecting source text.

Tests should assert:

- `NavigationSplitView` is no longer used by `MainWindowView`.
- `AgendaFeedView` and `AgendaMeetingCard` exist.
- Today and Recent sections are present.
- The code filters recent history to seven days.
- No static `Yesterday` section is rendered.
- Settings remains fixed in the app shell.
- Existing implemented detail controls remain present.

Run `make test` before completion.

## Risks

- The main window may become too dense if every card tries to show full detail. The design avoids this by using fuller Today cards and compact Recent cards.
- Removing `NavigationSplitView` can accidentally hide settings or detail workflows. The implementation should keep explicit view states for agenda, detail, and settings.
- Date grouping can be off by calendar boundary. Use `Calendar.current` day comparisons instead of raw second intervals for section membership.
