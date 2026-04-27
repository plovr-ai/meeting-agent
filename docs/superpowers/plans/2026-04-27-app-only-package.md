# App-Only Package Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the `CoreAudioTapProbe` CLI mode while preserving the macOS app and shared core library.

**Architecture:** Delete the SwiftPM CLI product/target and CLI-only source while leaving reusable meeting capture, STT, recording, translation, and summary types in `MeetingAgentCore`. Keep tests focused on current app/core behavior and add a manifest regression test to prevent accidental CLI reintroduction.

**Tech Stack:** Swift Package Manager, Swift 5.9, XCTest, macOS 14.2+.

---

### Task 1: Add Manifest Regression Test

**Files:**
- Modify: `Tests/MeetingAgentCoreTests/ScaffoldTests.swift`

- [ ] **Step 1: Write the failing test**

Add this test to `ScaffoldTests`:

```swift
func testPackageManifestDoesNotExposeCoreAudioTapProbe() throws {
    let manifestURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Package.swift")
    let manifest = try String(contentsOf: manifestURL)

    XCTAssertFalse(manifest.contains("CoreAudioTapProbe"))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ScaffoldTests/testPackageManifestDoesNotExposeCoreAudioTapProbe`

Expected: FAIL because `Package.swift` still contains `CoreAudioTapProbe`.

### Task 2: Remove CLI Package Surface

**Files:**
- Modify: `Package.swift`
- Delete: `Sources/CoreAudioTapProbe/ProbeMain.swift`
- Delete: `Sources/CoreAudioTapProbe/Info.plist`

- [ ] **Step 1: Remove the CLI product and target**

Update `Package.swift` so the `products` and `targets` sections only include:

```swift
products: [
    .library(name: "MeetingAgentCore", targets: ["MeetingAgentCore"]),
    .executable(name: "MeetingAgentApp", targets: ["MeetingAgentApp"])
],
targets: [
    .target(
        name: "MeetingAgentCore"
    ),
    .executableTarget(
        name: "MeetingAgentApp",
        dependencies: ["MeetingAgentCore"]
    ),
    .testTarget(
        name: "MeetingAgentCoreTests",
        dependencies: ["MeetingAgentCore"]
    )
]
```

- [ ] **Step 2: Delete CLI source files**

Remove the `Sources/CoreAudioTapProbe/` directory.

- [ ] **Step 3: Run the manifest test**

Run: `swift test --filter ScaffoldTests/testPackageManifestDoesNotExposeCoreAudioTapProbe`

Expected: PASS.

### Task 3: Remove CLI-Only Parser

**Files:**
- Delete: `Sources/MeetingAgentCore/ProbeOptions.swift`
- Delete: `Sources/MeetingAgentCore/RecordingOutput.swift`
- Create: `Sources/MeetingAgentCore/TranscriptFileWriter.swift`
- Rename: `Tests/MeetingAgentCoreTests/RecordingOutputTests.swift` to `Tests/MeetingAgentCoreTests/TranscriptFileWriterTests.swift`

- [ ] **Step 1: Remove parser tests**

Delete tests in `RecordingOutputTests` that instantiate `ProbeOptions` or directly exercise CLI `.record` output naming. Keep tests that directly exercise `TranscriptFileWriter`.

- [ ] **Step 2: Delete `ProbeOptions.swift`**

Move `TranscriptFileWriter` from `Sources/MeetingAgentCore/RecordingOutput.swift` to `Sources/MeetingAgentCore/TranscriptFileWriter.swift`, then remove `Sources/MeetingAgentCore/ProbeOptions.swift` and `Sources/MeetingAgentCore/RecordingOutput.swift`.

- [ ] **Step 3: Run focused tests**

Run: `swift test --filter TranscriptFileWriterTests`

Expected: PASS.

### Task 4: Update Current Docs

**Files:**
- Modify: `AGENTS.md`

- [ ] **Step 1: Rewrite current command and layout references**

Remove `CoreAudioTapProbe` from the current project overview, repository layout, and common command list. Keep app and `swift test` / `swift build --product MeetingAgentApp` commands.

- [ ] **Step 2: Remove CLI runtime notes**

Delete notes that describe CLI flags and `.record/` output as supported current behavior.

### Task 5: Verify and Commit

**Files:**
- All files changed by Tasks 1-4

- [ ] **Step 1: Run full unit tests**

Run: `swift test`

Expected: PASS.

- [ ] **Step 2: Build the app product**

Run: `swift build --product MeetingAgentApp`

Expected: PASS.

- [ ] **Step 3: Commit**

Run:

```bash
git add Package.swift AGENTS.md Sources/CoreAudioTapProbe Sources/MeetingAgentCore/ProbeOptions.swift Sources/MeetingAgentCore/RecordingOutput.swift Sources/MeetingAgentCore/TranscriptFileWriter.swift Tests/MeetingAgentCoreTests/ScaffoldTests.swift Tests/MeetingAgentCoreTests/TranscriptFileWriterTests.swift docs/superpowers/specs/2026-04-27-app-only-package-design.md docs/superpowers/plans/2026-04-27-app-only-package.md
git commit -m "feat: remove CoreAudioTapProbe CLI mode (#20)"
```
