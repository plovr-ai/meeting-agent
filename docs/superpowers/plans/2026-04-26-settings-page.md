# Settings Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an in-window Settings page where all speech and bilingual pipeline strategy settings are selected from dropdown controls and saved explicitly.

**Architecture:** Add small, testable configuration helpers to `MeetingAgentViewModel`, then create a dedicated SwiftUI `SettingsView` that edits a draft `SpeechTranscriptionConfiguration`. Update `MainWindowView` navigation so Settings is a first-class destination and remove inline configuration controls from the meeting list sidebar.

**Tech Stack:** Swift 5.9, SwiftUI, XCTest, source-layout tests matching the existing app test style.

---

## File Structure

- Modify `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`: add supported locale list and bulk save method.
- Create `Sources/MeetingAgentApp/SettingsView.swift`: settings form using only `Picker` controls, Save, Reset, and status display.
- Modify `Sources/MeetingAgentApp/MainWindowView.swift`: add sidebar destination selection, remove old inline config controls, route Settings to `SettingsView`.
- Modify `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`: test bulk save persistence and status.
- Create `Tests/MeetingAgentCoreTests/SettingsViewLayoutTests.swift`: source-based tests for picker-only settings UI.
- Modify `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`: assert old text-field controls are removed and Settings destination exists.

## Task 1: ViewModel Settings Save API

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Modify: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] **Step 1: Write failing ViewModel save test**

Add this test to `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`:

```swift
func testSaveSpeechConfigurationPersistsBilingualSettings() throws {
    let suiteName = "meeting-vm-settings-save-\(UUID().uuidString)"
    let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { userDefaults.removePersistentDomain(forName: suiteName) }
    let configurationStore = SpeechTranscriptionConfigurationStore(userDefaults: userDefaults)
    let viewModel = MeetingAgentViewModel(
        speechConfigurationStore: configurationStore,
        processTargetsProvider: { [] }
    )

    let configuration = SpeechTranscriptionConfiguration(
        provider: .local,
        localeIdentifier: "ja-JP",
        targetLocaleIdentifier: "zh-CN",
        bilingualPipelineProfileID: "local-whisper-local-translation",
        whisperBinaryPath: "/opt/homebrew/bin/whisper-cli",
        whisperModelPath: "/Users/allan/models/ggml-medium.bin"
    )

    viewModel.saveSpeechConfiguration(configuration)

    XCTAssertEqual(viewModel.speechConfiguration, configuration)
    XCTAssertEqual(try configurationStore.load(), configuration)
    XCTAssertEqual(viewModel.statusText, "Settings saved")
}
```

Add this locale-list test:

```swift
func testSupportedLocaleIdentifiersIncludeInitialSettingsChoices() {
    XCTAssertEqual(MeetingAgentViewModel.supportedLocaleIdentifiers, [
        "en-US",
        "zh-CN",
        "zh-TW",
        "ja-JP",
        "ko-KR",
        "fr-FR",
        "de-DE",
        "es-ES"
    ])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MeetingAgentViewModelTests/testSaveSpeechConfigurationPersistsBilingualSettings`

Expected: build fails because `saveSpeechConfiguration(_:)` does not exist.

Run: `swift test --filter MeetingAgentViewModelTests/testSupportedLocaleIdentifiersIncludeInitialSettingsChoices`

Expected: build fails because `supportedLocaleIdentifiers` does not exist.

- [ ] **Step 3: Implement ViewModel save API**

In `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`, add near the published properties:

```swift
public static let supportedLocaleIdentifiers = [
    "en-US",
    "zh-CN",
    "zh-TW",
    "ja-JP",
    "ko-KR",
    "fr-FR",
    "de-DE",
    "es-ES"
]
```

Add this public method near the existing single-field update methods:

```swift
public func saveSpeechConfiguration(_ configuration: SpeechTranscriptionConfiguration) {
    speechConfiguration = SpeechTranscriptionConfiguration(
        provider: configuration.provider,
        localeIdentifier: configuration.localeIdentifier,
        targetLocaleIdentifier: configuration.targetLocaleIdentifier,
        bilingualPipelineProfileID: configuration.bilingualPipelineProfileID,
        whisperBinaryPath: configuration.whisperBinaryPath,
        whisperModelPath: configuration.whisperModelPath
    )
    persistSpeechConfiguration()
    statusText = "Settings saved"
}
```

