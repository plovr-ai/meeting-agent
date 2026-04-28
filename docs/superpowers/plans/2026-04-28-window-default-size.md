# Window Default Size Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Start the macOS app at the current screen's visible size with a 1400-point width cap, and make the meetings sidebar wider.

**Architecture:** Keep sizing logic at the SwiftUI app boundary. Add a small pure helper for the default size calculation, apply it through `WindowGroup.defaultSize`, and constrain the existing `NavigationSplitView` sidebar root with wider min/ideal widths.

**Tech Stack:** Swift 5.9, SwiftUI, AppKit `NSScreen`, XCTest source-layout checks.

---

### Task 1: Default Window Size

**Files:**
- Modify: `Sources/MeetingAgentApp/MeetingAgentApp.swift`
- Test: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

- [ ] **Step 1: Write the failing tests**

Add tests that read `MeetingAgentApp.swift` and verify the app has a sizing helper, caps width at 1400, uses the visible screen frame, and applies `.defaultSize(width:height:)`.

```swift
func testAppDefaultWindowSizeUsesVisibleScreenWithWidthCap() throws {
    let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/MeetingAgentApp/MeetingAgentApp.swift")
    let source = try String(contentsOf: sourceURL)

    XCTAssertTrue(source.contains("DefaultWindowSizing.mainWindowSize"))
    XCTAssertTrue(source.contains("NSScreen.main?.visibleFrame.size"))
    XCTAssertTrue(source.contains("min(screenSize.width, 1_400)"))
    XCTAssertTrue(source.contains(".defaultSize(width: defaultWindowSize.width, height: defaultWindowSize.height)"))
}
```

- [ ] **Step 2: Run the focused test to verify it fails**

Run: `swift test --filter MainWindowViewLayoutTests/testAppDefaultWindowSizeUsesVisibleScreenWithWidthCap`

Expected: FAIL because the helper and `.defaultSize` are not implemented yet.

- [ ] **Step 3: Implement the sizing helper and scene default**

In `MeetingAgentApp.swift`, import AppKit, add a computed default size in the app, and define a small helper:

```swift
import AppKit
import MeetingAgentCore
import SwiftUI

@main
struct MeetingAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = MeetingAgentViewModel()

    private var defaultWindowSize: CGSize {
        DefaultWindowSizing.mainWindowSize()
    }

    var body: some Scene {
        WindowGroup("Meeting Agent") {
            MainWindowView(viewModel: viewModel)
                .frame(minWidth: 900, minHeight: 600)
                .commandCenterAppTheme()
                .onAppear {
                    appDelegate.viewModel = viewModel
                }
                .task {
                    try? viewModel.loadMeetings()
                    var lastProcessPoll = Date.distantPast
                    while !Task.isCancelled {
                        if Date().timeIntervalSince(lastProcessPoll) >= 3,
                           let candidate = viewModel.pollForMeetingCandidates() {
                            lastProcessPoll = Date()
                            appDelegate.notifyMeetingDetected(candidate)
                        }
                        viewModel.drainRecordingFrames()
                        try? await Task.sleep(nanoseconds: 250_000_000)
                    }
                }
        }
        .defaultSize(width: defaultWindowSize.width, height: defaultWindowSize.height)
    }
}

enum DefaultWindowSizing {
    private static let fallbackSize = CGSize(width: 1_200, height: 800)

    static func mainWindowSize(screenSize: CGSize? = NSScreen.main?.visibleFrame.size) -> CGSize {
        guard let screenSize else { return fallbackSize }

        return CGSize(
            width: min(screenSize.width, 1_400),
            height: screenSize.height
        )
    }
}
```

- [ ] **Step 4: Run focused test to verify it passes**

Run: `swift test --filter MainWindowViewLayoutTests/testAppDefaultWindowSizeUsesVisibleScreenWithWidthCap`

Expected: PASS.

### Task 2: Sidebar Width

**Files:**
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift`
- Test: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

- [ ] **Step 1: Write the failing test**

Add a source-layout test that verifies the sidebar root has wider min and ideal width constraints.

```swift
func testMeetingsSidebarUsesWiderDefaultWidth() throws {
    let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/MeetingAgentApp/MainWindowView.swift")
    let source = try String(contentsOf: sourceURL)

    XCTAssertTrue(source.contains(".frame(minWidth: 260, idealWidth: 300)"))
}
```

- [ ] **Step 2: Run focused test to verify it fails**

Run: `swift test --filter MainWindowViewLayoutTests/testMeetingsSidebarUsesWiderDefaultWidth`

Expected: FAIL because the sidebar has no explicit width constraint yet.

- [ ] **Step 3: Add the sidebar width constraint**

In `MainWindowView.swift`, apply this modifier to the sidebar root `VStack`, after its background modifier:

```swift
.frame(minWidth: 260, idealWidth: 300)
```

- [ ] **Step 4: Run focused test to verify it passes**

Run: `swift test --filter MainWindowViewLayoutTests/testMeetingsSidebarUsesWiderDefaultWidth`

Expected: PASS.

### Task 3: Full Verification and Commit

**Files:**
- Modify: `Sources/MeetingAgentApp/MeetingAgentApp.swift`
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift`
- Modify: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`
- Modify: `docs/superpowers/plans/2026-04-28-window-default-size.md`

- [ ] **Step 1: Run app build**

Run: `swift build --product MeetingAgentApp`

Expected: Build succeeds.

- [ ] **Step 2: Run unit test entrypoint**

Run: `make test`

Expected: Tests pass.

- [ ] **Step 3: Commit implementation**

Run:

```bash
git add Sources/MeetingAgentApp/MeetingAgentApp.swift Sources/MeetingAgentApp/MainWindowView.swift Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift docs/superpowers/plans/2026-04-28-window-default-size.md
git commit -m "feat: size main window for screen on launch (#31)"
```

Expected: Commit succeeds.

