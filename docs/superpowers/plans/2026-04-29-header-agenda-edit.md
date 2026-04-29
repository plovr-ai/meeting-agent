# Header Agenda Edit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move meeting goal and attendees into the workspace back/header row and make them direct agenda edit entry points.

**Architecture:** `MeetingCommandCenterView` keeps the existing agenda draft and save flow. `topCommandRow` renders goal and attendee buttons beside Back, both opening the existing `AgendaEditorView`; `AgendaContextStrip` keeps passive topic/time context and no longer renders an explicit Edit Agenda button.

**Tech Stack:** Swift 5.9, SwiftUI, XCTest source layout guards.

---

### Task 1: Add Layout Regression

**Files:**
- Modify: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

- [ ] **Step 1: Extend `testLiveWorkspaceShowsAgendaContextStrip`**

Replace the test body with assertions that the workspace still wires meeting agenda metadata and that the top row owns the edit affordance:

```swift
func testLiveWorkspaceShowsAgendaContextStrip() throws {
    let source = try appSource(named: "MainWindowView.swift")

    XCTAssertTrue(source.contains("AgendaContextStrip("))
    XCTAssertTrue(source.contains("meeting.attendees"))
    XCTAssertTrue(source.contains("meeting.agendaTopics"))
    XCTAssertTrue(source.contains("meeting.meetingGoal?.title"))
    XCTAssertTrue(source.contains("Button(action: beginDetailAgendaEdit)"))
    XCTAssertTrue(source.contains("CommandCenterChip(title: goalDisplay"))
    XCTAssertTrue(source.contains("CommandCenterChip(title: attendeesDisplay"))
    XCTAssertFalse(source.contains("Label(\"Edit Agenda\", systemImage: \"square.and.pencil\")"))
}
```

- [ ] **Step 2: Run the focused test and verify failure**

Run: `swift test --filter MainWindowViewLayoutTests/testLiveWorkspaceShowsAgendaContextStrip`

Expected before implementation: FAIL because the top row does not contain goal/attendee buttons and the old `Edit Agenda` label still exists.

### Task 2: Move Goal And Attendees Into Header

**Files:**
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift`

- [ ] **Step 1: Update `topCommandRow`**

Insert the agenda edit buttons immediately after Back:

```swift
Button(action: beginDetailAgendaEdit) {
    CommandCenterChip(title: goalDisplay, tint: CommandCenterPalette.primary, filled: meeting.meetingGoal != nil)
}
.buttonStyle(.plain)
.help("Edit meeting goal")

Button(action: beginDetailAgendaEdit) {
    CommandCenterChip(title: attendeesDisplay, tint: CommandCenterPalette.cyan, filled: !meeting.attendees.isEmpty)
}
.buttonStyle(.plain)
.help("Edit attendees")
```

Add helper properties on `MeetingCommandCenterView`:

```swift
private var goalDisplay: String {
    let normalized = meeting.meetingGoal?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return normalized.isEmpty ? "No goal" : normalized
}

private var attendeesDisplay: String {
    meeting.attendees.isEmpty ? "No attendees" : "\(meeting.attendees.count) attendees"
}
```

- [ ] **Step 2: Simplify `AgendaContextStrip`**

Remove `attendees`, `goalTitle`, and `editAgenda` from the view input. Keep `meeting` and `topics`, then delete the `Edit Agenda` button and the local `goalDisplay`. The strip should show only topic chips, overflow topic count, spacer, and scheduled time.

- [ ] **Step 3: Run the focused layout test**

Run: `swift test --filter MainWindowViewLayoutTests/testLiveWorkspaceShowsAgendaContextStrip`

Expected: PASS.

### Task 3: Verify And Commit

**Files:**
- Modified files from Task 1 and Task 2.

- [ ] **Step 1: Build the app**

Run: `swift build --product MeetingAgentApp`

Expected: build succeeds.

- [ ] **Step 2: Run required unit verification**

Run: `make test`

Expected: tests and coverage succeed.

- [ ] **Step 3: Commit**

Run:

```bash
git add Sources/MeetingAgentApp/MainWindowView.swift Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift docs/superpowers/plans/2026-04-29-header-agenda-edit.md
git commit -m "feat: move agenda edit entry to workspace header (#107)"
```

