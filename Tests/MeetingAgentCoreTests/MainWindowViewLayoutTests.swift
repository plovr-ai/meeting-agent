import XCTest

final class MainWindowViewLayoutTests: XCTestCase {
    func testAppDefaultWindowSizeUsesVisibleScreenWithWidthCap() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MeetingAgentApp/MeetingAgentApp.swift")
        let source = try String(contentsOf: sourceURL)

        XCTAssertTrue(source.contains("DefaultWindowSizing.mainWindowSize"))
        XCTAssertTrue(source.contains("NSScreen.main?.visibleFrame.size"))
        XCTAssertTrue(source.contains("min(screenSize.width, 1_400)"))
        XCTAssertTrue(source.contains(".defaultSize(width: defaultWindowSize.width, height: defaultWindowSize.height)"))
    }

    func testAgendaSidebarUsesWiderDefaultWidth() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MeetingAgentApp/MainWindowView.swift")
        let source = try String(contentsOf: sourceURL)

        XCTAssertTrue(source.contains(".frame(minWidth: 260, idealWidth: 300)"))
    }

    func testMainWindowRoutesThroughAgendaFirstSidebarSections() throws {
        let source = try appSource(named: "MainWindowView.swift")

        XCTAssertTrue(source.contains("enum MainWindowDestination"))
        XCTAssertTrue(source.contains("case today"))
        XCTAssertTrue(source.contains("case recordings"))
        XCTAssertTrue(source.contains("TodayAgendaView("))
        XCTAssertTrue(source.contains("Button(\"Today\")"))
        XCTAssertTrue(source.contains("Button(\"Recordings\")"))
        XCTAssertTrue(source.contains("Label(\"Settings\", systemImage: \"gearshape\")"))
        XCTAssertFalse(source.contains("Text(\"Meetings\")"))
    }

    func testTodayAgendaViewDefinesAgendaRowsAndExplicitEditorSaveCancel() throws {
        let source = try appSource(named: "TodayAgendaView.swift")

        XCTAssertTrue(source.contains("struct TodayAgendaView"))
        XCTAssertTrue(source.contains("AgendaRowView"))
        XCTAssertTrue(source.contains("AgendaEditorView"))
        XCTAssertTrue(source.contains("Open Workspace"))
        XCTAssertTrue(source.contains("Start Recording"))
        XCTAssertTrue(source.contains("Open Transcript"))
        XCTAssertTrue(source.contains("Create Meeting"))
        XCTAssertTrue(source.contains("Button(\"Save\")"))
        XCTAssertTrue(source.contains("Button(\"Cancel\")"))
        XCTAssertTrue(source.contains("Save / Discard / Cancel"))
    }

    func testLiveWorkspaceShowsAgendaContextStrip() throws {
        let source = try appSource(named: "MainWindowView.swift")

        XCTAssertTrue(source.contains("AgendaContextStrip("))
        XCTAssertTrue(source.contains("meeting.attendees"))
        XCTAssertTrue(source.contains("meeting.agendaTopics"))
        XCTAssertTrue(source.contains("meeting.meetingGoal?.title"))
    }

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

        XCTAssertTrue(source.contains("@State private var destination: MainWindowDestination = .today"))
        XCTAssertTrue(source.contains("SettingsView("))
        XCTAssertFalse(source.contains("\"Whisper Binary Path\""))
        XCTAssertFalse(source.contains("\"Whisper Model Path\""))
        XCTAssertFalse(source.contains("\"STT Locale\""))
    }

    func testRecordingsRowsUseListSelectionTags() throws {
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
        XCTAssertTrue(source.contains("destination = .settings"))
    }

    func testSidebarTitleUsesCommandCenterStylingInsteadOfSystemNavigationTitle() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MeetingAgentApp/MainWindowView.swift")
        let source = try String(contentsOf: sourceURL)

        XCTAssertTrue(source.contains("Text(\"Meeting Agent\")"))
        XCTAssertTrue(source.contains(".commandCenterEyebrow()"))
        XCTAssertFalse(source.contains(".navigationTitle(\"Meeting Agent\")"))
    }

    func testWindowToolbarUsesCommandCenterThemeBackground() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MeetingAgentApp/MainWindowView.swift")
        let source = try String(contentsOf: sourceURL)

        XCTAssertTrue(source.contains(".toolbarBackground(CommandCenterPalette.surface, for: .windowToolbar)"))
        XCTAssertTrue(source.contains(".toolbarBackground(.visible, for: .windowToolbar)"))
        XCTAssertTrue(source.contains(".toolbarColorScheme(.dark, for: .windowToolbar)"))
        XCTAssertTrue(source.contains(".foregroundStyle(CommandCenterPalette.text)"))
    }

    func testMainWindowRemovesUnimplementedLiveTranslationControls() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MeetingAgentApp/MainWindowView.swift")
        let source = try String(contentsOf: sourceURL)

        XCTAssertFalse(source.contains("Live Translation"))
        XCTAssertFalse(source.contains("Start Live Translation"))
        XCTAssertFalse(source.contains("Stop Live Translation"))
        XCTAssertFalse(source.contains("Send to call"))
        XCTAssertFalse(source.contains("Type what you want to say in Chinese or English"))
    }

    func testMeetingDetailShowsCurrentPipelineAndActualSTTSource() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MeetingAgentApp/MainWindowView.swift")
        let source = try String(contentsOf: sourceURL)

        XCTAssertTrue(source.contains("speechConfiguration: viewModel.speechConfiguration"))
        XCTAssertTrue(source.contains("Current Pipeline"))
        XCTAssertTrue(source.contains("Transcription Link"))
        XCTAssertTrue(source.contains("Transcription Model"))
        XCTAssertFalse(source.contains("Translation Link"))
        XCTAssertFalse(source.contains("Translation Model"))
        XCTAssertTrue(source.contains("Actual STT Source"))
        XCTAssertTrue(source.contains("actualTranscriptionSourceText(for: meeting)"))
    }

    func testMainWindowRemovesUnimplementedMeetingGoalDashboardStructure() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MeetingAgentApp/MainWindowView.swift")
        let source = try String(contentsOf: sourceURL)

        XCTAssertFalse(source.contains("LiveMeetingDashboardView"))
        XCTAssertTrue(source.contains("UnifiedTranscriptView"))
        XCTAssertFalse(source.contains("GoalStatusPanel"))
        XCTAssertFalse(source.contains("SuggestedQuestionRow"))
        XCTAssertFalse(source.contains("LiveHealthChip"))
    }

    func testTranscriptPaneUsesUnifiedTranscriptSurface() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MeetingAgentApp/MainWindowView.swift")
        let source = try String(contentsOf: sourceURL)

        XCTAssertTrue(source.contains("UnifiedTranscriptView("))
        XCTAssertTrue(source.contains("BilingualTranscriptRow("))
        XCTAssertTrue(source.contains("LiveCaptionDisplayState("))
        XCTAssertTrue(source.contains("ScrollViewReader"))
        XCTAssertTrue(source.contains("LazyVStack"))
        XCTAssertFalse(source.contains("Text(\"Live Captions\")"))
        XCTAssertFalse(source.contains("ForEach(liveCaptionTurns.suffix(8))"))
        XCTAssertFalse(source.contains("Text(turn.isFinal ? \"final\" : \"partial\")"))
        XCTAssertFalse(source.contains("\" turns\""))
    }

    func testUnifiedTranscriptPreservesFallbackAndQuietCorrectionControls() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MeetingAgentApp/MainWindowView.swift")
        let source = try String(contentsOf: sourceURL)

        XCTAssertTrue(source.contains("transcriptText.isEmpty"))
        XCTAssertTrue(source.contains("returnToLatest"))
        XCTAssertTrue(source.contains("translation unavailable"))
        XCTAssertTrue(source.contains("Translating"))
        XCTAssertTrue(source.contains("Button(\"Edit name\")"))
        XCTAssertTrue(source.contains("Image(systemName: \"pencil\")"))
    }

    func testExportsPanelExposesImplementedExportActionsOnly() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MeetingAgentApp/MainWindowView.swift")
        let source = try String(contentsOf: sourceURL)

        XCTAssertTrue(source.contains("exportSRT"))
        XCTAssertTrue(source.contains("exportVTT"))
        XCTAssertTrue(source.contains("Label(\"SRT\", systemImage: \"captions.bubble\")"))
        XCTAssertTrue(source.contains("Label(\"VTT\", systemImage: \"captions.bubble\")"))
        XCTAssertTrue(source.contains("viewModel.exportSubtitles(for: meeting.id, format: .srt"))
        XCTAssertTrue(source.contains("viewModel.exportSubtitles(for: meeting.id, format: .vtt"))
        XCTAssertFalse(source.contains("exportReadinessReport"))
        XCTAssertFalse(source.contains("Readiness Report"))
    }

    func testLiveCaptionsExposeCorrectionControls() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MeetingAgentApp/MainWindowView.swift")
        let source = try String(contentsOf: sourceURL)

        XCTAssertTrue(source.contains("updateSpeakerLabel"))
        XCTAssertTrue(source.contains("updateTranscriptSegmentText"))
        XCTAssertTrue(source.contains("CaptionEditSheet"))
        XCTAssertTrue(source.contains("Menu {"))
        XCTAssertTrue(source.contains("Button(\"Edit name\")"))
        XCTAssertTrue(source.contains("Image(systemName: \"chevron.down\")"))
        XCTAssertFalse(source.contains("person.crop.circle.badge.pencil"))
        XCTAssertTrue(source.contains("Image(systemName: \"pencil\")"))
        XCTAssertTrue(source.contains("Correct Caption"))
        XCTAssertTrue(source.contains("Save Speaker"))
        XCTAssertTrue(source.contains("Save Caption"))
    }

    func testMainWindowRemovesUnimplementedMeetingGoalComposer() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MeetingAgentApp/MainWindowView.swift")
        let source = try String(contentsOf: sourceURL)

        XCTAssertFalse(source.contains("GoalComposerPanel"))
        XCTAssertFalse(source.contains("TextField(\"Goal title\""))
        XCTAssertFalse(source.contains("LabeledTextEditor(title: \"Objectives\""))
        XCTAssertFalse(source.contains("LabeledTextEditor(title: \"Required Questions\""))
        XCTAssertFalse(source.contains("LabeledTextEditor(title: \"Key Terms\""))
        XCTAssertFalse(source.contains("Label(\"Apply Goal\", systemImage: \"target\")"))
        XCTAssertFalse(source.contains("setMeetingGoal(buildGoal())"))
        XCTAssertFalse(source.contains("meetingGoal: viewModel.meetingGoal"))
        XCTAssertFalse(source.contains("draftGoal: meetingGoal"))
    }

    private func appSource(named fileName: String) throws -> String {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MeetingAgentApp")
            .appendingPathComponent(fileName)
        return try String(contentsOf: sourceURL)
    }
}