- [ ] **Step 4: Run ViewModel tests**

Run: `swift test --filter MeetingAgentViewModelTests/testSaveSpeechConfigurationPersistsBilingualSettings`

Expected: test passes.

Run: `swift test --filter MeetingAgentViewModelTests/testSupportedLocaleIdentifiersIncludeInitialSettingsChoices`

Expected: test passes.

- [ ] **Step 5: Commit**

Run:

```bash
git add Sources/MeetingAgentCore/MeetingAgentViewModel.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift
git commit -m "Add settings save API"
```

## Task 2: Settings View Picker-Only Layout

**Files:**
- Create: `Sources/MeetingAgentApp/SettingsView.swift`
- Create: `Tests/MeetingAgentCoreTests/SettingsViewLayoutTests.swift`

- [ ] **Step 1: Write failing source-layout tests**

Create `Tests/MeetingAgentCoreTests/SettingsViewLayoutTests.swift`:

```swift
import XCTest

final class SettingsViewLayoutTests: XCTestCase {
    func testSettingsViewUsesPickersForAllEditableFields() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MeetingAgentApp/SettingsView.swift")
        let source = try String(contentsOf: sourceURL)

        XCTAssertTrue(source.contains("Picker(\"STT Provider\""))
        XCTAssertTrue(source.contains("Picker(\"Source Locale\""))
        XCTAssertTrue(source.contains("Picker(\"Target Locale\""))
        XCTAssertTrue(source.contains("Picker(\"Bilingual Pipeline Profile\""))
        XCTAssertTrue(source.contains("Picker(\"Whisper Binary Path\""))
        XCTAssertTrue(source.contains("Picker(\"Whisper Model Path\""))
        XCTAssertFalse(source.contains("TextField("))
    }

    func testSettingsViewHasSaveResetAndRecordingDisabledState() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MeetingAgentApp/SettingsView.swift")
        let source = try String(contentsOf: sourceURL)

        XCTAssertTrue(source.contains("Button(\"Save\")"))
        XCTAssertTrue(source.contains("Button(\"Reset\")"))
        XCTAssertTrue(source.contains(".disabled(isRecording)"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SettingsViewLayoutTests`

Expected: tests fail because `Sources/MeetingAgentApp/SettingsView.swift` does not exist.

- [ ] **Step 3: Implement `SettingsView`**

Create `Sources/MeetingAgentApp/SettingsView.swift`:

