# Agenda Single Feed Reimplementation Design

## Context

Issue #95 tracks reimplementing the agenda single-feed experience from #39 after later navigation and workspace work replaced the original shape.

The current app uses a `NavigationSplitView` with `Today`, `This Week`, `History`, and `Settings` destinations. `TodayAgendaView` already owns agenda rows, editing, local meeting creation, and start/open workspace actions. The missing behavior is the agenda-first main-region feed from #39: one scannable surface that starts with today's meetings and includes recent meeting context.

## Decision

Keep the current navigation model. Do not restore a separate top-level `Agenda` destination.

Reimplement the #39 single-feed experience inside the main detail region shown for `Today`. The left sidebar remains `Today / This Week / History`, preserving #91. The right side becomes an agenda-first workspace with a feed-led layout rather than only a today list plus editor.

## User Experience

When `Today` is selected, the main region should show:

- A header with `Agenda`, the current date, today's meeting count, and the live recording chip when one of the visible meetings is active.
- A feed column with a `Today` section and a `Recent` section.
- Today rows that preserve the current preparation workflow: scheduled time, title, goal, attendees, topics, live state, and primary action.
- Recent cards that restore #39's scan value: meeting title, date/time, transcription status, duration, locale, and artifact readiness.
- The existing agenda editor in the same main region so users can edit attendees, topics, scheduled time, and goal before opening the workspace.

When no meetings exist today, the `Today` section still shows the current create-meeting empty state. The recent section should still be available below it when recent meetings exist.

## Non-Goals

- Do not remove `Today / This Week / History` navigation.
- Do not revert `MainWindowView.swift` to the #39 `AgendaShellView` structure.
- Do not change meeting persistence or recorder behavior.
- Do not change live workspace transcript or insight behavior except where required for compilation.

## Architecture

`MainWindowView` continues to route `case .today` to `TodayAgendaView`, but it should pass enough meetings for `TodayAgendaView` to render both today's agenda and recent meeting context. Filtering for sidebar buckets remains in `MainWindowView`.

`TodayAgendaView` becomes responsible for:

- partitioning all supplied meetings into today and recent groups,
- rendering the agenda feed sections,
- preserving current agenda row actions and editor save/cancel behavior,
- exposing small helper views for recent meeting cards and artifact/status chips.

The recent feed should use local helpers inside `TodayAgendaView.swift` to keep the change scoped to the agenda surface. Shared app chrome stays in `MainWindowView.swift`.

## Data Rules

- Display date is `scheduledStartAt ?? startedAt`.
- Today uses `Calendar.current.isDate(_:inSameDayAs:)`.
- Recent includes meetings before today and within the last 7 days.
- Today feed rows sort ascending by display date.
- Recent groups sort newest day first, and meetings within each group sort newest display date first.
- Transcript readiness uses the existing readable transcript check from `TodayAgendaView`.
- Artifact readiness mirrors #39: summary ready wins over transcript ready, otherwise artifacts pending.

## Testing

Update `MainWindowViewLayoutTests.swift` with source-level layout guards that prove:

- `MainWindowView` still declares `Today`, `This Week`, and `History`.
- `MainWindowView` routes `TodayAgendaView` with the full `viewModel.meetings` collection so the main region can render both today and recent context.
- `TodayAgendaView` defines agenda feed sections for `Today` and `Recent`.
- `TodayAgendaView` preserves `AgendaRowView`, `AgendaEditorView`, `Open Workspace`, `Start Recording`, `Open Transcript`, `Create Meeting`, `Save`, and `Cancel`.
- The agenda editor dirty-state protections from #77 still exist.
- The live workspace agenda context strip still exists.

Run `make test` before completion.
