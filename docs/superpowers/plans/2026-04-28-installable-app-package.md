# Installable App Package Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a reproducible local packaging workflow that builds `dist/MeetingAgent.app` from the existing SwiftPM `MeetingAgentApp` product.

**Architecture:** Keep SwiftPM as the build source of truth. Add bundle metadata as an app resource template, add a shell script that assembles a standard macOS `.app` layout from the release executable, and expose the script through `make package-app`. Use source-level tests to protect the package script, `Info.plist`, and supported command surface.

**Tech Stack:** Swift Package Manager, Swift 5.9, XCTest, POSIX shell, macOS app bundle layout.

---

## File Structure

- `Sources/MeetingAgentApp/Resources/Info.plist`: bundle metadata copied into `MeetingAgent.app/Contents/Info.plist`.
- `scripts/package-app.sh`: build and bundle script.
- `Makefile`: adds the stable `package-app` entrypoint.
- `AGENTS.md`: documents the packaging command and unsigned distribution limitation.
- `Tests/MeetingAgentCoreTests/ScaffoldTests.swift`: source-level regression tests for packaging files and metadata.

### Task 1: Add Packaging Regression Tests

**Files:**
- Modify: `Tests/MeetingAgentCoreTests/ScaffoldTests.swift`

- [ ] **Step 1: Add helper methods and failing tests**

Add these helpers and tests inside `ScaffoldTests`:

```swift
    func testPackageAppScriptBuildsAndAssemblesBundle() throws {
        let script = try readRepositoryFile("scripts/package-app.sh")

        XCTAssertTrue(script.contains("swift build -c release --product MeetingAgentApp"))
        XCTAssertTrue(script.contains("dist/MeetingAgent.app"))
        XCTAssertTrue(script.contains("Contents/MacOS"))
        XCTAssertTrue(script.contains("Contents/Resources"))
        XCTAssertTrue(script.contains("Sources/MeetingAgentApp/Resources/Info.plist"))
        XCTAssertTrue(script.contains("PkgInfo"))
    }

    func testAppInfoPlistContainsBundleMetadataAndPermissions() throws {
        let plist = try readRepositoryFile("Sources/MeetingAgentApp/Resources/Info.plist")

        XCTAssertTrue(plist.contains("<key>CFBundleExecutable</key>"))
        XCTAssertTrue(plist.contains("<string>MeetingAgentApp</string>"))
        XCTAssertTrue(plist.contains("<key>CFBundleIdentifier</key>"))
        XCTAssertTrue(plist.contains("<string>ai.plovr.MeetingAgent</string>"))
        XCTAssertTrue(plist.contains("<key>CFBundlePackageType</key>"))
        XCTAssertTrue(plist.contains("<string>APPL</string>"))
        XCTAssertTrue(plist.contains("<key>LSMinimumSystemVersion</key>"))
        XCTAssertTrue(plist.contains("<string>14.2</string>"))
        XCTAssertTrue(plist.contains("<key>NSMicrophoneUsageDescription</key>"))
        XCTAssertTrue(plist.contains("<key>NSSpeechRecognitionUsageDescription</key>"))
        XCTAssertTrue(plist.contains("<key>NSUserNotificationUsageDescription</key>"))
    }

    func testMakefileExposesPackageAppCommand() throws {
        let makefile = try readRepositoryFile("Makefile")

        XCTAssertTrue(makefile.contains(".PHONY: test package-app"))
        XCTAssertTrue(makefile.contains("package-app:"))
        XCTAssertTrue(makefile.contains("scripts/package-app.sh"))
    }

    private func readRepositoryFile(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url)
    }
```

- [ ] **Step 2: Run the focused test and confirm failure**

Run: `swift test --filter ScaffoldTests`

Expected: FAIL because `scripts/package-app.sh` and `Sources/MeetingAgentApp/Resources/Info.plist` do not exist, and `Makefile` does not expose `package-app`.

- [ ] **Step 3: Commit the failing tests only if project convention requires red commits**

Do not commit yet for this repository. Keep the failing tests in the working tree and implement the minimal files in Task 2.

### Task 2: Add Bundle Metadata

**Files:**
- Create: `Sources/MeetingAgentApp/Resources/Info.plist`

- [ ] **Step 1: Create the resources directory**

Run: `mkdir -p Sources/MeetingAgentApp/Resources`

- [ ] **Step 2: Add `Info.plist`**

