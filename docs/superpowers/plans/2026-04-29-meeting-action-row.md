# Meeting Action Row Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Consolidate meeting workspace actions into the top Back row and move export/debug actions behind an overflow menu.

**Architecture:** Keep the existing `MeetingCommandCenterView` as the owner of page-level workspace actions. Move recording, retry transcription, and export callbacks up to that view's top command row, then simplify `TranscriptPaneView` and `InsightPaneView` so they only render transcript and insight content.

**Tech Stack:** Swift 5.9, SwiftUI, XCTest source-layout tests, macOS 14.2+ Swift Package.

---

### Task 1: Add Layout Regression Coverage

**Files:**
- Modify: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

- [ ] **Step 1: Replace the old recording/retry row test**

Replace `testRecordingAndRetryButtonsShareActionRow` with a test that reads `MainWindowView.swift`, slices `MeetingCommandCenterView`, and asserts the command row contains `Label("Back", systemImage: "chevron.left")`, `Label("Stop Recording", systemImage: "stop.fill")`, `Label("Record", systemImage: "record.circle")`, `Menu`, and `Image(systemName: "ellipsis.circle")`.

- [ ] **Step 2: Add assertions for removed visible surfaces**

In the same test or a second focused test, assert that `TranscriptPaneView` no longer contains `private var recordingActions: some View`, and that `InsightPaneView` no longer contains `private var exports: some View` or `Text("Exports")`.

- [ ] **Step 3: Add assertions for overflow menu actions**

Assert that `MeetingCommandCenterView` contains menu labels for `Copy Summary`, `Export Transcript`, `Export Meeting JSON`, `Export SRT`, `Export VTT`, and `Retry Transcription`, plus disabled conditions for summary, transcript, retry, and recording-sensitive actions.

- [ ] **Step 4: Run focused test and confirm failure**

Run:

```bash
swift test --filter MainWindowViewLayoutTests/testMeetingWorkspaceConsolidatesActionsIntoTopRow
```

Expected: fails until `MainWindowView.swift` is updated.

### Task 2: Move Actions Into Top Command Row

**Files:**
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift`

- [ ] **Step 1: Extend `MeetingCommandCenterView` top row**

Change the first `HStack` in `MeetingCommandCenterView.body` so it calls a helper such as `topCommandRow`.

The helper should render:

```swift
Button(action: backToMeetings) {
    Label("Back", systemImage: "chevron.left")
}
.buttonStyle(.plain)
.font(CommandCenterTypography.button)
.foregroundStyle(CommandCenterPalette.primary)

Spacer()

recordingCommand
overflowMenu
```

- [ ] **Step 2: Add `recordingCommand`**

Add a `@ViewBuilder private var recordingCommand: some View` inside `MeetingCommandCenterView`.

When `isRecording` is true, render:

```swift
Button {
    stopRecording()
} label: {
    Label("Stop Recording", systemImage: "stop.fill")
}
.buttonStyle(CommandCenterActionButtonStyle(variant: .danger))
```

When `isRecording` is false, render:

```swift
Button {
} label: {
    Label("Record", systemImage: "record.circle")
}
.buttonStyle(CommandCenterActionButtonStyle())
.disabled(true)
.help("Recording can be started from an agenda item.")
```

- [ ] **Step 3: Add `overflowMenu`**

Add a `private var overflowMenu: some View` using `Menu`.

The menu content should call existing closures:

```swift
Button { copySummary() } label: {
    Label("Copy Summary", systemImage: "doc.on.clipboard")
}
.disabled(isRecording || meeting.summaryURL == nil)

Button { exportTranscript() } label: {
    Label("Export Transcript", systemImage: "doc.text")
}
.disabled(isRecording || meeting.transcriptURL == nil)

Button { exportMeetingData() } label: {
    Label("Export Meeting JSON", systemImage: "curlybraces")
}

Button { exportSRT() } label: {
    Label("Export SRT", systemImage: "captions.bubble")
}

Button { exportVTT() } label: {
    Label("Export VTT", systemImage: "captions.bubble")
}

Divider()

Button { retryTranscription() } label: {
    Label("Retry Transcription", systemImage: "arrow.clockwise")
}
.disabled(isRecording || meeting.audioURL == nil)
```

Use this menu label:

```swift
Image(systemName: "ellipsis.circle")
    .accessibilityLabel("Meeting actions")
```

Apply `CommandCenterIconButtonStyle()` and `.help("Meeting actions")`.

- [ ] **Step 4: Remove now-unused child callbacks**

Stop passing `stopRecording` and `retryTranscription` into `TranscriptPaneView`. Remove those stored properties from `TranscriptPaneView`.

Stop passing export closures into `InsightPaneView`. Keep `copySummary` only if the summary panel still needs it; otherwise remove it too.

- [ ] **Step 5: Remove old visible action blocks**

Delete `recordingActions` from `TranscriptPaneView` and remove the `recordingActions` call from the transcript scroll content.

Delete `exports` from `InsightPaneView` and remove the `exports` call from its scroll content.

### Task 3: Verify and Commit Implementation

**Files:**
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift`
- Modify: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

- [ ] **Step 1: Run focused layout test**

Run:

```bash
swift test --filter MainWindowViewLayoutTests/testMeetingWorkspaceConsolidatesActionsIntoTopRow
```

Expected: passes.

- [ ] **Step 2: Build app product**

Run:

```bash
swift build --product MeetingAgentApp
```

Expected: exits 0.

- [ ] **Step 3: Run required unit verification**

Run:

```bash
make test
```

Expected: exits 0 and coverage threshold passes.

- [ ] **Step 4: Commit implementation**

Run:

```bash
git add Sources/MeetingAgentApp/MainWindowView.swift Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift
git commit -m "feat: consolidate meeting workspace actions (#103)"
```