```swift
import MeetingAgentCore
import SwiftUI

struct SettingsView: View {
    let configuration: SpeechTranscriptionConfiguration
    let profiles: [BilingualPipelineProfile]
    let localeIdentifiers: [String]
    let isRecording: Bool
    let status: SpeechConfigurationValidationStatus
    let save: (SpeechTranscriptionConfiguration) -> Void

    @State private var draft: SpeechTranscriptionConfiguration

    init(
        configuration: SpeechTranscriptionConfiguration,
        profiles: [BilingualPipelineProfile],
        localeIdentifiers: [String],
        isRecording: Bool,
        status: SpeechConfigurationValidationStatus,
        save: @escaping (SpeechTranscriptionConfiguration) -> Void
    ) {
        self.configuration = configuration
        self.profiles = profiles
        self.localeIdentifiers = localeIdentifiers
        self.isRecording = isRecording
        self.status = status
        self.save = save
        _draft = State(initialValue: configuration)
    }

    var body: some View {
        Form {
            Section("Speech") {
                Picker("STT Provider", selection: $draft.provider) {
                    ForEach(SpeechProvider.allCases, id: \.self) { provider in
                        Text(provider.rawValue).tag(provider)
                    }
                }

                Picker("Source Locale", selection: $draft.localeIdentifier) {
                    ForEach(localeIdentifiers, id: \.self) { localeIdentifier in
                        Text(localeIdentifier).tag(localeIdentifier)
                    }
                }

                Picker("Target Locale", selection: $draft.targetLocaleIdentifier) {
                    ForEach(localeIdentifiers, id: \.self) { localeIdentifier in
                        Text(localeIdentifier).tag(localeIdentifier)
                    }
                }
            }

            Section("Bilingual Pipeline") {
                Picker("Bilingual Pipeline Profile", selection: $draft.bilingualPipelineProfileID) {
                    ForEach(profiles, id: \.id) { profile in
                        Text(profile.displayName).tag(profile.id)
                    }
                }
            }

            Section("Whisper") {
                Picker("Whisper Binary Path", selection: whisperBinaryPathBinding) {
                    ForEach(whisperBinaryPathOptions, id: \.self) { path in
                        Text(path).tag(path)
                    }
                }

                Picker("Whisper Model Path", selection: whisperModelPathBinding) {
                    ForEach(whisperModelPathOptions, id: \.self) { path in
                        Text(path).tag(path)
                    }
                }
            }

            Section {
                Text(configurationStatusText)
                    .font(.caption)
                    .foregroundStyle(configurationStatusColor)

                HStack {
                    Button("Save") {
                        save(draft)
                    }
                    .disabled(isRecording)

                    Button("Reset") {
                        draft = configuration
                    }
                }
            }
        }
        .disabled(isRecording)
        .padding(20)
        .navigationTitle("Settings")
    }

    private var whisperBinaryPathBinding: Binding<String> {
        Binding(
            get: { draft.whisperBinaryPath ?? "" },
            set: { draft.whisperBinaryPath = SpeechTranscriptionConfiguration.normalized($0) }
        )
    }

    private var whisperModelPathBinding: Binding<String> {
        Binding(
            get: { draft.whisperModelPath ?? "" },
            set: { draft.whisperModelPath = SpeechTranscriptionConfiguration.normalized($0) }
        )
    }

    private var whisperBinaryPathOptions: [String] {
        uniqueNonBlank([
            draft.whisperBinaryPath,
            configuration.whisperBinaryPath,
            ProcessInfo.processInfo.environment["MEETING_AGENT_WHISPER_BIN"],
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli"
        ])
    }

    private var whisperModelPathOptions: [String] {
        uniqueNonBlank([
            draft.whisperModelPath,
            configuration.whisperModelPath,
            ProcessInfo.processInfo.environment["MEETING_AGENT_WHISPER_MODEL"],
            "/Users/allan/models/ggml-small.bin",
            "/Users/allan/models/ggml-medium.bin"
        ])
    }

    private func uniqueNonBlank(_ values: [String?]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            guard let normalized = SpeechTranscriptionConfiguration.normalized(value), !seen.contains(normalized) else {
                return nil
            }
            seen.insert(normalized)
            return normalized
        }
    }

    private var configurationStatusText: String {
        switch status {
        case .available:
            return "Configuration available"
        case .unavailable(let reason):
            return reason
        }
    }

    private var configurationStatusColor: Color {
        switch status {
        case .available:
            return .secondary
        case .unavailable:
            return .red
        }
    }
}
```

- [ ] **Step 4: Run layout tests**

Run: `swift test --filter SettingsViewLayoutTests`

Expected: all settings view layout tests pass.

- [ ] **Step 5: Commit**

Run:

```bash
git add Sources/MeetingAgentApp/SettingsView.swift Tests/MeetingAgentCoreTests/SettingsViewLayoutTests.swift
git commit -m "Add settings view"
```

## Task 3: Main Window Navigation And Remove Inline Controls

