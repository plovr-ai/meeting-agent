# Meeting Detail Goal Editing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users edit a meeting goal from the meeting detail page.

**Architecture:** Reuse the existing agenda metadata save path from `MeetingAgentViewModel.saveAgenda(for:update:)`. `MeetingDetailView` passes a save closure into `MeetingCommandCenterView`, and the detail surface presents an agenda-style editor so goal changes persist with the same normalization and progress reset behavior as the agenda page.

**Tech Stack:** Swift 5.9, SwiftUI, Swift Package Manager, XCTest.

---

## File Structure

- Modify `Sources/MeetingAgentApp/MainWindowView.swift` to add the detail-page edit state, editor presentation, and `saveAgenda` closure wiring.
- Modify `Sources/MeetingAgentApp/TodayAgendaView.swift` only if `AgendaDraft` or `AgendaEditorView` visibility must be widened for reuse.
- Modify `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift` with source-level regression coverage for the new detail-page editing path.

### Task 1: Detail Page Goal Editing UI

**Files:**
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift`
- Test: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

- [ ] **Step 1: Write the failing layout test**

Add this test near the existing meeting-detail layout tests in `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`:

```swift
func testMeetingDetailAllowsEditingAgendaGoalThroughSaveAgenda() throws {
    let source = try appSource(named: "MainWindowView.swift")

    XCTAssertTrue(source.contains("saveAgenda: { meetingID, update in"))
    XCTAssertTrue(source.contains("editAgenda: { editAgendaTarget = meeting }"))
    XCTAssertTrue(source.contains("AgendaEditorView("))
    XCTAssertTrue(source.contains("try saveAgenda(meetingID, draft.update())"))
    XCTAssertTrue(source.contains("Label(\"Edit Agenda\", systemImage: \"square.and.pencil\")"))
    XCTAssertTrue(source.contains("labeledTextEditor(\"Meeting Goal\", text: $draft.goalText)"))
}
```

- [ ] **Step 2: Run the focused test to verify it fails**

Run:

```bash
swift test --filter MainWindowViewLayoutTests/testMeetingDetailAllowsEditingAgendaGoalThroughSaveAgenda
```

Expected: FAIL because the detail page has no `editAgenda` action, no detail editor presentation, and no `saveAgenda` closure.

- [ ] **Step 3: Wire `saveAgenda` into `MeetingDetailView`**

In `Sources/MeetingAgentApp/MainWindowView.swift`, update the `MeetingDetailView` call from the app detail switch to pass the existing view-model save path:

```swift
saveAgenda: { meetingID, update in
    try viewModel.saveAgenda(for: meetingID, update: update)
},
```

Add the matching stored property to `MeetingDetailView`:

```swift
let saveAgenda: (UUID, MeetingAgendaUpdate) throws -> Void
```

Pass it through to `MeetingCommandCenterView`:

```swift
saveAgenda: saveAgenda,
```

- [ ] **Step 4: Add detail-page editor state and presentation**

In `MeetingCommandCenterView`, add:

```swift
let saveAgenda: (UUID, MeetingAgendaUpdate) throws -> Void
@State private var editAgendaTarget: MeetingRecord?
@State private var agendaDraft = AgendaDraft()
@State private var agendaRecordBackedDraft = AgendaDraft()
@State private var agendaSaveError: String?
```

Wrap the existing root `VStack` in a `ZStack(alignment: .topTrailing)` and present a side editor when `editAgendaTarget` is non-nil:

```swift
if let editAgendaTarget {
    AgendaEditorView(
        meeting: editAgendaTarget,
        draft: $agendaDraft,
        saveError: agendaSaveError,
        save: saveDetailAgenda,
        cancel: cancelDetailAgendaEdit
    )
    .frame(width: 360)
    .padding(.top, 54)
    .padding(.trailing, 18)
}
```

Add helpers inside `MeetingCommandCenterView`:

```swift
private func beginDetailAgendaEdit() {
    editAgendaTarget = meeting
    agendaDraft = AgendaDraft(meeting: meeting)
    agendaRecordBackedDraft = agendaDraft
    agendaSaveError = nil
}

private func saveDetailAgenda() {
    guard let meetingID = editAgendaTarget?.id else { return }
    do {
        try saveAgenda(meetingID, agendaDraft.update())
        agendaRecordBackedDraft = agendaDraft
        editAgendaTarget = nil
        agendaSaveError = nil
    } catch {
        agendaSaveError = "Could not save agenda: \(error)"
    }
}

private func cancelDetailAgendaEdit() {
    agendaDraft = agendaRecordBackedDraft
    editAgendaTarget = nil
    agendaSaveError = nil
}
```

- [ ] **Step 5: Add the edit action to the agenda context strip**

Update `AgendaContextStrip` to accept an edit closure:

```swift
let editAgenda: () -> Void
```

Render the action near the right side of the strip:

```swift
Button(action: editAgenda) {
    Label("Edit Agenda", systemImage: "square.and.pencil")
}
.buttonStyle(CommandCenterSecondaryButtonStyle())
```

Pass it from `MeetingCommandCenterView`:

```swift
editAgenda: beginDetailAgendaEdit
```

- [ ] **Step 6: Widen editor helper visibility only as needed**

If the compiler reports `AgendaEditorView` or `AgendaDraft` is inaccessible from `MainWindowView.swift`, change their declarations in `Sources/MeetingAgentApp/TodayAgendaView.swift` from `private` to internal:

```swift
struct AgendaEditorView: View {
```

```swift
struct AgendaDraft: Equatable {
```

Keep nested helper methods private unless the compiler requires otherwise.

- [ ] **Step 7: Run focused tests and build**

Run:

```bash
swift test --filter MainWindowViewLayoutTests/testMeetingDetailAllowsEditingAgendaGoalThroughSaveAgenda
swift build --product MeetingAgentApp
```

Expected: both commands pass.

- [ ] **Step 8: Run full verification**

Run:

```bash
make test
```

Expected: unit tests pass and coverage check succeeds.

- [ ] **Step 9: Commit implementation**

Run:

```bash
git add Sources/MeetingAgentApp/MainWindowView.swift Sources/MeetingAgentApp/TodayAgendaView.swift Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift
git commit -m "feat: edit meeting goals from detail view (#101)"
```

If `TodayAgendaView.swift` was not changed, omit it from `git add`.

## Self-Review

- Spec coverage: The plan adds a detail-page edit action, saves through existing agenda persistence, preserves metadata through `AgendaDraft(meeting:)`, updates visible state through existing view-model publication, and keeps recording/transcript/export controls untouched.
- Placeholder scan: No placeholders remain.
- Type consistency: The plan uses existing `MeetingAgendaUpdate`, `AgendaDraft`, `AgendaEditorView`, and `saveAgenda(for:update:)` names.
