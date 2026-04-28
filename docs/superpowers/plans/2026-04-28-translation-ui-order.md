# Translation UI Order Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render original/source captions above translated captions in the live bilingual transcript UI for issue #42.

**Architecture:** Keep translation state and stored transcript semantics unchanged. Change only the SwiftUI row rendering order for translated display state and add a source-layout regression test that fails on the current order.

**Tech Stack:** Swift 5.9, SwiftUI, XCTest, Swift Package Manager via `make test`.

---

## File Structure

- Modify `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`: add a regression test that inspects the translated branch in `BilingualTranscriptRow`.
- Modify `Sources/MeetingAgentApp/MainWindowView.swift`: swap the two rendered `Text` blocks in the `.translated` case so `sourceText` renders first and `primaryText` renders second.

### Task 1: Add Regression Test

**Files:**
- Modify: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

- [ ] **Step 1: Add the failing source-layout test**

Add this test near `testTranscriptPaneUsesUnifiedTranscriptSurface`:

```swift
    func testTranslatedTranscriptRowsRenderSourceBeforeTranslation() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MeetingAgentApp/MainWindowView.swift")
        let source = try String(contentsOf: sourceURL)

        guard let translatedCaseRange = source.range(of: "case .translated(let primaryText, let sourceText):") else {
            return XCTFail("Translated transcript branch is missing")
        }
        guard let originalOnlyRange = source.range(of: "case .originalOnly", range: translatedCaseRange.upperBound..<source.endIndex) else {
            return XCTFail("Translated transcript branch end is missing")
        }

        let translatedBranch = source[translatedCaseRange.lowerBound..<originalOnlyRange.lowerBound]
        guard let sourceTextRange = translatedBranch.range(of: "Text(sourceText)") else {
            return XCTFail("Translated transcript branch does not render sourceText")
        }
        guard let primaryTextRange = translatedBranch.range(of: "Text(primaryText)") else {
            return XCTFail("Translated transcript branch does not render primaryText")
        }

        XCTAssertLessThan(sourceTextRange.lowerBound, primaryTextRange.lowerBound)
    }
```

- [ ] **Step 2: Run the focused test and confirm it fails**

Run:

```bash
swift test --filter MainWindowViewLayoutTests/testTranslatedTranscriptRowsRenderSourceBeforeTranslation
```

Expected: FAIL because the current translated branch renders `Text(primaryText)` before `Text(sourceText)`.

### Task 2: Swap Render Order

**Files:**
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift`

- [ ] **Step 1: Update the translated branch**

Replace the `.translated` case body with:

```swift
            case .translated(let primaryText, let sourceText):
                Text(sourceText)
                    .font(CommandCenterTypography.transcript)
                    .lineSpacing(5)
                    .foregroundStyle(CommandCenterPalette.text)
                    .textSelection(.enabled)
                Text(primaryText)
                    .font(CommandCenterTypography.secondaryBody)
                    .lineSpacing(4)
                    .foregroundStyle(CommandCenterPalette.secondaryText)
                    .textSelection(.enabled)
```

- [ ] **Step 2: Run the focused test and confirm it passes**

Run:

```bash
swift test --filter MainWindowViewLayoutTests/testTranslatedTranscriptRowsRenderSourceBeforeTranslation
```

Expected: PASS.

### Task 3: Verify And Commit

**Files:**
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift`
- Modify: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

- [ ] **Step 1: Run full local verification**

Run:

```bash
make test
```

Expected: PASS.

- [ ] **Step 2: Commit implementation**

Run:

```bash
git add Sources/MeetingAgentApp/MainWindowView.swift Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift
git commit -m "fix: show source captions before translations (#42)"
```

## Self-Review

- Spec coverage: the plan changes only the live translated row order, leaves pending and failed states unchanged, and adds a focused regression test.
- Placeholder scan: no placeholders remain.
- Type consistency: the plan uses existing `primaryText` and `sourceText` bindings from `LiveCaptionDisplayState`.

