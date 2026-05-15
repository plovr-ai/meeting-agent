import XCTest

final class SettingsViewLayoutTests: XCTestCase {
    func testSettingsViewUsesPickersForAllEditableFields() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MeetingAgentApp/SettingsView.swift")
        let source = try String(contentsOf: sourceURL)

        XCTAssertFalse(source.contains("Picker(\"Source Locale\""))
        XCTAssertTrue(source.contains("Picker(\"Main Language\""))
        XCTAssertTrue(source.contains("Picker(\"Main Language\", selection: $draft.localeIdentifier)"))
        XCTAssertFalse(source.contains("Picker(\"Target Locale\""))
        XCTAssertTrue(source.contains("Picker(\"Transcription Mode\""))
        XCTAssertTrue(source.contains("Picker(\"Local Transcription Provider\""))
        XCTAssertTrue(source.contains("Picker(\"Hosted Transcription Provider\""))
        XCTAssertTrue(source.contains("Picker(\"Hosted Transcription Model\""))
        XCTAssertTrue(source.contains("Text(\"Deepgram\")"))
        XCTAssertTrue(source.contains("Text(\"Aliyun Paraformer\")"))
        XCTAssertTrue(source.contains("SettingsCommandCenterPanel(\"Deepgram\")"))
        XCTAssertTrue(source.contains("SettingsCommandCenterPanel(\"Aliyun\")"))
        XCTAssertTrue(source.contains("SecureField(\"Deepgram API Key\""))
        XCTAssertTrue(source.contains("SecureField(\"DashScope API Key\""))
        XCTAssertTrue(source.contains("SecureField(\"OpenRouter API Key\""))
        XCTAssertFalse(source.contains("Text(\"OpenAI Realtime\")"))
        XCTAssertFalse(source.contains("SettingsCommandCenterPanel(\"Live Translation\")"))
        XCTAssertFalse(source.contains("SecureField(\"OpenAI Realtime API Key\""))
        XCTAssertFalse(source.contains("openAIRealtimeAPIKeyBinding"))
        XCTAssertTrue(source.contains("usesOpenRouter"))
        XCTAssertFalse(source.contains("Picker(\"Hosted Translation Model\""))
        XCTAssertTrue(source.contains("Picker(\"Hosted Summary Model\""))
        XCTAssertFalse(source.contains("Picker(\"Translation Mode\""))
        XCTAssertFalse(source.contains("Picker(\"Local Translation Provider\""))
        XCTAssertFalse(source.contains("Picker(\"Hosted Translation Provider\""))
        XCTAssertFalse(source.contains("Picker(\"" + "Bilingual Pipeline Profile\""))
        XCTAssertFalse(source.contains("Section(\"" + "Bilingual Pipeline\")"))
        XCTAssertFalse(source.contains("Picker(\"Whisper Binary Path\""))
        XCTAssertFalse(source.contains("whisperBinaryPathOptions"))
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

    func testSettingsViewExposesKarpathyWikiDestinationControls() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MeetingAgentApp/SettingsView.swift")
        let source = try String(contentsOf: sourceURL)

