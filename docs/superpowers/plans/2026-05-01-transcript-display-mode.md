# Transcript Display Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a workspace transcript display mode for Both, Original, and Translation, defaulting to Both.

**Architecture:** Model the mode in core so display-state behavior is unit-testable, then thread it through the existing SwiftUI transcript view hierarchy. The option is local UI state in `TranscriptPaneView`; it does not affect transcription, translation scheduling, persistence, or exports.

**Tech Stack:** Swift 5.9, SwiftUI, XCTest, Swift Package Manager, project `make test` coverage command.

---

### Task 1: Core Display State

**Files:**
- Modify: `Sources/MeetingAgentCore/LiveMeetingCockpit.swift`
- Test: `Tests/MeetingAgentCoreTests/LiveCaptionDisplayStateTests.swift`

- [ ] **Step 1: Write failing tests**

Add tests for the new display mode behavior:

```swift
func testBothDisplayModeKeepsTranslatedState() {
    let turn = LiveCaptionTurn(
        sourceSegmentID: "segment-1",
        originalText: "We need a launch owner.",
        translatedText: "我们需要一位上线负责人。",
        sourceLocale: "en-US",
        targetLocale: "zh-CN",
        isFinal: true,
        translationHealth: .live
    )

    let state = LiveCaptionDisplayState(turn: turn, secondLanguageEnabled: true, displayMode: .both)

    XCTAssertEqual(state, .translated(primaryText: "我们需要一位上线负责人。", sourceText: "We need a launch owner."))
}

func testOriginalOnlyDisplayModeHidesTranslation() {
    let turn = LiveCaptionTurn(
        sourceSegmentID: "segment-1",
        originalText: "We need a launch owner.",
        translatedText: "我们需要一位上线负责人。",
        sourceLocale: "en-US",
        targetLocale: "zh-CN",
        isFinal: true,
        translationHealth: .live
    )

    let state = LiveCaptionDisplayState(turn: turn, secondLanguageEnabled: true, displayMode: .originalOnly)

    XCTAssertEqual(state, .originalOnly("We need a launch owner."))
}

func testTranslationOnlyDisplayModeUsesTranslatedTextAsSingleBlock() {
    let turn = LiveCaptionTurn(
        sourceSegmentID: "segment-1",
        originalText: "We need a launch owner.",
        translatedText: "我们需要一位上线负责人。",
        sourceLocale: "en-US",
        targetLocale: "zh-CN",
        isFinal: true,
        translationHealth: .live
    )

    let state = LiveCaptionDisplayState(turn: turn, secondLanguageEnabled: true, displayMode: .translationOnly)

    XCTAssertEqual(state, .originalOnly("我们需要一位上线负责人。"))
}

func testTranslationOnlyDisplayModeShowsPendingWhenTranslationIsMissing() {
    let turn = LiveCaptionTurn(
        sourceSegmentID: "segment-1",
        originalText: "We need a launch owner.",
        sourceLocale: "en-US",
        targetLocale: "zh-CN",
        isFinal: true,
        translationHealth: .pending
    )

    let state = LiveCaptionDisplayState(turn: turn, secondLanguageEnabled: true, displayMode: .translationOnly)

    XCTAssertEqual(state, .pending(sourceText: "We need a launch owner."))
}
```

- [ ] **Step 2: Run focused test to verify failure**

Run: `swift test --filter LiveCaptionDisplayStateTests`
Expected: fail because `LiveCaptionDisplayMode` and the new initializer argument do not exist.

- [ ] **Step 3: Implement core mode**

Add this enum before `LiveCaptionDisplayState`:

```swift
public enum LiveCaptionDisplayMode: String, Codable, CaseIterable, Equatable, Identifiable {
    case both
    case originalOnly
    case translationOnly

    public var id: String { rawValue }
}
```

Change `LiveCaptionDisplayState` to add a mode-aware initializer while keeping the existing initializer:

```swift
public init(turn: LiveCaptionTurn, secondLanguageEnabled: Bool) {
    self.init(turn: turn, secondLanguageEnabled: secondLanguageEnabled, displayMode: .both)
}

public init(turn: LiveCaptionTurn, secondLanguageEnabled: Bool, displayMode: LiveCaptionDisplayMode) {
    let originalText = turn.originalText.trimmingCharacters(in: .whitespacesAndNewlines)
    let translatedText = turn.translatedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    switch displayMode {
    case .originalOnly:
        self = .originalOnly(originalText)
    case .translationOnly:
        if !translatedText.isEmpty {
            self = .originalOnly(translatedText)
        } else {
            self = Self.translationFallbackState(originalText: originalText, health: turn.translationHealth)
        }
    case .both:
        guard secondLanguageEnabled else {
            self = .originalOnly(originalText)
            return
        }
        if !translatedText.isEmpty {
            self = .translated(primaryText: translatedText, sourceText: originalText)
            return
        }
        self = Self.translationFallbackState(originalText: originalText, health: turn.translationHealth)
    }
}
```

Add the helper:

```swift
private static func translationFallbackState(originalText: String, health: LivePipelineHealth) -> LiveCaptionDisplayState {
    switch health {
    case .failed(let message), .degraded(let message):
        return .failed(sourceText: originalText, message: message)
    case .pending:
        return .pending(sourceText: originalText)
    case .idle, .live:
        return .originalOnly(originalText)
    }
}
```

- [ ] **Step 4: Run focused test to verify pass**

Run: `swift test --filter LiveCaptionDisplayStateTests`
Expected: pass.

### Task 2: Workspace UI Control

**Files:**
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift`
- Test: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

- [ ] **Step 1: Write source-layout test**

Add a layout guard that checks the mode state, picker labels, and prop threading:

```swift
func testTranscriptPaneDefinesDisplayModePicker() throws {
    let source = try appSource(named: "MainWindowView.swift")

    XCTAssertTrue(source.contains("@State private var transcriptDisplayMode: LiveCaptionDisplayMode = .both"))
    XCTAssertTrue(source.contains("Picker(\"Transcript display\", selection: $transcriptDisplayMode)"))
    XCTAssertTrue(source.contains("Text(\"Both\").tag(LiveCaptionDisplayMode.both)"))
    XCTAssertTrue(source.contains("Text(\"Original\").tag(LiveCaptionDisplayMode.originalOnly)"))
    XCTAssertTrue(source.contains("Text(\"Translation\").tag(LiveCaptionDisplayMode.translationOnly)"))
    XCTAssertTrue(source.contains(".pickerStyle(.segmented)"))
    XCTAssertTrue(source.contains("displayMode: transcriptDisplayMode"))
    XCTAssertTrue(source.contains("displayMode: displayMode"))
    XCTAssertTrue(source.contains("LiveCaptionDisplayState(turn: turn, secondLanguageEnabled: secondLanguageEnabled, displayMode: displayMode)"))
}
```

- [ ] **Step 2: Run focused test to verify failure**

Run: `swift test --filter MainWindowViewLayoutTests/testTranscriptPaneDefinesDisplayModePicker`
Expected: fail because the picker and display-mode props do not exist.

- [ ] **Step 3: Add transcript pane state and picker**

In `TranscriptPaneView`, add:

```swift
@State private var transcriptDisplayMode: LiveCaptionDisplayMode = .both
```

Pass `displayMode: transcriptDisplayMode` into `UnifiedTranscriptView`.

In `UnifiedTranscriptView`, add `let displayMode: LiveCaptionDisplayMode`. Replace the header `HStack` with one that includes:

```swift
Picker("Transcript display", selection: $transcriptDisplayMode) {
    Text("Both").tag(LiveCaptionDisplayMode.both)
    Text("Original").tag(LiveCaptionDisplayMode.originalOnly)
    Text("Translation").tag(LiveCaptionDisplayMode.translationOnly)
}
.pickerStyle(.segmented)
.frame(width: 260)
```

The picker belongs in `TranscriptPaneView` because the state is owned there; pass the current value into `UnifiedTranscriptView`.

- [ ] **Step 4: Thread mode into transcript blocks**

Add `displayMode` properties to `UnifiedTranscriptView`, `BilingualTranscriptGroup`, and `BilingualTranscriptBlock`. Pass it through every initializer and update `BilingualTranscriptBlock` to call:

```swift
LiveCaptionDisplayState(turn: turn, secondLanguageEnabled: secondLanguageEnabled, displayMode: displayMode)
```

- [ ] **Step 5: Run focused layout test**

Run: `swift test --filter MainWindowViewLayoutTests/testTranscriptPaneDefinesDisplayModePicker`
Expected: pass.

### Task 3: Verification and Commit

**Files:**
- Modify: `Sources/MeetingAgentCore/LiveMeetingCockpit.swift`
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift`
- Modify: `Tests/MeetingAgentCoreTests/LiveCaptionDisplayStateTests.swift`
- Modify: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`
- Create: `docs/superpowers/specs/2026-05-01-transcript-display-mode-design.md`
- Create: `docs/superpowers/plans/2026-05-01-transcript-display-mode.md`

- [ ] **Step 1: Run focused tests**

Run these serially:

```bash
swift test --filter LiveCaptionDisplayStateTests
swift test --filter MainWindowViewLayoutTests/testTranscriptPaneDefinesDisplayModePicker
```

Expected: both pass.

- [ ] **Step 2: Run required verification**

Run: `make test`
Expected: pass with coverage gate satisfied.

- [ ] **Step 3: Commit implementation**

Run:

```bash
git add Sources/MeetingAgentCore/LiveMeetingCockpit.swift Sources/MeetingAgentApp/MainWindowView.swift Tests/MeetingAgentCoreTests/LiveCaptionDisplayStateTests.swift Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift docs/superpowers/specs/2026-05-01-transcript-display-mode-design.md docs/superpowers/plans/2026-05-01-transcript-display-mode.md
git commit -m "feat: add transcript display modes (#126)"
```

Expected: commit succeeds.

## Self-Review

- Spec coverage: The plan adds all three display modes, defaults to both, keeps behavior display-only, and adds tests.
- Placeholder scan: No placeholder instructions remain.
- Type consistency: `LiveCaptionDisplayMode`, `displayMode`, and `LiveCaptionDisplayState` initializer names are consistent across tasks.
