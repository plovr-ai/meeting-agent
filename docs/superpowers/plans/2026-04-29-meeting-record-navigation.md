# Meeting Record Navigation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace recording-centric navigation with `MeetingRecord`-driven `Today`, `This Week`, and `History` meeting buckets.

**Architecture:** Keep `MeetingAgentViewModel` and `MeetingRecord` unchanged. Compute calendar buckets inside `MainWindowView` from `scheduledStartAt ?? startedAt`, pass today's meetings into `TodayAgendaView`, and route bucket row selections to the existing workspace detail.

**Tech Stack:** Swift 5.9, SwiftUI, XCTest source-layout regression tests, Swift Package Manager.

---

### Task 1: Add Navigation Regression Coverage

**Files:**
- Modify: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`
- Test: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

- [ ] **Step 1: Update the routing test first**

Replace `testMainWindowRoutesThroughAgendaFirstSidebarSections` with assertions for `thisWeek`, `history`, bucket filtering helpers, and removal of the `Recordings` nav button:

```swift
func testMainWindowRoutesThroughMeetingRecordBuckets() throws {
    let source = try appSource(named: "MainWindowView.swift")

    XCTAssertTrue(source.contains("enum MainWindowDestination"))
    XCTAssertTrue(source.contains("case today"))
    XCTAssertTrue(source.contains("case thisWeek"))
    XCTAssertTrue(source.contains("case history"))
    XCTAssertTrue(source.contains("TodayAgendaView("))
    XCTAssertTrue(source.contains("Button(\"Today\")"))
    XCTAssertTrue(source.contains("Button(\"This Week\")"))
    XCTAssertTrue(source.contains("Button(\"History\")"))
    XCTAssertTrue(source.contains("Label(\"Settings\", systemImage: \"gearshape\")"))
    XCTAssertTrue(source.contains("meetings(for: destination)"))
    XCTAssertTrue(source.contains("meetingDisplayDate(_ meeting: MeetingRecord)"))
    XCTAssertTrue(source.contains("meeting.scheduledStartAt ?? meeting.startedAt"))
    XCTAssertFalse(source.contains("Button(\"Recordings\")"))
    XCTAssertFalse(source.contains("Text(\"Recent Recordings\")"))
}
```

- [ ] **Step 2: Add a bucket-specific behavior guard**

Add a new source-layout test that confirms today is passed into the agenda and current-week/history filtering is implemented:

```swift
func testMeetingBucketsUseCalendarBoundaries() throws {
    let source = try appSource(named: "MainWindowView.swift")

    XCTAssertTrue(source.contains("TodayAgendaView("))
    XCTAssertTrue(source.contains("meetings: meetings(for: .today)"))
    XCTAssertTrue(source.contains("calendar.isDate(meetingDate, inSameDayAs: now)"))
    XCTAssertTrue(source.contains("calendar.isDate(meetingDate, equalTo: now, toGranularity: .weekOfYear)"))
    XCTAssertTrue(source.contains("calendar.isDate(meetingDate, equalTo: now, toGranularity: .yearForWeekOfYear)"))
    XCTAssertTrue(source.contains("!calendar.isDate(meetingDate, inSameDayAs: now)"))
}
```

- [ ] **Step 3: Run focused tests and verify they fail**

Run: `swift test --filter MainWindowViewLayoutTests/testMainWindowRoutesThroughMeetingRecordBuckets --filter MainWindowViewLayoutTests/testMeetingBucketsUseCalendarBoundaries`

Expected: fail before implementation because `thisWeek`, `history`, and bucket helpers do not exist yet.

### Task 2: Implement Meeting Buckets in MainWindowView

**Files:**
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift`
- Test: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

- [ ] **Step 1: Replace the destination case**

Change:

```swift
case recordings
```

to:

```swift
case thisWeek
case history
```

- [ ] **Step 2: Replace sidebar buttons**