        XCTAssertTrue(source.contains("SettingsCommandCenterPanel(\"Knowledge Destinations\")"))
        XCTAssertTrue(source.contains("Toggle(\"Export to Karpathy Wiki\""))
        XCTAssertTrue(source.contains("CommandCenterTextEditor(text: $karpathyWikiRootPath)"))
        XCTAssertTrue(source.contains("Text(\"GBrain sync is planned\")"))
    }

    func testSettingsViewAppliesCommandCenterTextColorToNativeControls() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MeetingAgentApp/SettingsView.swift")
        let source = try String(contentsOf: sourceURL)

        XCTAssertTrue(source.contains(".foregroundStyle(CommandCenterPalette.text)"))
        XCTAssertTrue(source.contains(".tint(CommandCenterPalette.primary)"))
    }

    func testSettingsViewUsesInContentThemedHeaderInsteadOfSystemNavigationTitle() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MeetingAgentApp/SettingsView.swift")
        let source = try String(contentsOf: sourceURL)

        XCTAssertTrue(source.contains("CommandCenterPageHeader(title: \"Settings\""))
        XCTAssertFalse(source.contains(".navigationTitle(\"Settings\")"))
    }

    func testMainWindowUsesCommandCenterStyling() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MeetingAgentApp/MainWindowView.swift")
        let source = try String(contentsOf: sourceURL)

        XCTAssertTrue(source.contains("CommandCenterPalette"))
        XCTAssertTrue(source.contains("CommandCenterActionButtonStyle"))
        XCTAssertTrue(source.contains("MeetingCommandCenterView"))
        XCTAssertTrue(source.contains("TranscriptPaneView"))
        XCTAssertTrue(source.contains("InsightPaneView"))
        XCTAssertFalse(source.contains("Live Translation"))
        XCTAssertFalse(source.contains("Send to call"))
    }

    func testSettingsViewUsesCommandCenterPanels() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MeetingAgentApp/SettingsView.swift")
        let source = try String(contentsOf: sourceURL)

        XCTAssertTrue(source.contains("SettingsCommandCenterPanel"))
        XCTAssertTrue(source.contains("CommandCenterPanel"))
        XCTAssertTrue(source.contains("CommandCenterActionButtonStyle"))
    }

    func testCommandCenterDesignSystemCentralizesSharedStyles() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MeetingAgentApp/CommandCenterDesignSystem.swift")
        let source = try String(contentsOf: sourceURL)

        XCTAssertTrue(source.contains("enum CommandCenterPalette"))
        XCTAssertTrue(source.contains("enum CommandCenterTypography"))
        XCTAssertTrue(source.contains("struct CommandCenterPanel"))
        XCTAssertTrue(source.contains("struct CommandCenterPageHeader"))
        XCTAssertTrue(source.contains("struct CommandCenterScrollView"))
        XCTAssertTrue(source.contains("struct CommandCenterTextEditor"))
        XCTAssertTrue(source.contains("struct CommandCenterChip"))
        XCTAssertTrue(source.contains("struct CommandCenterActionButtonStyle"))
        XCTAssertTrue(source.contains("commandCenterAppTheme()"))
        XCTAssertTrue(source.contains("CommandCenterNativeAppearance"))
        XCTAssertTrue(source.contains("extension Text"))
    }

    func testAppViewsUseSharedThemeAndAvoidAdHocFonts() throws {
        let appSourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MeetingAgentApp/MeetingAgentApp.swift")
        let mainSourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MeetingAgentApp/MainWindowView.swift")
        let settingsSourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MeetingAgentApp/SettingsView.swift")
        let appSource = try String(contentsOf: appSourceURL)
        let mainSource = try String(contentsOf: mainSourceURL)
        let settingsSource = try String(contentsOf: settingsSourceURL)

        XCTAssertTrue(appSource.contains(".commandCenterAppTheme()"))
        XCTAssertFalse(mainSource.contains(".font(.system("))
        XCTAssertFalse(mainSource.contains(".font(.headline)"))
        XCTAssertFalse(mainSource.contains(".font(.caption)"))
        XCTAssertFalse(settingsSource.contains(".font(.system("))
        XCTAssertFalse(settingsSource.contains(".font(.headline)"))
        XCTAssertFalse(settingsSource.contains(".font(.caption)"))
    }

    func testScrollableAndEditableSurfacesUseSharedCommandCenterComponents() throws {
        let mainSourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MeetingAgentApp/MainWindowView.swift")
        let settingsSourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MeetingAgentApp/SettingsView.swift")
        let mainSource = try String(contentsOf: mainSourceURL)
        let settingsSource = try String(contentsOf: settingsSourceURL)

        XCTAssertTrue(mainSource.contains("CommandCenterScrollView"))
        XCTAssertTrue(settingsSource.contains("CommandCenterScrollView"))
        XCTAssertTrue(mainSource.contains("CommandCenterTextEditor(text: $text)"))
        XCTAssertFalse(mainSource.contains("\n            TextEditor(text:"))
        XCTAssertFalse(mainSource.contains("\n            ScrollView {"))
        XCTAssertFalse(settingsSource.contains("\n        ScrollView {"))
    }
}
