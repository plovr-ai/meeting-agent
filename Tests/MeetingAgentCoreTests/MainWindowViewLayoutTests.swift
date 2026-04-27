import XCTest

final class MainWindowViewLayoutTests: XCTestCase {
    func testRecordingAndRetryButtonsShareActionRow() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MeetingAgentApp/MainWindowView.swift")
        let source = try String(contentsOf: sourceURL)

        guard let stopRange = source.range(of: "Button(\"Stop Recording\")") else {
            return XCTFail("Stop Recording button is missing")
        }
        guard let retryRange = source.range(of: "Button(\"Retry Transcription\")") else {
            return XCTFail("Retry Transcription button is missing")
        }
        XCTAssertLessThan(stopRange.lowerBound, retryRange.lowerBound)

        let precedingSource = source[..<stopRange.lowerBound]
        guard let actionRowStart = precedingSource.range(of: "HStack", options: .backwards) else {
            return XCTFail("Recording action row is missing")
        }

        let actionRow = source[actionRowStart.lowerBound..<retryRange.upperBound]
        XCTAssertTrue(actionRow.contains("Button(\"Stop Recording\")"))
        XCTAssertTrue(actionRow.contains("Button(\"Retry Transcription\")"))
    }

    func testSummaryDownloadAndRegenerateControlsAreRemoved() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MeetingAgentApp/MainWindowView.swift")
        let source = try String(contentsOf: sourceURL)

        XCTAssertFalse(source.contains("Label(\"Summary\", systemImage: \"text.badge.checkmark\")"))
        XCTAssertFalse(source.contains("Button(\"Regenerate Summary\")"))
    }

    func testMainWindowHasSettingsDestinationAndNoInlineConfigurationFields() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MeetingAgentApp/MainWindowView.swift")
        let source = try String(contentsOf: sourceURL)

        XCTAssertTrue(source.contains("@State private var showSettings = false"))
        XCTAssertTrue(source.contains("SettingsView("))
        XCTAssertFalse(source.contains("\"Whisper Binary Path\""))
        XCTAssertFalse(source.contains("\"Whisper Model Path\""))
        XCTAssertFalse(source.contains("\"STT Locale\""))
    }

    func testMeetingRowsUseListSelectionTags() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MeetingAgentApp/MainWindowView.swift")
        let source = try String(contentsOf: sourceURL)

        XCTAssertTrue(source.contains("List(selection: Binding("))
        XCTAssertTrue(source.contains(".tag(Optional(meeting.id))"))
        XCTAssertFalse(source.contains(".onTapGesture {\n                            viewModel.selectMeeting(meeting.id)"))
    }

    func testSettingsEntryIsFixedAtBottomOfSidebar() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MeetingAgentApp/MainWindowView.swift")
        let source = try String(contentsOf: sourceURL)

        guard let spacerRange = source.range(of: "Spacer()") else {
            return XCTFail("Sidebar spacer is missing")
        }
        guard let settingsRange = source.range(of: "Button {") else {
            return XCTFail("Settings bottom button is missing")
        }

        XCTAssertLessThan(spacerRange.lowerBound, settingsRange.lowerBound)
        XCTAssertTrue(source.contains("showSettings = true"))
    }

    func testMainWindowContainsLiveTranslationControls() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MeetingAgentApp/MainWindowView.swift")
        let source = try String(contentsOf: sourceURL)

        XCTAssertTrue(source.contains("Live Translation"))
        XCTAssertTrue(source.contains("Start Live Translation"))
        XCTAssertTrue(source.contains("Stop Live Translation"))
    }

    func testMeetingDetailShowsCurrentPipelineAndActualSTTSource() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MeetingAgentApp/MainWindowView.swift")
        let source = try String(contentsOf: sourceURL)

        XCTAssertTrue(source.contains("speechConfiguration: viewModel.speechConfiguration"))
        XCTAssertTrue(source.contains("Current Pipeline"))
        XCTAssertTrue(source.contains("Transcription Link"))
        XCTAssertTrue(source.contains("Transcription Model"))
        XCTAssertTrue(source.contains("Translation Link"))
        XCTAssertTrue(source.contains("Translation Model"))
        XCTAssertTrue(source.contains("Actual STT Source"))
        XCTAssertTrue(source.contains("actualTranscriptionSourceText(for: meeting)"))
    }

    func testMainWindowExposesLiveMeetingDashboardStructure() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MeetingAgentApp/MainWindowView.swift")
        let source = try String(contentsOf: sourceURL)

        XCTAssertTrue(source.contains("LiveMeetingDashboardView"))
        XCTAssertTrue(source.contains("CaptionTurnView"))
        XCTAssertTrue(source.contains("GoalStatusPanel"))
        XCTAssertTrue(source.contains("SuggestedQuestionRow"))
        XCTAssertTrue(source.contains("LiveHealthChip"))
    }

    func testTranscriptPaneShowsLiveCaptionStreamBeforeTranscript() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MeetingAgentApp/MainWindowView.swift")
        let source = try String(contentsOf: sourceURL)

        guard let liveCaptionsRange = source.range(of: "liveCaptions") else {
            return XCTFail("Live caption stream is missing")
        }
        guard let transcriptRange = source.range(of: "transcript", options: [], range: liveCaptionsRange.upperBound..<source.endIndex) else {
            return XCTFail("Transcript section is missing after live captions")
        }

        XCTAssertLessThan(liveCaptionsRange.lowerBound, transcriptRange.lowerBound)
        XCTAssertTrue(source.contains("Text(\"Live Captions\")"))
        XCTAssertTrue(source.contains("ForEach(liveCaptionTurns.suffix(8))"))
        XCTAssertTrue(source.contains("CaptionTurnView("))
        XCTAssertTrue(source.contains("turn: turn"))
    }

    func testExportsPanelExposesSubtitleExportActions() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MeetingAgentApp/MainWindowView.swift")
        let source = try String(contentsOf: sourceURL)

        XCTAssertTrue(source.contains("exportSRT"))
        XCTAssertTrue(source.contains("exportVTT"))
        XCTAssertTrue(source.contains("Label(\"SRT\", systemImage: \"captions.bubble\")"))
        XCTAssertTrue(source.contains("Label(\"VTT\", systemImage: \"captions.bubble\")"))
        XCTAssertTrue(source.contains("viewModel.exportSubtitles(for: meeting.id, format: .srt"))
        XCTAssertTrue(source.contains("viewModel.exportSubtitles(for: meeting.id, format: .vtt"))
    }

    func testLiveCaptionsExposeCorrectionControls() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MeetingAgentApp/MainWindowView.swift")
        let source = try String(contentsOf: sourceURL)

        XCTAssertTrue(source.contains("updateSpeakerLabel"))
        XCTAssertTrue(source.contains("updateTranscriptSegmentText"))
        XCTAssertTrue(source.contains("CaptionEditSheet"))
        XCTAssertTrue(source.contains("person.crop.circle.badge.pencil"))
        XCTAssertTrue(source.contains("Image(systemName: \"pencil\")"))
        XCTAssertTrue(source.contains("Correct Caption"))
        XCTAssertTrue(source.contains("Save Speaker"))
        XCTAssertTrue(source.contains("Save Caption"))
    }

    func testMainWindowExposesLightweightMeetingGoalComposer() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MeetingAgentApp/MainWindowView.swift")
        let source = try String(contentsOf: sourceURL)

        XCTAssertTrue(source.contains("GoalComposerPanel"))
        XCTAssertTrue(source.contains("TextField(\"Goal title\""))
        XCTAssertTrue(source.contains("LabeledTextEditor(title: \"Objectives\""))
        XCTAssertTrue(source.contains("LabeledTextEditor(title: \"Required Questions\""))
        XCTAssertTrue(source.contains("LabeledTextEditor(title: \"Key Terms\""))
        XCTAssertTrue(source.contains("Label(\"Apply Goal\", systemImage: \"target\")"))
        XCTAssertTrue(source.contains("setMeetingGoal(buildGoal())"))
        XCTAssertTrue(source.contains("meetingGoal: viewModel.meetingGoal"))
        XCTAssertTrue(source.contains("draftGoal: meetingGoal"))
    }
}
