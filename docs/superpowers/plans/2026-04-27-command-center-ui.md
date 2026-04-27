# Command Center UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restyle the macOS prototype into the approved dark live-meeting command center for issue #22.

**Architecture:** Keep `MeetingAgentViewModel` and all core behavior unchanged. Implement the visual language in a dedicated app-level design system file, then consume those named styles from the main window and settings views. Add layout tests that source-inspect for the key command-center structure and the shared design system.

**Tech Stack:** Swift 5.9, SwiftUI, XCTest, Swift Package Manager, macOS 14.2.

---

## File Structure

- Create `Sources/MeetingAgentApp/CommandCenterDesignSystem.swift`: own the shared palette, panel modifier, chip view, typography helpers, and button style so the visual system is not duplicated across screens.
- Modify `Sources/MeetingAgentApp/MainWindowView.swift`: replace the plain split-detail presentation with a dark sidebar, transcript pane, right insight pane, status chips, and action controls using existing callbacks and the shared design system.
- Modify `Sources/MeetingAgentApp/SettingsView.swift`: keep the existing form fields and bindings, but wrap them in dark grouped panels and compact button styling from the shared design system.
- Modify `Tests/MeetingAgentCoreTests/SettingsViewLayoutTests.swift`: add source-inspection assertions for the new command-center UI markers.

## Task 1: Lock In UI Structure Expectations

**Files:**
- Modify: `Tests/MeetingAgentCoreTests/SettingsViewLayoutTests.swift`

- [ ] **Step 1: Add a source-inspection test for the main command-center surface**

Add this XCTest method to `SettingsViewLayoutTests`:

```swift
func testMainWindowUsesCommandCenterStyling() throws {
    let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/MeetingAgentApp/MainWindowView.swift")
    let source = try String(contentsOf: sourceURL)

    XCTAssertTrue(source.contains("CommandCenterPalette"))
    XCTAssertTrue(source.contains("CommandCenterActionButtonStyle"))
    XCTAssertTrue(source.contains("MeetingCommandCenterView"))
    XCTAssertTrue(source.contains("TranscriptPaneView"))
    XCTAssertTrue(source.contains("InsightPaneView"))
    XCTAssertTrue(source.contains("Live Translation"))
    XCTAssertTrue(source.contains("Send to call"))
}
```

- [ ] **Step 2: Add a source-inspection test for dark settings panels**

Add this XCTest method to `SettingsViewLayoutTests`:

```swift
func testSettingsViewUsesCommandCenterPanels() throws {
    let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/MeetingAgentApp/SettingsView.swift")
    let source = try String(contentsOf: sourceURL)

    XCTAssertTrue(source.contains("SettingsCommandCenterPanel"))
    XCTAssertTrue(source.contains("CommandCenterPanel"))
    XCTAssertTrue(source.contains("CommandCenterActionButtonStyle"))
}
```

- [ ] **Step 3: Add a source-inspection test for the shared design system**

Add this XCTest method to `SettingsViewLayoutTests`:

```swift
func testCommandCenterDesignSystemCentralizesSharedStyles() throws {
    let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/MeetingAgentApp/CommandCenterDesignSystem.swift")
    let source = try String(contentsOf: sourceURL)

    XCTAssertTrue(source.contains("enum CommandCenterPalette"))
    XCTAssertTrue(source.contains("struct CommandCenterPanel"))
    XCTAssertTrue(source.contains("struct CommandCenterChip"))
    XCTAssertTrue(source.contains("struct CommandCenterActionButtonStyle"))
    XCTAssertTrue(source.contains("extension Text"))
}
```

- [ ] **Step 4: Run the focused layout tests and confirm they fail before implementation**

Run:

```bash
swift test --filter SettingsViewLayoutTests
```

Expected: failures for the newly added command-center markers until the view code is updated.

## Task 2: Add Shared Command-Center Design System

**Files:**
- Create: `Sources/MeetingAgentApp/CommandCenterDesignSystem.swift`

- [ ] **Step 1: Add centralized palette, panel, chip, text, and button abstractions**

Create `CommandCenterDesignSystem.swift` with reusable SwiftUI styles named `CommandCenterPalette`, `CommandCenterPanel`, `CommandCenterChip`, `CommandCenterActionButtonStyle`, and `extension Text` helpers. These helpers should be app-internal and used by both main and settings views.

## Task 3: Restyle the Main Meeting Window

**Files:**
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift`

- [ ] **Step 1: Replace the default sidebar styling**

Update the `NavigationSplitView` sidebar so the meeting list and settings button sit on a dark background. Keep the same selection binding and `showSettings` behavior. Meeting rows should show name and date, with muted secondary text and a subtle selected settings background.

- [ ] **Step 2: Replace `MeetingDetailView` body with a command-center shell**

When a meeting is selected, render a new private `MeetingCommandCenterView` that receives all current `MeetingDetailView` inputs and callbacks. When no meeting is selected, render a dark empty panel with the existing no-meeting message.

- [ ] **Step 3: Add transcript and insight panes**

Create private subviews named `TranscriptPaneView` and `InsightPaneView`. `TranscriptPaneView` owns the meeting header, progress bar, metadata chips, transcript body, live translation turns, and bottom composer row. `InsightPaneView` owns the phase summary, status chips, export controls, and summary sections.

- [ ] **Step 4: Preserve all existing actions**

Map the current buttons to the same closures: stop recording, retry transcription, start live translation, stop live translation, copy summary, export transcript, export meeting data, and export readiness report. Disable controls with the same conditions as before.

## Task 4: Restyle Settings

**Files:**
- Modify: `Sources/MeetingAgentApp/SettingsView.swift`

- [ ] **Step 1: Replace the plain `Form` surface**

Keep every existing picker, secure field, conditional section, binding, and `.onChange` handler. Wrap groups in dark panels with headings matching the current sections: Speech, Transcription Chain, Translation Chain, OpenRouter, Deepgram, Live Translation, and validation/actions.

- [ ] **Step 2: Preserve settings tests**

Ensure `Picker("Source Locale"`, `Picker("Target Locale"`, all provider/model pickers, secure fields, `Button("Save")`, `Button("Reset")`, and `.disabled(isRecording)` remain present in source so existing layout tests continue to protect behavior.

## Task 5: Verification and Commit

**Files:**
- Create: `Sources/MeetingAgentApp/CommandCenterDesignSystem.swift`
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift`
- Modify: `Sources/MeetingAgentApp/SettingsView.swift`
- Modify: `Tests/MeetingAgentCoreTests/SettingsViewLayoutTests.swift`

- [ ] **Step 1: Run focused tests**

Run:

```bash
swift test --filter SettingsViewLayoutTests
```

Expected: pass.

- [ ] **Step 2: Run app build**

Run:

```bash
swift build --product MeetingAgentApp
```

Expected: build complete with no Swift compiler errors.

- [ ] **Step 3: Run required verification**

Run:

```bash
make test
```

Expected: pass.

- [ ] **Step 4: Commit implementation**

Run:

```bash
git add Sources/MeetingAgentApp/CommandCenterDesignSystem.swift Sources/MeetingAgentApp/MainWindowView.swift Sources/MeetingAgentApp/SettingsView.swift Tests/MeetingAgentCoreTests/SettingsViewLayoutTests.swift docs/superpowers/plans/2026-04-27-command-center-ui.md docs/superpowers/specs/2026-04-27-command-center-ui-design.md
git commit -m "feat: add command center UI (#22)"
```
