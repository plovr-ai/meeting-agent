import XCTest

final class SettingsViewLayoutTests: XCTestCase {
    func testSettingsViewUsesPickersForAllEditableFields() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MeetingAgentApp/SettingsView.swift")
        let source = try String(contentsOf: sourceURL)

        XCTAssertTrue(source.contains("Picker(\"Source Locale\""))
        XCTAssertTrue(source.contains("Picker(\"Target Locale\""))
        XCTAssertTrue(source.contains("Picker(\"Transcription Mode\""))
        XCTAssertTrue(source.contains("Picker(\"Local Transcription Provider\""))
        XCTAssertTrue(source.contains("Picker(\"Hosted Transcription Provider\""))
        XCTAssertTrue(source.contains("Picker(\"Hosted Transcription Model\""))
        XCTAssertTrue(source.contains("Text(\"Deepgram\")"))
        XCTAssertTrue(source.contains("Text(\"OpenAI Realtime\")"))
        XCTAssertTrue(source.contains("SettingsCommandCenterPanel(\"Deepgram\")"))
        XCTAssertTrue(source.contains("SecureField(\"Deepgram API Key\""))
        XCTAssertTrue(source.contains("SecureField(\"OpenRouter API Key\""))
        XCTAssertTrue(source.contains("SettingsCommandCenterPanel(\"Live Translation\")"))
        XCTAssertTrue(source.contains("SecureField(\"OpenAI Realtime API Key\""))
        XCTAssertTrue(source.contains("openAIRealtimeAPIKeyBinding"))
        XCTAssertTrue(source.contains("usesOpenRouter"))
        XCTAssertTrue(source.contains("Picker(\"Translation Mode\""))
        XCTAssertTrue(source.contains("Picker(\"Local Translation Provider\""))
        XCTAssertTrue(source.contains("Picker(\"Hosted Translation Provider\""))
        XCTAssertTrue(source.contains("Picker(\"Hosted Translation Model\""))
        XCTAssertFalse(source.contains("Picker(\"Bilingual Pipeline Profile\""))
        XCTAssertFalse(source.contains("Section(\"Bilingual Pipeline\")"))
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

    func testMainWindowUsesCommandCenterStyling() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MeetingAgentApp/MainWindowView.swift")
        let source = try String(contentsOf: sourceURL)

        XCTAssertTrue(source.contains("CommandCenterPalette"))
        XCTAssertTrue(source.contains("CommandCenterActionButtonStyle"))
        XCTAssertTrue(source.contains("MeetingCommandCenterView"))
        XCTAssertTrue(source.contains("TranscriptPaneView"))
        XCTAssertTrue(source.contains("InsightPaneView"))
        XCTAssertTrue(source.contains("Live Translation"))
        XCTAssertTrue(source.contains("Send to call"))
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
        XCTAssertTrue(source.contains("struct CommandCenterPanel"))
        XCTAssertTrue(source.contains("struct CommandCenterChip"))
        XCTAssertTrue(source.contains("struct CommandCenterActionButtonStyle"))
        XCTAssertTrue(source.contains("extension Text"))
    }
}
