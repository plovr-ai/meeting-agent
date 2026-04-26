# Settings Page Design

## Goal

Move meeting-agent configuration out of the meeting list sidebar and into a dedicated Settings page inside the existing main window.

The Settings page should let users configure speech recognition and bilingual subtitle pipeline strategy without typing free-form values. All editable settings should use dropdown-style selection controls and should be saved explicitly.

## Scope

In scope:

- Add a Settings destination inside the existing `NavigationSplitView`.
- Keep the app as a single main-window experience.
- Move current speech configuration controls out of the meeting list area.
- Add bilingual subtitle strategy settings:
  - source locale
  - target locale
  - bilingual pipeline profile
- Use dropdown controls for all editable settings.
- Save settings only when the user clicks Save.
- Reset draft settings back to the currently saved configuration.
- Disable editing and saving while recording.
- Persist saved settings through `SpeechTranscriptionConfigurationStore`.

Out of scope:

- Creating a separate macOS Settings window.
- Custom model path browsing.
- Runtime validation of local filesystem paths beyond the existing `speechConfigurationStatus`.
- Implementing real hosted translation providers.
- Running the bilingual pipeline after recording. This page configures strategy only.

## Navigation

The main window should keep `NavigationSplitView`.

The sidebar should have a top-level navigation section with two destinations:

- `Meetings`
- `Settings`

When `Meetings` is selected, the app shows the current meeting list and meeting detail behavior.

When `Settings` is selected, the detail pane shows the Settings page. The meeting list should not be mixed with configuration controls.

## Settings Fields

All editable fields use dropdown-style controls.

### STT Provider

Control: Picker.

Options:

- values from `SpeechProvider.allCases`

Saved to:

- `SpeechTranscriptionConfiguration.provider`

### Source Locale

Control: Picker.

Options:

- `en-US`
- `zh-CN`
- `zh-TW`
- `ja-JP`
- `ko-KR`
- `fr-FR`
- `de-DE`
- `es-ES`

Saved to:

- `SpeechTranscriptionConfiguration.localeIdentifier`

### Target Locale

Control: Picker.

Options:

- same locale list as Source Locale

Saved to:

- `SpeechTranscriptionConfiguration.targetLocaleIdentifier`

### Bilingual Pipeline Profile

Control: Picker.

Options:

- values from `BilingualPipelineFactory.builtInProfiles`

Display text:

- `BilingualPipelineProfile.displayName`

Saved value:

- `BilingualPipelineProfile.id`

Saved to:

- `SpeechTranscriptionConfiguration.bilingualPipelineProfileID`

### Whisper Binary Path

Control: Picker.

Options:

- current saved binary path, if present
- `MEETING_AGENT_WHISPER_BIN` value, if set
- `/opt/homebrew/bin/whisper-cli`
- `/usr/local/bin/whisper-cli`

Duplicate and blank options should be removed before rendering.

Saved to:

- `SpeechTranscriptionConfiguration.whisperBinaryPath`

### Whisper Model Path

Control: Picker.

Options:

- current saved model path, if present
- `MEETING_AGENT_WHISPER_MODEL` value, if set
- `/Users/allan/models/ggml-small.bin`
- `/Users/allan/models/ggml-medium.bin`

Duplicate and blank options should be removed before rendering.

Saved to:

- `SpeechTranscriptionConfiguration.whisperModelPath`

## Save And Reset Behavior

The Settings page edits a draft copy of `SpeechTranscriptionConfiguration`.

Initial draft:

- copied from `MeetingAgentViewModel.speechConfiguration`

Save:

- calls `MeetingAgentViewModel.saveSpeechConfiguration(_:)`
- updates the published configuration
- persists through `SpeechTranscriptionConfigurationStore`
- updates the status text to indicate settings were saved

Reset:

- replaces the draft with the current `MeetingAgentViewModel.speechConfiguration`
- does not write to storage

Recording:

- dropdown controls are disabled while `viewModel.isRecording` is true
- Save is disabled while recording
- Reset may remain enabled because it only affects unsaved draft state

## ViewModel Changes

Add a bulk save method:

```swift
public func saveSpeechConfiguration(_ configuration: SpeechTranscriptionConfiguration)
```

The method should:

1. Assign the normalized configuration to `speechConfiguration`.
2. Persist with `SpeechTranscriptionConfigurationStore`.
3. Update `statusText` to `Settings saved`.

Existing single-field update methods can remain for compatibility with current tests and any later compact controls.

Add convenience data for settings UI where useful:

```swift
public static let supportedLocaleIdentifiers: [String]
```

This keeps locale choices testable outside SwiftUI.

## SwiftUI Structure

Introduce a small private sidebar selection enum in `MainWindowView.swift`:

```swift
private enum MainSidebarSelection: Hashable {
    case meetings
    case settings
}
```

Add a private `SettingsView` in `MainWindowView.swift` or a new `SettingsView.swift` if the file becomes too large.

Recommended first implementation:

- create `Sources/MeetingAgentApp/SettingsView.swift`
- keep `MainWindowView.swift` focused on navigation and meeting detail

`SettingsView` inputs:

```swift
struct SettingsView: View {
    let configuration: SpeechTranscriptionConfiguration
    let profiles: [BilingualPipelineProfile]
    let localeIdentifiers: [String]
    let isRecording: Bool
    let status: SpeechConfigurationValidationStatus
    let save: (SpeechTranscriptionConfiguration) -> Void
}
```

`SettingsView` owns:

- `@State private var draft: SpeechTranscriptionConfiguration`

The view should refresh the draft when the incoming configuration changes and the user has no unsaved edit.

## Error And Status Display

The Settings page should show the current configuration status using the existing `SpeechConfigurationValidationStatus`:

- `.available`: secondary text
- `.unavailable(reason)`: red text

This keeps Whisper binary/model problems visible without adding path validation logic to the view.

## Testing

Unit and source-layout tests should cover:

- `MeetingAgentViewModel.saveSpeechConfiguration(_:)` persists provider, source locale, target locale, profile ID, and Whisper paths.
- Saving settings updates `statusText` to `Settings saved`.
- `MainWindowView.swift` no longer renders the old sidebar text fields for STT locale and Whisper paths.
- `SettingsView.swift` contains pickers for STT provider, source locale, target locale, pipeline profile, Whisper binary path, and Whisper model path.
- `SettingsView.swift` does not contain `TextField(`.
- `SettingsView.swift` disables controls when `isRecording` is true.

The SwiftUI view tests can stay source-based, matching the current lightweight `MainWindowViewLayoutTests` pattern.

## Compatibility

Existing saved `SpeechTranscriptionConfiguration` values remain compatible because the configuration type already supplies defaults for missing bilingual fields during decoding.

Existing meeting records do not need migration. The Settings page affects future recordings and retry operations that read `speechConfiguration`.