**Files:**
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift`
- Modify: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

- [ ] **Step 1: Write failing MainWindow layout tests**

Add this test to `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`:

```swift
func testMainWindowHasSettingsDestinationAndNoInlineConfigurationFields() throws {
    let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/MeetingAgentApp/MainWindowView.swift")
    let source = try String(contentsOf: sourceURL)

    XCTAssertTrue(source.contains("case settings"))
    XCTAssertTrue(source.contains("SettingsView("))
    XCTAssertFalse(source.contains("TextField("))
    XCTAssertFalse(source.contains("\"Whisper Binary Path\""))
    XCTAssertFalse(source.contains("\"Whisper Model Path\""))
    XCTAssertFalse(source.contains("\"STT Locale\""))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MainWindowViewLayoutTests/testMainWindowHasSettingsDestinationAndNoInlineConfigurationFields`

Expected: test fails because `MainWindowView.swift` still contains inline text fields and no settings destination.

- [ ] **Step 3: Update `MainWindowView` navigation**

In `Sources/MeetingAgentApp/MainWindowView.swift`, add above `MainWindowView`:

```swift
private enum MainSidebarSelection: Hashable {
    case meetings
    case settings
}
```

Inside `MainWindowView`, add:

```swift
@State private var sidebarSelection: MainSidebarSelection? = .meetings
```

Replace the sidebar content with a `List(selection:)` that has top-level navigation rows and a meetings section:

```swift
List(selection: $sidebarSelection) {
    Section {
        Label("Meetings", systemImage: "waveform")
            .tag(Optional(MainSidebarSelection.meetings))
        Label("Settings", systemImage: "gearshape")
            .tag(Optional(MainSidebarSelection.settings))
    }

    if sidebarSelection == .meetings {
        Section("Meetings") {
            ForEach(viewModel.meetings) { meeting in
                VStack(alignment: .leading, spacing: 4) {
                    Text(meeting.name)
                        .font(.headline)
                    Text(meeting.startedAt, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(Optional(MainSidebarSelection.meetings))
                .onTapGesture {
                    viewModel.selectMeeting(meeting.id)
                    sidebarSelection = .meetings
                }
            }
        }
    }
}
.navigationTitle("Meeting Agent")
```

Remove the old inline `Picker("STT Provider")`, `TextField("STT Locale")`, `TextField("Whisper Binary Path")`, `TextField("Whisper Model Path")`, and configuration status text from the sidebar.

In the detail builder, switch on selection:

```swift
switch sidebarSelection {
case .settings:
    SettingsView(
        configuration: viewModel.speechConfiguration,
        profiles: BilingualPipelineFactory.builtInProfiles,
        localeIdentifiers: MeetingAgentViewModel.supportedLocaleIdentifiers,
        isRecording: viewModel.isRecording,
        status: viewModel.speechConfigurationStatus,
        save: { viewModel.saveSpeechConfiguration($0) }
    )
default:
    MeetingDetailView(...)
}
```

Keep the existing `MeetingDetailView(...)` arguments unchanged.

- [ ] **Step 4: Run layout test**

Run: `swift test --filter MainWindowViewLayoutTests/testMainWindowHasSettingsDestinationAndNoInlineConfigurationFields`

Expected: test passes.

- [ ] **Step 5: Run app build**

Run: `swift build --product MeetingAgentApp`

Expected: app builds successfully.

- [ ] **Step 6: Commit**

Run:

```bash
git add Sources/MeetingAgentApp/MainWindowView.swift Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift
git commit -m "Move configuration into settings navigation"
```

## Task 4: Full Verification

**Files:**
- No planned edits.

- [ ] **Step 1: Run full tests**

Run: `swift test`

Expected: all tests pass.

- [ ] **Step 2: Build app and CLI**

Run: `swift build --product MeetingAgentApp`

Expected: build succeeds.

Run: `swift build --product CoreAudioTapProbe`

Expected: build succeeds.

- [ ] **Step 3: Check worktree**

Run: `git status --short`

Expected: only intentional committed changes are present, or the tree is clean except user-owned `.roadmap/`.

## Self-Review

- Spec coverage: the plan covers the in-window Settings destination, picker-only controls, explicit Save and Reset, recording disabled state, persisted configuration, and source-based layout tests.
- Scope control: the plan does not add a separate macOS Settings window, custom file browsing, or actual bilingual pipeline execution.
- Type consistency: settings fields use existing `SpeechTranscriptionConfiguration` properties: `provider`, `localeIdentifier`, `targetLocaleIdentifier`, `bilingualPipelineProfileID`, `whisperBinaryPath`, and `whisperModelPath`.