Create `Sources/MeetingAgentApp/Resources/Info.plist` with:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>Meeting Agent</string>
    <key>CFBundleExecutable</key>
    <string>MeetingAgentApp</string>
    <key>CFBundleIdentifier</key>
    <string>ai.plovr.MeetingAgent</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Meeting Agent</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.2</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Meeting Agent needs microphone access to capture meeting audio for transcription and summaries.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Meeting Agent uses speech recognition to transcribe meeting audio when the local Apple Speech provider is selected.</string>
    <key>NSUserNotificationUsageDescription</key>
    <string>Meeting Agent uses notifications to alert you when a meeting app is detected.</string>
</dict>
</plist>
```

- [ ] **Step 3: Run the focused plist test**

Run: `swift test --filter ScaffoldTests/testAppInfoPlistContainsBundleMetadataAndPermissions`

Expected: PASS.

### Task 3: Add Packaging Script and Make Target

**Files:**
- Create: `scripts/package-app.sh`
- Modify: `Makefile`

- [ ] **Step 1: Create `scripts/package-app.sh`**

Create `scripts/package-app.sh` with:

```sh
#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
APP_NAME="MeetingAgent"
EXECUTABLE_NAME="MeetingAgentApp"
APP_BUNDLE="$REPO_ROOT/dist/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
INFO_PLIST="$REPO_ROOT/Sources/MeetingAgentApp/Resources/Info.plist"
RELEASE_EXECUTABLE="$REPO_ROOT/.build/release/$EXECUTABLE_NAME"

if [ ! -f "$INFO_PLIST" ]; then
    echo "Missing app Info.plist at $INFO_PLIST" >&2
    exit 1
fi

cd "$REPO_ROOT"
swift build -c release --product MeetingAgentApp

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$RELEASE_EXECUTABLE" "$MACOS_DIR/$EXECUTABLE_NAME"
cp "$INFO_PLIST" "$CONTENTS_DIR/Info.plist"
printf "APPL????" > "$CONTENTS_DIR/PkgInfo"

if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - "$APP_BUNDLE"
fi

echo "Packaged $APP_BUNDLE"
```

- [ ] **Step 2: Make the script executable**

Run: `chmod +x scripts/package-app.sh`

- [ ] **Step 3: Update `Makefile`**

Replace `Makefile` contents with:

```make
.PHONY: test package-app

test:
	scripts/check-unit-coverage.sh

package-app:
	scripts/package-app.sh
```

- [ ] **Step 4: Run the focused script and Makefile tests**

Run: `swift test --filter ScaffoldTests/testPackageAppScriptBuildsAndAssemblesBundle`

Expected: PASS.

Run: `swift test --filter ScaffoldTests/testMakefileExposesPackageAppCommand`

Expected: PASS.

### Task 4: Document Packaging Workflow

**Files:**
- Modify: `AGENTS.md`

- [ ] **Step 1: Update common commands**

Change the common commands block to include `make package-app`:

```sh
make test
swift build --product MeetingAgentApp
make package-app
swift run MeetingAgentApp
```

- [ ] **Step 2: Add packaging note**

Add this paragraph after the app data location paragraph:

```markdown
Use `make package-app` to create `dist/MeetingAgent.app` for local installation or prototype sharing. The generated app bundle is not Developer ID signed or Apple notarized, so recipients may need to right-click Open or approve it in System Settings the first time they launch it.
```

### Task 5: Verify Packaging End-to-End

**Files:**
- All files changed by Tasks 1-4

- [ ] **Step 1: Run focused scaffold tests**

Run: `swift test --filter ScaffoldTests`

Expected: PASS.

- [ ] **Step 2: Run full unit verification**

Run: `make test`

Expected: PASS with coverage threshold satisfied.

- [ ] **Step 3: Build the app product**

Run: `swift build --product MeetingAgentApp`

Expected: PASS.

- [ ] **Step 4: Build the installable app bundle**

Run: `make package-app`

Expected: PASS and output includes `Packaged /Users/allan/workspace/meeting/meeting-agent-issue-38/dist/MeetingAgent.app`.

- [ ] **Step 5: Inspect generated bundle**

Run: `find dist/MeetingAgent.app -maxdepth 3 -type f | sort`

Expected output includes:

```text
dist/MeetingAgent.app/Contents/Info.plist
dist/MeetingAgent.app/Contents/MacOS/MeetingAgentApp
dist/MeetingAgent.app/Contents/PkgInfo
```

- [ ] **Step 6: Commit implementation**

Run:

```bash
git add AGENTS.md Makefile Sources/MeetingAgentApp/Resources/Info.plist scripts/package-app.sh Tests/MeetingAgentCoreTests/ScaffoldTests.swift docs/superpowers/plans/2026-04-28-installable-app-package.md
git commit -m "feat: add installable app packaging (#38)"
```

