# Remove Summary Status Badges Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the recording and summary-ready chips from the summary area while preserving summary content and agenda/list artifact badges.

**Architecture:** Keep the change scoped to the SwiftUI summary pane. Delete the chip row from `InsightPaneView.phaseSummary` and add a layout regression that checks only the `InsightPaneView` source slice, so `TodayAgendaView` can keep its existing `Summary ready` artifact text.

**Tech Stack:** Swift 5.9, SwiftUI, XCTest source-layout tests, Swift Package Manager, project `make test`.

---

### Task 1: Remove Summary-Area Status Chips

**Files:**
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift`
- Modify: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

- [ ] **Step 1: Write the failing layout regression**

Add this test to `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift` near the existing summary/workspace layout tests:

```swift
func testInsightPaneDoesNotRenderSummaryStatusBadges() throws {
    let source = try appSource(named: "MainWindowView.swift")

    guard let insightRange = source.range(of: "private struct InsightPaneView") else {
        return XCTFail("InsightPaneView is missing")
    }
    guard let summaryListRange = source.range(of: "private struct SummaryListView", range: insightRange.upperBound..<source.endIndex) else {
        return XCTFail("InsightPaneView boundary is missing")
    }

    let insightSource = source[insightRange.lowerBound..<summaryListRange.lowerBound]
    XCTAssertTrue(insightSource.contains("Text(\"Summary\").commandCenterEyebrow()"))
    XCTAssertTrue(insightSource.contains("Meeting summary will appear here after recording stops."))
    XCTAssertFalse(insightSource.contains("\"ACTIVE\""))
    XCTAssertFalse(insightSource.contains("\"RECORDED\""))
    XCTAssertFalse(insightSource.contains("\"Summary pending\""))
    XCTAssertFalse(insightSource.contains("\"Summary ready\""))
}
```

- [ ] **Step 2: Run the focused test to verify it fails**

Run:

```bash
swift test --filter MainWindowViewLayoutTests/testInsightPaneDoesNotRenderSummaryStatusBadges
```

Expected: FAIL because `InsightPaneView.phaseSummary` still contains the status chip row.

- [ ] **Step 3: Remove the chip row**

In `Sources/MeetingAgentApp/MainWindowView.swift`, update `phaseSummary` by deleting this block:

```swift
HStack {
    CommandCenterChip(title: isRecording ? "ACTIVE" : "RECORDED", tint: CommandCenterPalette.primary, filled: true)
    CommandCenterChip(title: summary == nil ? "Summary pending" : "Summary ready", tint: summary == nil ? CommandCenterPalette.warning : CommandCenterPalette.primary)
}
```

Do not change the `Summary` eyebrow, overview text, fallback copy, or `summaryPanel`.

- [ ] **Step 4: Run the focused test to verify it passes**

Run:

```bash
swift test --filter MainWindowViewLayoutTests/testInsightPaneDoesNotRenderSummaryStatusBadges
```

Expected: PASS.

- [ ] **Step 5: Run full verification**

Run:

```bash
make test
```

Expected: PASS with coverage checks satisfied.

- [ ] **Step 6: Commit the implementation**

Run:

```bash
git add Sources/MeetingAgentApp/MainWindowView.swift Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift docs/superpowers/specs/2026-04-29-remove-summary-status-badges-design.md docs/superpowers/plans/2026-04-29-remove-summary-status-badges.md
git commit -m "feat: remove summary status badges (#108)"
```

## Self-Review

- Spec coverage: the plan removes only summary-area chips, preserves overview and fallback copy, and leaves agenda/list artifact text untouched.
- Placeholder scan: no placeholders remain.
- Type consistency: all referenced files, view names, and test helper names exist in the current codebase.
