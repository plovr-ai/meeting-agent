# Agenda Single Feed Reimplementation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore the #39 agenda single-feed experience inside the current `Today` main region without regressing `Today / This Week / History` navigation.

**Architecture:** `MainWindowView` keeps the current `NavigationSplitView` and sidebar buckets, but passes all meetings to `TodayAgendaView` for the `Today` detail pane. `TodayAgendaView` partitions meetings into today and recent feed sections, preserves agenda editing and actions, and adds recent meeting cards with status/artifact chips.

**Tech Stack:** Swift 5.9, SwiftUI, Swift Package Manager, XCTest source-layout guards.

---

### Task 1: Add Layout Guards For The Reimplemented Feed

**Files:**
- Modify: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

- [ ] **Step 1: Update the bucket routing test expectation**

Change the assertion in `testMeetingBucketsUseCalendarBoundaries` from:

```swift
XCTAssertTrue(source.contains("meetings: meetings(for: .today)"))
```

to:

```swift
XCTAssertTrue(source.contains("meetings: viewModel.meetings"))
```

- [ ] **Step 2: Add a feed-section layout test**

Add this test after `testTodayAgendaViewDefinesAgendaRowsAndExplicitEditorSaveCancel`:

```swift
func testTodayAgendaRestoresSingleFeedSections() throws {
    let source = try appSource(named: "TodayAgendaView.swift")

    XCTAssertTrue(source.contains("AgendaFeedSection(title: \"Today\""))
    XCTAssertTrue(source.contains("AgendaFeedSection(title: \"Recent\""))
    XCTAssertTrue(source.contains("recentGroups"))
    XCTAssertTrue(source.contains("recentHistoryDays"))
    XCTAssertTrue(source.contains("RecentAgendaMeetingCard"))
    XCTAssertTrue(source.contains("Meeting schedule and metadata"))
    XCTAssertTrue(source.contains("Summary ready"))
    XCTAssertTrue(source.contains("Transcript ready"))
    XCTAssertTrue(source.contains("Artifacts pending"))
}
```

- [ ] **Step 3: Run the focused layout tests and verify failure**

Run:

```bash
swift test --filter MainWindowViewLayoutTests
```

Expected: fails because `TodayAgendaView` has not yet added feed sections and `MainWindowView` still passes only `meetings(for: .today)`.

### Task 2: Route Today Main Region With Full Meeting Context

**Files:**
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift`
- Test: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

- [ ] **Step 1: Pass all meetings to TodayAgendaView**

Change the `TodayAgendaView` call in the `.today` destination from:

```swift
meetings: meetings(for: .today),
```

to:

```swift
meetings: viewModel.meetings,
```

- [ ] **Step 2: Run the focused routing test**

Run:

```bash
swift test --filter MainWindowViewLayoutTests/testMeetingBucketsUseCalendarBoundaries
```

Expected: passes after Task 1 and this change.

### Task 3: Implement Today And Recent Feed Sections

**Files:**
- Modify: `Sources/MeetingAgentApp/TodayAgendaView.swift`
- Test: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

- [ ] **Step 1: Add recent feed constants and groups**

Inside `TodayAgendaView`, add:

```swift
private let recentHistoryDays = 7
```

Add computed properties:

```swift
private var recentGroups: [(Date, [MeetingRecord])] {
    let calendar = Calendar.current
    let startOfToday = calendar.startOfDay(for: Date())
    let recentHistoryStart = calendar.date(byAdding: .day, value: -recentHistoryDays, to: startOfToday) ?? startOfToday
    let recentMeetings = meetings.filter { meeting in
        let day = calendar.startOfDay(for: displayDate(for: meeting))
        return day >= recentHistoryStart && day < startOfToday
    }
    let grouped = Dictionary(grouping: recentMeetings) { meeting in
        calendar.startOfDay(for: displayDate(for: meeting))
    }
    return grouped.keys.sorted(by: >).map { day in
        let meetings = grouped[day]?.sorted { displayDate(for: $0) > displayDate(for: $1) } ?? []
        return (day, meetings)
    }
}
```

- [ ] **Step 2: Replace `agendaList` populated branch with a feed**

Keep the current empty-state behavior for no today meetings, but make the populated and mixed state render a scroll view containing `AgendaFeedSection(title: "Today", count: todayMeetings.count)` and a conditional `AgendaFeedSection(title: "Recent", count: recentGroups.reduce(0) { $0 + $1.1.count })`.

Use `AgendaRowView` for today rows and `RecentAgendaMeetingCard` for recent rows.

- [ ] **Step 3: Add `AgendaFeedSection`**

Add a private generic view:

```swift
private struct AgendaFeedSection<Content: View>: View {
    let title: String
    let count: Int
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).commandCenterEyebrow()
                CommandCenterChip(title: "\(count)")
            }
            content
        }
    }
}
```

- [ ] **Step 4: Add `RecentAgendaMeetingCard`**

Add a private view that mirrors #39 scan metadata:

```swift
private struct RecentAgendaMeetingCard: View {
    let meeting: MeetingRecord
    let isSelected: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            CommandCenterPanel {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(meeting.name)
                            .font(CommandCenterTypography.sectionTitle)
                            .foregroundStyle(CommandCenterPalette.text)
                            .lineLimit(2)
                        Spacer()
                        Text(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                            .commandCenterMono()
                    }
                    HStack(spacing: 8) {
                        CommandCenterChip(title: statusText, tint: statusTint, filled: true)
                        CommandCenterChip(title: durationText)
                        CommandCenterChip(title: meeting.speechLocaleIdentifier, tint: CommandCenterPalette.cyan)
                        CommandCenterChip(title: artifactText, tint: artifactTint)
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? CommandCenterPalette.primary : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
```

Implement the helper properties with the same status, duration, and artifact logic from #39.

- [ ] **Step 5: Run the focused feed test**

Run:

```bash
swift test --filter MainWindowViewLayoutTests/testTodayAgendaRestoresSingleFeedSections
```

Expected: passes.

### Task 4: Verify Full Unit Suite And Commit

**Files:**
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift`
- Modify: `Sources/MeetingAgentApp/TodayAgendaView.swift`
- Modify: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

- [ ] **Step 1: Run required unit verification**

Run:

```bash
make test
```

Expected: all tests pass and coverage gate passes.

- [ ] **Step 2: Review the issue acceptance criteria**

Confirm:

- `Today / This Week / History` are still present.
- `TodayAgendaView` receives all meetings.
- The `Today` main area contains `Today` and `Recent` feed sections.
- Agenda editing, save/cancel, local create, start recording, open workspace, and open transcript markers remain.
- Live workspace agenda context strip markers remain.

- [ ] **Step 3: Commit implementation**

Run:

```bash
git add Sources/MeetingAgentApp/MainWindowView.swift Sources/MeetingAgentApp/TodayAgendaView.swift Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift
git commit -m "feat: restore agenda single feed in today view (#95)"
```

Expected: commit succeeds.

---

## Self-Review

- Spec coverage: all #95 acceptance criteria map to Tasks 1-4.
- Placeholder scan: no placeholder tasks remain.
- Type consistency: all referenced view and helper names are introduced before tests depend on them.
