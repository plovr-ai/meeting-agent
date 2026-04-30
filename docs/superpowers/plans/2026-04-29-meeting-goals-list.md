# Meeting Goals List Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add title-only multiple meeting goals, editable as a list and visible in a fixed workspace tracker.

**Architecture:** `MeetingRecord` gains canonical `meetingGoals` while retaining `meetingGoal` as a compatibility bridge. Agenda drafts edit `[String]` goal titles and convert them to normalized `MeetingGoal` values. The workspace right pane renders a `GoalTrackerPanel` above existing insight content, using existing first-goal progress state when available.

**Tech Stack:** Swift 5.9, SwiftUI, Swift Package Manager, XCTest.

---

### Task 1: Model and View-Model Goal Arrays

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingRecord.swift`
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingRecordTests.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] **Step 1: Write model regression tests**

Add tests that construct JSON with only `meetingGoal` and verify `meetingGoals` contains that goal, and JSON with `meetingGoals` and verify the first value remains the legacy `meetingGoal`.

- [ ] **Step 2: Write save regression test**

Extend `testSaveAgendaNormalizesAndPersistsEditableMetadata` so `MeetingAgendaUpdate` includes multiple goal titles, an empty title, and asserts saved/loaded `meetingGoals.map(\.title)` is trimmed and the legacy `meetingGoal?.title` equals the first saved goal.

- [ ] **Step 3: Implement model compatibility**

Add `meetingGoals: [MeetingGoal]` to `MeetingAgendaUpdate` and `MeetingRecord`, decode it with fallback from `meetingGoal`, encode it normally, and initialize it from either explicit goals or the legacy single goal.

- [ ] **Step 4: Implement view-model normalization**

Add a helper that normalizes goal arrays by trimming titles and dropping blanks. In `saveAgenda`, persist the normalized array and assign `record.meetingGoal = normalizedGoals.first`.

- [ ] **Step 5: Verify focused tests**

Run:

```bash
swift test --filter MeetingRecordTests
swift test --filter MeetingAgentViewModelTests/testSaveAgendaNormalizesAndPersistsEditableMetadata
```

Expected: both pass.

### Task 2: Agenda Goal List Editor

**Files:**
- Modify: `Sources/MeetingAgentApp/TodayAgendaView.swift`
- Test: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

- [ ] **Step 1: Write source-layout regression**

Add a layout test that verifies `AgendaDraft` has `goalTexts`, `AgendaEditorView` calls a `goalsEditor`, the UI includes `Add Goal`, and the old `labeledTextEditor("Meeting Goal", text: $draft.goalText)` call is gone.

- [ ] **Step 2: Change `AgendaDraft`**

Replace `goalText` with `goalTexts: [String]`. Load from `meeting.meetingGoals`, fall back to `meeting.meetingGoal`, and ensure the editor always has at least one row. Build `MeetingAgendaUpdate` with `meetingGoals` created from non-empty title rows and `meetingGoal` set to the first goal for compatibility.

- [ ] **Step 3: Add editor controls**

Add a `goalsEditor` section in `AgendaEditorView` with one `TextField` per goal, a remove icon button per row, and an `Add Goal` button that appends an empty row.

- [ ] **Step 4: Update row display**

Change agenda row goal copy to summarize `meeting.meetingGoals`: first title, `+N` suffix for more goals, or `No goals`.

- [ ] **Step 5: Verify focused layout test**

Run:

```bash
swift test --filter MainWindowViewLayoutTests/testTodayAgendaViewDefinesGoalListEditor
```

Expected: pass.

### Task 3: Workspace Goal Tracker

**Files:**
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift`
- Test: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

- [ ] **Step 1: Write source-layout regression**

Add a layout test that verifies `MeetingCommandCenterView` passes `meetingProgressState`, `InsightPaneView` accepts `meetingProgressState`, renders `GoalTrackerPanel`, and the panel appears before `phaseSummary`.

- [ ] **Step 2: Pass progress into right pane**

Add `meetingProgressState: MeetingProgressState?` to `MeetingCommandCenterView` and `InsightPaneView`, pass `viewModel.meetingProgressState` from the main workspace construction, and pass the value into `InsightPaneView`.

- [ ] **Step 3: Add `GoalTrackerPanel`**

Create a private SwiftUI view in `MainWindowView.swift` that renders `meeting.meetingGoals`, or `meeting.meetingGoal` fallback, as title rows. The first goal uses `meetingProgressState.status.displayText` when IDs match; other goals show `Pending`.

- [ ] **Step 4: Update header chip**

Change `goalDisplay` to summarize `meeting.meetingGoals`: first goal title plus `+N`, or `No goals`.

- [ ] **Step 5: Verify focused layout tests**

Run:

```bash
swift test --filter MainWindowViewLayoutTests/testWorkspaceInsightPaneShowsGoalTracker
swift test --filter MainWindowViewLayoutTests/testLiveWorkspaceShowsAgendaContextStrip
```

Expected: both pass.

### Task 4: Full Verification and Commit

**Files:**
- Modify: implementation and tests from Tasks 1-3
- Modify: `docs/superpowers/plans/2026-04-29-meeting-goals-list.md`

- [ ] **Step 1: Run build**

Run:

```bash
swift build --product MeetingAgentApp
```

Expected: build succeeds.

- [ ] **Step 2: Run required verification**

Run:

```bash
make test
```

Expected: all tests and coverage checks pass.

- [ ] **Step 3: Commit implementation**

Run:

```bash
git add Sources/MeetingAgentCore/MeetingRecord.swift Sources/MeetingAgentCore/MeetingAgentViewModel.swift Sources/MeetingAgentApp/TodayAgendaView.swift Sources/MeetingAgentApp/MainWindowView.swift Tests/MeetingAgentCoreTests/MeetingRecordTests.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift docs/superpowers/plans/2026-04-29-meeting-goals-list.md
git commit -m "feat: add meeting goals list (#111)"
```