Replace the `Recordings` button with:

```swift
Button("This Week") {
    destination = .thisWeek
}
.buttonStyle(SidebarNavigationButtonStyle(isSelected: destination == .thisWeek))

Button("History") {
    destination = .history
}
.buttonStyle(SidebarNavigationButtonStyle(isSelected: destination == .history))
```

- [ ] **Step 3: Filter sidebar rows by destination**

Change the `ForEach(viewModel.meetings)` list source to:

```swift
ForEach(meetings(for: destination)) { meeting in
```

Change the list header to:

```swift
Text(meetingListTitle(for: destination))
    .foregroundStyle(CommandCenterPalette.secondaryText)
```

- [ ] **Step 4: Pass only today's meetings to the Today surface**

Change the `TodayAgendaView` call to:

```swift
TodayAgendaView(
    meetings: meetings(for: .today),
```

- [ ] **Step 5: Keep detail routing explicit**

Change the detail switch case from:

```swift
case .recordings, .workspace:
```

to:

```swift
case .thisWeek, .history, .workspace:
```

- [ ] **Step 6: Add calendar bucket helpers**

Add these helpers inside `MainWindowView`:

```swift
private func meetings(for destination: MainWindowDestination) -> [MeetingRecord] {
    switch destination {
    case .today:
        return viewModel.meetings.filter { isToday($0) }
    case .thisWeek:
        return viewModel.meetings.filter { isThisWeek($0) && !isToday($0) }
    case .history:
        return viewModel.meetings.filter { !isThisWeek($0) }
    case .workspace:
        return viewModel.meetings
    case .settings:
        return []
    }
}

private func meetingListTitle(for destination: MainWindowDestination) -> String {
    switch destination {
    case .today:
        return "Today"
    case .thisWeek:
        return "This Week"
    case .history:
        return "History"
    case .workspace:
        return "All Meetings"
    case .settings:
        return "Meetings"
    }
}

private func isToday(_ meeting: MeetingRecord, now: Date = Date(), calendar: Calendar = .current) -> Bool {
    calendar.isDate(meetingDisplayDate(meeting), inSameDayAs: now)
}

private func isThisWeek(_ meeting: MeetingRecord, now: Date = Date(), calendar: Calendar = .current) -> Bool {
    let meetingDate = meetingDisplayDate(meeting)
    return calendar.isDate(meetingDate, equalTo: now, toGranularity: .weekOfYear)
        && calendar.isDate(meetingDate, equalTo: now, toGranularity: .yearForWeekOfYear)
}

private func meetingDisplayDate(_ meeting: MeetingRecord) -> Date {
    meeting.scheduledStartAt ?? meeting.startedAt
}
```

- [ ] **Step 7: Run focused tests and verify pass**

Run: `swift test --filter MainWindowViewLayoutTests`

Expected: pass.

### Task 3: Full Verification and Commit

**Files:**
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift`
- Modify: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`
- Existing: `docs/superpowers/specs/2026-04-29-meeting-record-navigation-design.md`
- Existing: `docs/superpowers/plans/2026-04-29-meeting-record-navigation.md`

- [ ] **Step 1: Build the app**

Run: `swift build --product MeetingAgentApp`

Expected: build succeeds.

- [ ] **Step 2: Run required unit verification**

Run: `make test`

Expected: all tests pass and coverage gate passes.

- [ ] **Step 3: Inspect relevant diff**

Run: `git diff -- Sources/MeetingAgentApp/MainWindowView.swift Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift docs/superpowers/plans/2026-04-29-meeting-record-navigation.md`

Expected: diff only covers meeting bucket navigation, layout tests, and this plan.

- [ ] **Step 4: Commit implementation**

Run:

```bash
git add Sources/MeetingAgentApp/MainWindowView.swift Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift docs/superpowers/plans/2026-04-29-meeting-record-navigation.md
git commit -m "feat: align navigation around meetings (#91)"
```
