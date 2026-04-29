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

    func testMainWindowRoutesThroughMeetingRecordBuckets() throws {
        let source = try appSource(named: "MainWindowView.swift")

        XCTAssertTrue(source.contains("enum MainWindowDestination"))
        XCTAssertTrue(source.contains("case today"))
        XCTAssertTrue(source.contains("case thisWeek"))
        XCTAssertTrue(source.contains("case history"))
        XCTAssertTrue(source.contains("TodayAgendaView("))
        XCTAssertTrue(source.contains("Button(\"Today\")"))
        XCTAssertTrue(source.contains("Button(\"This Week\")"))
        XCTAssertTrue(source.contains("Button(\"History\")"))
        XCTAssertTrue(source.contains("Label(\"Settings\", systemImage: \"gearshape\")"))
        XCTAssertTrue(source.contains("meetings(for: destination)"))
        XCTAssertTrue(source.contains("TodayAgendaView("))
        XCTAssertTrue(source.contains("case .today, .thisWeek, .history:"))
        XCTAssertTrue(source.contains("agendaEmptyTitle(for: destination)"))
        XCTAssertTrue(source.contains("agendaEmptyDescription(for: destination)"))
        XCTAssertTrue(source.contains("meetingDisplayDate(_ meeting: MeetingRecord)"))
        XCTAssertTrue(source.contains("meeting.scheduledStartAt ?? meeting.startedAt"))
        XCTAssertTrue(source.contains("No meetings scheduled today"))
        XCTAssertTrue(source.contains("No meetings scheduled this week"))
        XCTAssertTrue(source.contains("No meeting history"))
        XCTAssertFalse(source.contains("Button(\"Recordings\")"))
        XCTAssertFalse(source.contains("Text(\"Recent Recordings\")"))
        XCTAssertFalse(source.contains("Text(\"Meetings\")"))
    }

    func testSidebarBucketNavigationDoesNotRenderMeetingSelectionList() throws {
        let source = try appSource(named: "MainWindowView.swift")

        XCTAssertFalse(source.contains("List(selection: Binding("))
        XCTAssertFalse(source.contains(".tag(Optional(meeting.id))"))
        XCTAssertFalse(source.contains("meetingListTitle(for: destination)"))
    }

    func testSidebarNavigationRowsDefineFullWidthHitArea() throws {
        let source = try appSource(named: "MainWindowView.swift")

        guard let styleRange = source.range(of: "private struct SidebarNavigationButtonStyle") else {
            return XCTFail("Sidebar navigation button style is missing")
        }
        guard let nextViewRange = source.range(of: "private struct MeetingDetailView", range: styleRange.upperBound..<source.endIndex) else {
            return XCTFail("Sidebar navigation button style boundary is missing")
        }

        let styleSource = source[styleRange.lowerBound..<nextViewRange.lowerBound]
        XCTAssertTrue(styleSource.contains(".frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)"))
        XCTAssertTrue(styleSource.contains(".contentShape(Rectangle())"))
    }

    func testMeetingBucketsUseCalendarBoundaries() throws {
        let source = try appSource(named: "MainWindowView.swift")

        XCTAssertTrue(source.contains("TodayAgendaView("))
        XCTAssertTrue(source.contains("meetings: meetings(for: destination)"))
        XCTAssertTrue(source.contains("calendar.isDate(meetingDate, inSameDayAs: now)"))
        XCTAssertTrue(source.contains("calendar.isDate(meetingDate, equalTo: now, toGranularity: .weekOfYear)"))
        XCTAssertTrue(source.contains("calendar.isDate(meetingDate, equalTo: now, toGranularity: .yearForWeekOfYear)"))
        XCTAssertTrue(source.contains("return viewModel.meetings.filter { isThisWeek($0) && !isToday($0) }"))
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

    func testTodayAgendaRefreshesCleanDraftWhenSelectedMeetingRecordChanges() throws {
        let source = try appSource(named: "TodayAgendaView.swift")

        XCTAssertTrue(source.contains("@State private var recordBackedDraft = AgendaDraft()"))
        XCTAssertTrue(source.contains("draft == recordBackedDraft"))
        XCTAssertTrue(source.contains("recordBackedDraft = draft"))
        XCTAssertTrue(source.contains("resetDraftFromSelection()"))
    }

    func testLiveWorkspaceShowsAgendaContextStrip() throws {
        let source = try appSource(named: "MainWindowView.swift")

        XCTAssertTrue(source.contains("AgendaContextStrip("))
        XCTAssertTrue(source.contains("meeting.attendees"))
        XCTAssertTrue(source.contains("meeting.agendaTopics"))
        XCTAssertTrue(source.contains("meeting.meetingGoal?.title"))
    }

    func testCurrentPipelineMovesDebugDetailsBehindHoverIcon() throws {
        let source = try appSource(named: "MainWindowView.swift")

        guard let metadataRange = source.range(of: "private var metadata: some View") else {
            return XCTFail("Pipeline metadata section is missing")
        }
        guard let actionsRange = source.range(of: "private var recordingActions: some View", range: metadataRange.upperBound..<source.endIndex) else {
            return XCTFail("Recording actions section is missing")
        }

        let metadataSource = source[metadataRange.lowerBound..<actionsRange.lowerBound]
        XCTAssertTrue(metadataSource.contains("Image(systemName: \"exclamationmark.circle\")"))
        XCTAssertTrue(metadataSource.contains(".help(pipelineDebugHelpText)"))
        XCTAssertTrue(metadataSource.contains("CommandCenterChip(title: transcriptionStatusText"))
        XCTAssertFalse(metadataSource.contains("CommandCenterChip(title: pipelineDisplayName"))
        XCTAssertFalse(metadataSource.contains("CommandCenterChip(title: \"Actual STT Source:"))
        XCTAssertFalse(metadataSource.contains("CommandCenterChip(title: \"Transcription Link:"))
        XCTAssertFalse(metadataSource.contains("CommandCenterChip(title: \"Transcription Model:"))
        XCTAssertFalse(metadataSource.contains("CommandCenterChip(title: \"Preflight:"))
        XCTAssertTrue(source.contains("\"Pipeline: \\(pipelineDisplayName)\""))
        XCTAssertTrue(source.contains("\"Transcript Latency: \\(transcriptLatencyText)\""))
        XCTAssertTrue(source.contains("\"Translation Latency: \\(translationLatencyText)\""))
        XCTAssertTrue(source.contains("meeting.performanceEventsURL"))
        XCTAssertTrue(source.contains("PerformanceEvent.self"))
        XCTAssertTrue(source.contains("translationRequestID"))
        XCTAssertTrue(source.contains("caption_translation_scheduled"))
        XCTAssertTrue(source.contains("caption_translation_attached"))
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

    func testInsightsPaneShowsRecommendedQuestionsOnlyWhenAvailable() throws {
        let source = try appSource(named: "MainWindowView.swift")

        XCTAssertTrue(source.contains("recommendedQuestions: viewModel.recommendedQuestions"))
        XCTAssertTrue(source.contains("let recommendedQuestions: [FollowUpQuestionSuggestion]"))
        XCTAssertTrue(source.contains("if !recommendedQuestions.isEmpty"))
        XCTAssertTrue(source.contains("RecommendedQuestionsPanel(questions: recommendedQuestions)"))
        XCTAssertTrue(source.contains("Text(\"Recommended Questions\").commandCenterEyebrow()"))
        XCTAssertTrue(source.contains("ForEach(Array(questions.prefix(2)))"))
        XCTAssertFalse(source.contains("No recommended questions"))
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

    func testMeetingRowsDoNotUseSidebarListSelectionTags() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MeetingAgentApp/MainWindowView.swift")
        let source = try String(contentsOf: sourceURL)

        XCTAssertFalse(source.contains("List(selection: Binding("))
        XCTAssertFalse(source.contains(".tag(Optional(meeting.id))"))
        XCTAssertFalse(source.contains(".onTapGesture {\n                            viewModel.selectMeeting(meeting.id)"))
    }

    func testDetectedMeetingStartRecordingOpensMeetingDetail() throws {
        let source = try appSource(named: "MainWindowView.swift")

        guard let alertButtonRange = source.range(of: "Button(\"Start Recording\")") else {
            return XCTFail("Detected meeting Start Recording button is missing")
        }
        guard let notNowRange = source.range(of: "Button(\"Not Now\"", range: alertButtonRange.upperBound..<source.endIndex) else {
            return XCTFail("Detected meeting Not Now button is missing")
        }

        let startRecordingAction = source[alertButtonRange.lowerBound..<notNowRange.lowerBound]
        XCTAssertTrue(startRecordingAction.contains("try await viewModel.startRecording(for: target)"))
        XCTAssertTrue(startRecordingAction.contains("destination = .workspace"))
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
        XCTAssertTrue(source.contains("BilingualTranscriptBlock("))
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
        XCTAssertFalse(source.contains("Image(systemName: \"pencil\")"))
    }

    func testUnifiedTranscriptRendersSpeakerGroupsInsteadOfOneLabelPerBlock() throws {
        let source = try String(contentsOfFile: "Sources/MeetingAgentApp/MainWindowView.swift")

        XCTAssertTrue(source.contains("LiveCaptionSpeakerGroup.groups(from: turns)"))
        XCTAssertTrue(source.contains("ForEach(group.turns)"))
        XCTAssertTrue(source.contains("BilingualTranscriptBlock"))
    }

    func testTranslatedTranscriptBlocksRenderSourceBeforeTranslation() throws {
        let source = try String(contentsOfFile: "Sources/MeetingAgentApp/MainWindowView.swift")

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

    func testTranscriptBlocksKeepSourceTextWhiteWhileTranslationIsPending() throws {
        let source = try String(contentsOfFile: "Sources/MeetingAgentApp/MainWindowView.swift")

        guard let pendingCaseRange = source.range(of: "case .pending(let sourceText):") else {
            return XCTFail("Pending transcript branch is missing")
        }
        guard let failedCaseRange = source.range(of: "case .failed", range: pendingCaseRange.upperBound..<source.endIndex) else {
            return XCTFail("Pending transcript branch end is missing")
        }

        let pendingBranch = source[pendingCaseRange.lowerBound..<failedCaseRange.lowerBound]
        XCTAssertTrue(pendingBranch.contains("Text(sourceText)"))
        XCTAssertTrue(pendingBranch.contains(".foregroundStyle(CommandCenterPalette.text)"))
    }

    func testUnifiedTranscriptUsesStableSpeakerGroupIDsAndTurnScrollAnchors() throws {
        let source = try String(contentsOfFile: "Sources/MeetingAgentApp/MainWindowView.swift")

        XCTAssertTrue(source.contains(".id(group.id)"))
        XCTAssertTrue(source.contains(".id(turn.id)"))
        XCTAssertFalse(source.contains(".id(group.turns.last?.id ?? group.id)"))
    }

    func testBilingualTranscriptBlockDoesNotReserveBlankEditControlSpace() throws {
        let source = try String(contentsOfFile: "Sources/MeetingAgentApp/MainWindowView.swift")

        XCTAssertTrue(source.contains("transcriptText\n            .frame(maxWidth: .infinity, alignment: .leading)"))
        XCTAssertFalse(source.contains("""
            HStack(spacing: 8) {
                Spacer()
"""))
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

    func testLiveCaptionsHideCaptionCorrectionWhileKeepingSpeakerEdit() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MeetingAgentApp/MainWindowView.swift")
        let source = try String(contentsOf: sourceURL)

        XCTAssertTrue(source.contains("updateSpeakerLabel"))
        XCTAssertTrue(source.contains("CaptionEditSheet"))
        XCTAssertTrue(source.contains("Menu {"))
        XCTAssertTrue(source.contains("Button(\"Edit name\")"))
        XCTAssertTrue(source.contains("Image(systemName: \"chevron.down\")"))
        XCTAssertTrue(source.contains("Save Speaker"))

        XCTAssertFalse(source.contains("updateTranscriptSegmentText"))
        XCTAssertFalse(source.contains("Correct Caption"))
        XCTAssertFalse(source.contains("Save Caption"))
        XCTAssertFalse(source.contains("Image(systemName: \"pencil\")"))
        XCTAssertFalse(source.contains("person.crop.circle.badge.pencil"))
    }

    func testUnifiedTranscriptRendersSpeakerGroupStartTimeBesideSpeakerName() throws {
        let source = try appSource(named: "MainWindowView.swift")

        XCTAssertTrue(source.contains("speakerStartTimeText"))
        XCTAssertTrue(source.contains("group.startedAt.formatted(date: .omitted, time: .standard)"))
        XCTAssertTrue(source.contains("Text(speakerStartTimeText)"))
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
