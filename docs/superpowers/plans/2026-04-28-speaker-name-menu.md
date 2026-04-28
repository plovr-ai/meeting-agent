# Speaker Name Menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the persistent speaker edit icon in transcript rows with a compact speaker-label menu containing only `Edit name`.

**Architecture:** Keep the behavior inside `BilingualTranscriptRow` in `MainWindowView.swift`. Rows with editable speaker identifiers render a `Menu` whose label is the current speaker name plus a chevron; rows without editable identifiers keep plain text. Existing sheet state and `updateSpeakerLabel` plumbing stay unchanged.

**Tech Stack:** Swift 5.9, SwiftUI, XCTest source-layout regression tests, Swift Package Manager via `make test`.

---

### Task 1: Add Layout Regression Coverage

**Files:**
- Modify: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

- [ ] **Step 1: Update the speaker correction layout test**

Replace the speaker-icon assertion in `testLiveCaptionsExposeCorrectionControls` with assertions for the new menu contract:

```swift
XCTAssertTrue(source.contains("Menu {"))
XCTAssertTrue(source.contains("Button(\"Edit name\")"))
XCTAssertTrue(source.contains("Image(systemName: \"chevron.down\")"))
XCTAssertFalse(source.contains("person.crop.circle.badge.pencil"))
```

Keep the existing assertions for `updateSpeakerLabel`, `updateTranscriptSegmentText`, `CaptionEditSheet`, `Image(systemName: \"pencil\")`, `Correct Caption`, `Save Speaker`, and `Save Caption`.

- [ ] **Step 2: Run the focused test and verify it fails**

Run: `swift test --filter MainWindowViewLayoutTests/testLiveCaptionsExposeCorrectionControls`

Expected: FAIL because `MainWindowView.swift` still contains `person.crop.circle.badge.pencil` and does not contain `Button("Edit name")`.

### Task 2: Replace Speaker Edit Icon With Menu

**Files:**
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift`

- [ ] **Step 1: Update `BilingualTranscriptRow` speaker header**

Replace the current speaker `Text` plus speaker edit `Button` block with a menu helper:

```swift
speakerLabel
Spacer()
if let editText {
    Button {
        editText()
    } label: {
        Image(systemName: "pencil")
    }
    .buttonStyle(CommandCenterIconButtonStyle())
    .help("Correct caption")
}
```

Add this private helper inside `BilingualTranscriptRow`:

```swift
private var speakerDisplayName: String {
    turn.speaker.label ?? turn.speaker.identifier ?? "Speaker"
}

@ViewBuilder
private var speakerLabel: some View {
    if let editSpeaker {
        Menu {
            Button("Edit name") {
                editSpeaker()
            }
        } label: {
            HStack(spacing: 4) {
                Text(speakerDisplayName)
                    .commandCenterMono()
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(CommandCenterPalette.secondaryText)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .help("Edit speaker name")
    } else {
        Text(speakerDisplayName)
            .commandCenterMono()
    }
}
```

- [ ] **Step 2: Run the focused layout test and verify it passes**

Run: `swift test --filter MainWindowViewLayoutTests/testLiveCaptionsExposeCorrectionControls`

Expected: PASS.

### Task 3: Final Verification and Commit

**Files:**
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift`
- Modify: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

- [ ] **Step 1: Run full local verification**

Run: `make test`

Expected: PASS with the repository coverage gate satisfied.

- [ ] **Step 2: Commit implementation**

Run:

```bash
git add Sources/MeetingAgentApp/MainWindowView.swift Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift docs/superpowers/plans/2026-04-28-speaker-name-menu.md
git commit -m "feat: move speaker editing into name menu (#27)"
```

Expected: commit succeeds on `feat/issue-27-user-name-editing`.

## Self-Review

- Spec coverage: Task 2 implements `User A` as a compact menu, `Edit name` as the only action, existing save plumbing, and plain text for non-editable speaker rows. Task 1 covers removal of the old icon and preservation of caption correction.
- Placeholder scan: no unresolved placeholders or deferred requirements.
- Type consistency: plan uses existing `BilingualTranscriptRow`, `LiveCaptionTurn`, `editSpeaker`, `editText`, `CommandCenterPalette`, and `CommandCenterIconButtonStyle` names from `MainWindowView.swift`.
