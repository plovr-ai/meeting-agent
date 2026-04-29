# Agenda Generated Title Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep the Agenda editor title synchronized with summary-generated meeting titles without overwriting unsaved agenda edits.

**Architecture:** `TodayAgendaView` will store both the visible `AgendaDraft` and the last record-backed baseline draft. The `meetings` change handler will refresh from the selected meeting only when the visible draft is still clean.

**Tech Stack:** Swift 5.9, SwiftUI, XCTest source-layout regression tests, Swift Package Manager.

---

## File Structure

- Modify `Sources/MeetingAgentApp/TodayAgendaView.swift`: add record-backed draft baseline state and clean-draft refresh logic.
- Modify `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`: add a focused source regression for the agenda draft refresh guard.

## Task 1: Add Agenda Draft Sync Guard

**Files:**
- Modify: `Sources/MeetingAgentApp/TodayAgendaView.swift`
- Test: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

- [ ] **Step 1: Write the failing source regression**

Add this test to `MainWindowViewLayoutTests`:

```swift
func testTodayAgendaRefreshesCleanDraftWhenSelectedMeetingRecordChanges() throws {
    let source = try appSource(named: "TodayAgendaView.swift")

    XCTAssertTrue(source.contains("@State private var recordBackedDraft = AgendaDraft()"))
    XCTAssertTrue(source.contains("draft == recordBackedDraft"))
    XCTAssertTrue(source.contains("resetDraftFromSelection()"))
}
```

- [ ] **Step 2: Run the focused test to verify it fails**

Run:

```bash
swift test --filter MainWindowViewLayoutTests/testTodayAgendaRefreshesCleanDraftWhenSelectedMeetingRecordChanges
```

Expected: FAIL because `recordBackedDraft` does not exist yet.

- [ ] **Step 3: Implement baseline draft tracking**

In `TodayAgendaView`, add a baseline state next to the existing draft state:

```swift
@State private var draft = AgendaDraft()
@State private var recordBackedDraft = AgendaDraft()
@State private var draftMeetingID: UUID?
```

Update the `meetings` change handler:

```swift
.onChange(of: meetings) { _, _ in
    guard draftMeetingID == selectedMeetingID else {
        resetDraftFromSelection()
        return
    }
    if draft == recordBackedDraft {
        resetDraftFromSelection()
    }
}
```

Update `resetDraftFromSelection()` so empty and selected states maintain the baseline:

```swift
private func resetDraftFromSelection() {
    guard let selectedMeeting else {
        draft = AgendaDraft()
        recordBackedDraft = draft
        draftMeetingID = nil
        saveError = nil
        return
    }
    draft = AgendaDraft(meeting: selectedMeeting)
    recordBackedDraft = draft
    draftMeetingID = selectedMeeting.id
    saveError = nil
}
```

- [ ] **Step 4: Run the focused test to verify it passes**

Run:

```bash
swift test --filter MainWindowViewLayoutTests/testTodayAgendaRefreshesCleanDraftWhenSelectedMeetingRecordChanges
```

Expected: PASS.

- [ ] **Step 5: Run full verification**

Run:

```bash
make test
```

Expected: PASS.

- [ ] **Step 6: Commit implementation**

Run:

```bash
git add Sources/MeetingAgentApp/TodayAgendaView.swift Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift docs/superpowers/specs/2026-04-29-agenda-generated-title-sync-design.md docs/superpowers/plans/2026-04-29-agenda-generated-title-sync.md
git commit -m "fix: sync agenda title after summary generation (#77)"
```

## Self-Review

- The plan covers the approved clean-draft refresh design.
- There are no placeholders.
- The test checks for the baseline state and clean-draft guard needed to prevent overwriting unsaved edits.
