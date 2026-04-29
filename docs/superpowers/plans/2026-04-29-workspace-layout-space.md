# Workspace Layout Space Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Optimize the meeting workspace layout so the navigation and transcript areas use screen space more efficiently.

**Architecture:** Keep the existing `MainWindowView.swift` component structure but trim nonessential framing: shrink the sidebar, remove the fixed app header and separate agenda strip, and let transcript content render directly in the scroll area. Preserve all existing callbacks and action controls.

**Tech Stack:** Swift 5.9, SwiftUI, XCTest source-layout guards.

---

### Task 1: Update Workspace Layout Guards

**Files:**
- Modify: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

- [ ] **Step 1: Change the sidebar width expectation**

Replace the assertion in `testAgendaSidebarUsesWiderDefaultWidth` with:

```swift
XCTAssertTrue(source.contains(".frame(minWidth: 180, idealWidth: 210)"))
```

- [ ] **Step 2: Change the sidebar title test into a removal guard**

Update `testSidebarTitleUsesCommandCenterStylingInsteadOfSystemNavigationTitle` so it asserts:

```swift
XCTAssertFalse(source.contains("sidebarHeader"))
XCTAssertFalse(source.contains("Text(\"Meeting Agent\")"))
XCTAssertFalse(source.contains(".navigationTitle(\"Meeting Agent\")"))
```

- [ ] **Step 3: Add a workspace strip removal guard**

Add or update a test near `testLiveWorkspaceShowsAgendaContextStrip` to assert the workspace no longer renders `AgendaContextStrip(` and still contains goal/attendee edit chips in the top row:

```swift
XCTAssertFalse(source.contains("AgendaContextStrip("))
XCTAssertFalse(source.contains("private struct AgendaContextStrip"))
XCTAssertTrue(source.contains("Button(action: beginDetailAgendaEdit)"))
XCTAssertTrue(source.contains("title: goalDisplay"))
XCTAssertTrue(source.contains("title: attendeesDisplay"))
```

- [ ] **Step 4: Add a transcript panel removal guard**

Update `testTranscriptPaneUsesUnifiedTranscriptSurface` to check that `UnifiedTranscriptView` does not wrap its content in `CommandCenterPanel`:

```swift
guard let unifiedRange = source.range(of: "private struct UnifiedTranscriptView") else {
    return XCTFail("UnifiedTranscriptView is missing")
}
guard let groupRange = source.range(of: "private struct BilingualTranscriptGroup", range: unifiedRange.upperBound..<source.endIndex) else {
    return XCTFail("UnifiedTranscriptView boundary is missing")
}
let unifiedSource = source[unifiedRange.lowerBound..<groupRange.lowerBound]
XCTAssertFalse(unifiedSource.contains("CommandCenterPanel"))
```

- [ ] **Step 5: Run focused tests and confirm failure**

Run:

```sh
swift test --filter MainWindowViewLayoutTests
```

Expected: FAIL because implementation still uses the old sidebar width, header, agenda strip, and transcript panel.

### Task 2: Trim MainWindowView Layout

**Files:**
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift`

- [ ] **Step 1: Remove the sidebar header from the rendered sidebar**

In the `NavigationSplitView` sidebar `VStack`, remove the `sidebarHeader` line so the sidebar starts with the navigation button group.

- [ ] **Step 2: Narrow the sidebar**

Change:

```swift
.frame(minWidth: 260, idealWidth: 300)
```

to:

```swift
.frame(minWidth: 180, idealWidth: 210)
```

- [ ] **Step 3: Delete the unused sidebarHeader property**

Remove the entire `private var sidebarHeader: some View` computed property from `MainWindowView`.

- [ ] **Step 4: Remove the separate agenda context strip from the workspace**

In `MeetingCommandCenterView.body`, remove:

```swift
AgendaContextStrip(
    meeting: meeting,
    topics: meeting.agendaTopics
)
```

- [ ] **Step 5: Delete the unused AgendaContextStrip type**

Remove the entire `private struct AgendaContextStrip: View` declaration.

- [ ] **Step 6: Let UnifiedTranscriptView render unframed**

Change `UnifiedTranscriptView.body` from:

```swift
CommandCenterPanel {
    VStack(alignment: .leading, spacing: 14) {
        ...
    }
}
```

to:

```swift
VStack(alignment: .leading, spacing: 14) {
    ...
}
.frame(maxWidth: .infinity, alignment: .leading)
```

- [ ] **Step 7: Run focused tests and confirm pass**

Run:

```sh
swift test --filter MainWindowViewLayoutTests
```

Expected: PASS.

### Task 3: Full Verification And Commit

**Files:**
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift`
- Modify: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

- [ ] **Step 1: Run required verification**

Run:

```sh
make test
```

Expected: PASS.

- [ ] **Step 2: Review diff**

Run:

```sh
git diff -- Sources/MeetingAgentApp/MainWindowView.swift Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift
```

Expected: Only the workspace layout trim and matching tests are changed.

- [ ] **Step 3: Commit implementation**

Run:

```sh
git add Sources/MeetingAgentApp/MainWindowView.swift Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift
git commit -m "feat: optimize workspace layout space (#112)"
```
