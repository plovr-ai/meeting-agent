# Meeting Workspace Back Button Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Back button on the meeting workspace that returns users to the agenda bucket they came from, with Today as the fallback.

**Architecture:** Keep navigation in `MainWindowView`'s existing explicit destination state. Store an optional agenda return destination before entering `.workspace`, pass a `backToMeetings` callback down to `MeetingDetailView`, and render the button in `MeetingCommandCenterView`.

**Tech Stack:** Swift 5.9, SwiftUI, XCTest source-layout regression tests, macOS app target.

---

## File Structure

- Modify `Sources/MeetingAgentApp/MainWindowView.swift`: add workspace return-state, route workspace entry through a helper, and render the Back button.
- Modify `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`: add source-layout regression tests for the return state and Back button wiring.

### Task 1: Add Failing Layout Coverage

**Files:**
- Modify: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

- [ ] **Step 1: Add the regression tests**

Append these tests near the other `MainWindowView.swift` layout tests:

```swift
func testMeetingWorkspaceBackButtonReturnsToSourceBucket() throws {
    let source = try appSource(named: "MainWindowView.swift")

    XCTAssertTrue(source.contains("@State private var workspaceReturnDestination: MainWindowDestination = .today"))
    XCTAssertTrue(source.contains("private func openWorkspace(from destination: MainWindowDestination, selecting meeting: MeetingRecord)"))
    XCTAssertTrue(source.contains("workspaceReturnDestination = destination.agendaReturnDestination"))
    XCTAssertTrue(source.contains("destination = .workspace"))
    XCTAssertTrue(source.contains("private var agendaReturnDestination: MainWindowDestination"))
    XCTAssertTrue(source.contains("case .workspace, .settings:"))
    XCTAssertTrue(source.contains("return .today"))
}

func testMeetingWorkspaceRendersBackButton() throws {
    let source = try appSource(named: "MainWindowView.swift")

    XCTAssertTrue(source.contains("backToMeetings: {"))
    XCTAssertTrue(source.contains("destination = workspaceReturnDestination"))
    XCTAssertTrue(source.contains("let backToMeetings: () -> Void"))
    XCTAssertTrue(source.contains("Button(action: backToMeetings)"))
    XCTAssertTrue(source.contains("Label(\"Back\", systemImage: \"chevron.left\")"))
}
```

- [ ] **Step 2: Run the focused test to verify it fails**

Run: `swift test --filter MainWindowViewLayoutTests/testMeetingWorkspaceBackButtonReturnsToSourceBucket`

Expected: fails because `workspaceReturnDestination`, `openWorkspace(from:selecting:)`, and `agendaReturnDestination` do not exist yet.

### Task 2: Implement Return Destination State And Routing

**Files:**
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift`

- [ ] **Step 1: Add return destination state**

Change the `MainWindowView` state declarations to:

```swift
@State private var destination: MainWindowDestination = .today
@State private var workspaceReturnDestination: MainWindowDestination = .today
```

- [ ] **Step 2: Route agenda workspace opens through a helper**

Replace the `openWorkspace` closure inside `TodayAgendaView` with:

```swift
openWorkspace: { meeting in
    openWorkspace(from: destination, selecting: meeting)
},
```

Replace the no-pending-candidate branch of `startRecording` with:

```swift
guard let target = viewModel.pendingCandidate else {
    openWorkspace(from: destination, selecting: meeting)
    return
}
```

Inside the successful async recording start path, set the return destination before entering the workspace:

```swift
try await viewModel.startRecording(for: target, meetingID: meeting.id)
workspaceReturnDestination = destination.agendaReturnDestination
destination = .workspace
```

- [ ] **Step 3: Pass Back callback into `MeetingDetailView`**

Add this argument in the `.workspace` case:

```swift
backToMeetings: {
    destination = workspaceReturnDestination
},
```

- [ ] **Step 4: Add helper methods**

Add these methods near the other `MainWindowView` private helpers:

```swift
private func openWorkspace(from destination: MainWindowDestination, selecting meeting: MeetingRecord) {
    workspaceReturnDestination = destination.agendaReturnDestination
    viewModel.selectMeeting(meeting.id)
    self.destination = .workspace
}
```

Add this extension after `MainWindowView`:

```swift
private extension MainWindowDestination {
    var agendaReturnDestination: MainWindowDestination {
        switch self {
        case .today, .thisWeek, .history:
            return self
        case .workspace, .settings:
            return .today
        }
    }
}
```

- [ ] **Step 5: Run the focused routing test**

Run: `swift test --filter MainWindowViewLayoutTests/testMeetingWorkspaceBackButtonReturnsToSourceBucket`

Expected: passes.

### Task 3: Render The Back Button

**Files:**
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift`

- [ ] **Step 1: Thread the callback through detail views**

Add `let backToMeetings: () -> Void` to `MeetingDetailView` and pass it into `MeetingCommandCenterView`:

```swift
let backToMeetings: () -> Void
```

```swift
MeetingCommandCenterView(
    meeting: meeting,
    backToMeetings: backToMeetings,
    pipelineDisplayName: pipelineDisplayName(for: speechConfiguration),
    ...
)
```

Add the same stored property to `MeetingCommandCenterView`:

```swift
let backToMeetings: () -> Void
```

- [ ] **Step 2: Render the button above the agenda context strip**

Change `MeetingCommandCenterView.body` to begin with this header before `AgendaContextStrip`:

```swift
VStack(spacing: 0) {
    HStack {
        Button(action: backToMeetings) {
            Label("Back", systemImage: "chevron.left")
        }
        .buttonStyle(.plain)
        .font(CommandCenterTypography.button)
        .foregroundStyle(CommandCenterPalette.primary)

        Spacer()
    }
    .padding(.horizontal, 22)
    .padding(.vertical, 10)
    .background(CommandCenterPalette.surface)
    .overlay(alignment: .bottom) {
        Rectangle()
            .fill(CommandCenterPalette.border)
            .frame(height: 1)
    }

    AgendaContextStrip(
        meeting: meeting,
        attendees: meeting.attendees,
        topics: meeting.agendaTopics,
        goalTitle: meeting.meetingGoal?.title
    )
```

- [ ] **Step 3: Run the focused Back button test**

Run: `swift test --filter MainWindowViewLayoutTests/testMeetingWorkspaceRendersBackButton`

Expected: passes.

### Task 4: Full Verification And Commit

**Files:**
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift`
- Modify: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

- [ ] **Step 1: Run full test suite**

Run: `make test`

Expected: all tests pass and coverage command completes.

- [ ] **Step 2: Inspect diff**

Run: `git diff -- Sources/MeetingAgentApp/MainWindowView.swift Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

Expected: diff only contains the source-return state, Back button, and focused tests.

- [ ] **Step 3: Commit implementation**

Run:

```bash
git add Sources/MeetingAgentApp/MainWindowView.swift Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift
git commit -m "feat: add meeting workspace back button (#99)"
```

Expected: commit succeeds.

## Self-Review

- Spec coverage: return-to-source bucket, Today fallback, visible chevron Back button, unchanged persistence, and source-layout tests are all covered by Tasks 1-4.
- Placeholder scan: no placeholder steps remain.
- Type consistency: `workspaceReturnDestination`, `agendaReturnDestination`, `openWorkspace(from:selecting:)`, and `backToMeetings` are named consistently across tests and implementation.
