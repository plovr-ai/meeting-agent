# Hide Caption Edit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hide the per-caption pencil correction UI while preserving speaker-name editing.

**Architecture:** This is a view-layer change in `MainWindowView.swift`. Remove the caption edit closure path from the transcript view hierarchy and update source-layout tests to guard against reintroducing the caption correction UI.

**Tech Stack:** Swift 5.9, SwiftUI, XCTest source-layout tests, Swift Package Manager.

---

### Task 1: Update Layout Regression Tests

**Files:**
- Modify: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

- [ ] **Step 1: Replace the correction-control test with a hidden-caption-edit regression**

Change `testLiveCaptionsExposeCorrectionControls` to assert speaker editing remains and caption correction UI is absent:

```swift
func testLiveCaptionsHideCaptionCorrectionWhileKeepingSpeakerEdit() throws {
    let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/MeetingAgentApp/MainWindowView.swift")
    let source = try String(contentsOf: sourceURL)

    XCTAssertTrue(source.contains("updateSpeakerLabel"))
    XCTAssertTrue(source.contains("CaptionEditSheet"))
    XCTAssertTrue(source.contains("Menu {"))
    XCTAssertTrue(source.contains("Button(\"Edit name\")"))
    XCTAssertTrue(source.contains("Image(systemName: \"chevron.down\")"))
    XCTAssertTrue(source.contains("Save Speaker"))

    XCTAssertFalse(source.contains("updateTranscriptSegmentText"))
    XCTAssertFalse(source.contains("Correct Caption"))
    XCTAssertFalse(source.contains("Save Caption"))
    XCTAssertFalse(source.contains("Image(systemName: \"pencil\")"))
    XCTAssertFalse(source.contains("person.crop.circle.badge.pencil"))
}
```

- [ ] **Step 2: Tighten the quiet-control test**

In `testUnifiedTranscriptPreservesFallbackAndQuietCorrectionControls`, remove the assertion that expects `Image(systemName: "pencil")` and replace it with an assertion that it is absent:

```swift
XCTAssertFalse(source.contains("Image(systemName: \"pencil\")"))
```

- [ ] **Step 3: Run the focused test and confirm it fails before implementation**

Run: `swift test --filter MainWindowViewLayoutTests/testLiveCaptionsHideCaptionCorrectionWhileKeepingSpeakerEdit`

Expected: FAIL because `MainWindowView.swift` still contains caption correction wiring and the pencil image.

### Task 2: Remove Caption Correction UI Wiring

**Files:**
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift`

- [ ] **Step 1: Remove transcript edit state and sheet wiring**

In `TranscriptPaneView`, remove:

```swift
@State private var transcriptEditTarget: LiveCaptionTurn?
@State private var transcriptTextDraft = ""
```

Remove the `editText` argument passed to `UnifiedTranscriptView`:

```swift
editText: { turn in
    transcriptTextDraft = turn.originalText
    transcriptEditTarget = turn
}
```

Remove the `transcriptEditTarget` sheet:

```swift
.sheet(item: $transcriptEditTarget) { turn in
    CaptionEditSheet(
        title: "Correct Caption",
        text: $transcriptTextDraft,
        saveTitle: "Save Caption",
        save: {
            updateTranscriptSegmentText(turn.id, transcriptTextDraft)
            transcriptEditTarget = nil
        },
        cancel: { transcriptEditTarget = nil }
    )
}
```

- [ ] **Step 2: Remove the edit closure from transcript views**

Remove `editText` from `UnifiedTranscriptView`, `BilingualTranscriptGroup`, and `BilingualTranscriptBlock`. `BilingualTranscriptBlock` should render only `transcriptText`:

```swift
var body: some View {
    transcriptText
        .frame(maxWidth: .infinity, alignment: .leading)
}
```

Keep `editSpeaker` and the `Button("Edit name")` menu unchanged.

- [ ] **Step 3: Run focused layout tests**

Run: `swift test --filter MainWindowViewLayoutTests`

Expected: PASS.

### Task 3: Full Verification and Commit

**Files:**
- Verify: `Sources/MeetingAgentApp/MainWindowView.swift`
- Verify: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

- [ ] **Step 1: Run build and tests**

Run:

```bash
swift build --product MeetingAgentApp
make test
```

Expected: both PASS.

- [ ] **Step 2: Commit implementation**

Run:

```bash
git add Sources/MeetingAgentApp/MainWindowView.swift Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift docs/superpowers/specs/2026-04-29-hide-caption-edit-design.md docs/superpowers/plans/2026-04-29-hide-caption-edit.md
git commit -m "feat: hide caption edit control (#80)"
```

Expected: one commit containing the UI change, regression tests, spec, and plan.

## Plan Self-Review

- Spec coverage: the plan removes only per-caption editing and preserves speaker editing.
- Placeholder scan: no TBD, TODO, or deferred steps remain.
- Type consistency: all named views and tests match the current source layout.

