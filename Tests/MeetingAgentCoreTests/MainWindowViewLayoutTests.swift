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
        XCTAssertTrue(source.contains("case meetings"))
        XCTAssertTrue(source.contains("case library"))
        XCTAssertTrue(source.contains("TodayAgendaView("))
        XCTAssertTrue(source.contains("Button(\"Today\")"))
        XCTAssertTrue(source.contains("Button(\"Meetings\")"))
        XCTAssertTrue(source.contains("Button(\"Library\")"))
        XCTAssertTrue(source.contains("Label(\"Settings\", systemImage: \"gearshape\")"))
        XCTAssertTrue(source.contains("meetings(for: destination)"))
        XCTAssertTrue(source.contains("TodayAgendaView("))
        XCTAssertTrue(source.contains("mode: agendaMode(for: destination)"))
        XCTAssertTrue(source.contains("case .today, .meetings, .library:"))
        XCTAssertTrue(source.contains("case .library:"))
        XCTAssertTrue(source.contains("return .library"))
        XCTAssertTrue(source.contains("agendaEmptyTitle(for: destination)"))
        XCTAssertTrue(source.contains("agendaEmptyDescription(for: destination)"))
        XCTAssertTrue(source.contains("meetingDisplayDate(_ meeting: MeetingRecord)"))
        XCTAssertTrue(source.contains("meeting.scheduledStartAt ?? meeting.startedAt"))
        XCTAssertTrue(source.contains("No meetings scheduled today"))
        XCTAssertTrue(source.contains("No scheduled meetings"))
        XCTAssertTrue(source.contains("No meeting library items"))
        XCTAssertFalse(source.contains("Button(\"Recordings\")"))
        XCTAssertFalse(source.contains("Text(\"Recent Recordings\")"))
        XCTAssertFalse(source.contains("Button(\"This Week\")"))
        XCTAssertFalse(source.contains("Button(\"History\")"))
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
        XCTAssertTrue(source.contains("return viewModel.meetings.filter { !isCompleted($0) }"))
        XCTAssertTrue(source.contains("return viewModel.meetings.filter { isCompleted($0) }"))
    }

    func testTodayAgendaViewDefinesAgendaRowsAndExplicitEditorSaveCancel() throws {
        let source = try appSource(named: "TodayAgendaView.swift")

        XCTAssertTrue(source.contains("struct TodayAgendaView"))
        XCTAssertTrue(source.contains("enum AgendaListMode"))
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

    func testTodayAgendaUsesTodayWorkflowSections() throws {
        let source = try appSource(named: "TodayAgendaView.swift")

        XCTAssertTrue(source.contains("AgendaFeedSection(title: \"Today\""))
        XCTAssertTrue(source.contains("AgendaFeedSection(title: \"Completed Today\""))
        XCTAssertTrue(source.contains("completedTodayMeetings"))
        XCTAssertTrue(source.contains("MeetingArtifactCard"))
        XCTAssertTrue(source.contains("mode == .today"))
        XCTAssertTrue(source.contains("mode == .library"))
        XCTAssertTrue(source.contains("artifactList"))
        XCTAssertTrue(source.contains("if showsAgendaEditor"))
        XCTAssertFalse(source.contains("recentGroups"))
        XCTAssertFalse(source.contains("recentHistoryDays"))
        XCTAssertFalse(source.contains("RecentAgendaMeetingCard"))
        XCTAssertTrue(source.contains("Meeting schedule and metadata"))
        XCTAssertTrue(source.contains("let selected = editableMeetings.first(where: { $0.id == selectedMeetingID })"))
        XCTAssertTrue(source.contains("Summary ready"))
        XCTAssertTrue(source.contains("Transcript ready"))
        XCTAssertTrue(source.contains("Artifacts pending"))
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

    func testMeetingWorkspaceBackButtonReturnsToSourceBucket() throws {
        let source = try appSource(named: "MainWindowView.swift")

        XCTAssertTrue(source.contains("@State private var workspaceReturnDestination: MainWindowDestination = .today"))
        XCTAssertTrue(source.contains("private func openWorkspace(from destination: MainWindowDestination, selecting meeting: MeetingRecord)"))
        XCTAssertTrue(source.contains("workspaceReturnDestination = destination.agendaReturnDestination"))
        XCTAssertTrue(source.contains("let returnDestination = destination.agendaReturnDestination"))
        XCTAssertTrue(source.contains("workspaceReturnDestination = returnDestination"))
        XCTAssertTrue(source.contains("destination = .workspace"))
        XCTAssertTrue(source.contains("var agendaReturnDestination: MainWindowDestination"))
        XCTAssertTrue(source.contains("case .today, .meetings, .library:"))
        XCTAssertTrue(source.contains("case .workspace, .settings:"))
        XCTAssertTrue(source.contains("return .today"))
        XCTAssertFalse(source.contains("case .today, .thisWeek, .history:"))
    }

    func testMeetingWorkspaceRendersBackButton() throws {
        let source = try appSource(named: "MainWindowView.swift")

        XCTAssertTrue(source.contains("backToMeetings: {"))
        XCTAssertTrue(source.contains("destination = workspaceReturnDestination"))
        XCTAssertTrue(source.contains("let backToMeetings: () -> Void"))
        XCTAssertTrue(source.contains("Button(action: backToMeetings)"))
        XCTAssertTrue(source.contains("Label(\"Back\", systemImage: \"chevron.left\")"))
    }

    func testCurrentPipelineMovesDebugDetailsBehindHoverIcon() throws {
        let source = try appSource(named: "MainWindowView.swift")

        guard let metadataRange = source.range(of: "private var metadata: some View") else {
            return XCTFail("Pipeline metadata section is missing")
        }
        guard let failureReasonRange = source.range(of: "private var failureReason: some View", range: metadataRange.upperBound..<source.endIndex) else {
            return XCTFail("Pipeline metadata boundary is missing")
        }

        let metadataSource = source[metadataRange.lowerBound..<failureReasonRange.lowerBound]
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

    func testMeetingWorkspaceConsolidatesActionsIntoTopRow() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MeetingAgentApp/MainWindowView.swift")
        let source = try String(contentsOf: sourceURL)

        guard let workspaceRange = source.range(of: "private struct MeetingCommandCenterView") else {
            return XCTFail("Meeting workspace view is missing")
        }
        guard let agendaRange = source.range(of: "private struct AgendaContextStrip", range: workspaceRange.upperBound..<source.endIndex) else {
            return XCTFail("Meeting workspace boundary is missing")
        }
        let workspaceSource = source[workspaceRange.lowerBound..<agendaRange.lowerBound]

        XCTAssertTrue(workspaceSource.contains("Label(\"Back\", systemImage: \"chevron.left\")"))
        XCTAssertTrue(workspaceSource.contains("Label(\"Stop Recording\", systemImage: \"stop.fill\")"))
        XCTAssertTrue(workspaceSource.contains("Label(\"Record\", systemImage: \"record.circle\")"))
        XCTAssertTrue(workspaceSource.contains("Menu {"))
        XCTAssertTrue(workspaceSource.contains("Image(systemName: \"ellipsis.circle\")"))
        XCTAssertTrue(workspaceSource.contains(".accessibilityLabel(\"Meeting actions\")"))
        XCTAssertTrue(workspaceSource.contains(".help(\"Meeting actions\")"))
        XCTAssertTrue(workspaceSource.contains("Label(\"Copy Summary\", systemImage: \"doc.on.clipboard\")"))
        XCTAssertTrue(workspaceSource.contains(".disabled(isRecording || meeting.summaryURL == nil)"))
        XCTAssertTrue(workspaceSource.contains("Label(\"Export Transcript\", systemImage: \"doc.text\")"))
        XCTAssertTrue(workspaceSource.contains(".disabled(isRecording || meeting.transcriptURL == nil)"))
        XCTAssertTrue(workspaceSource.contains("Label(\"Export Meeting JSON\", systemImage: \"curlybraces\")"))
        XCTAssertTrue(workspaceSource.contains("Label(\"Export SRT\", systemImage: \"captions.bubble\")"))
        XCTAssertTrue(workspaceSource.contains("Label(\"Export VTT\", systemImage: \"captions.bubble\")"))
        XCTAssertTrue(workspaceSource.contains("Label(\"Retry Transcription\", systemImage: \"arrow.clockwise\")"))
        XCTAssertTrue(workspaceSource.contains(".disabled(isRecording || meeting.audioURL == nil)"))

        guard let transcriptRange = source.range(of: "private struct TranscriptPaneView") else {
            return XCTFail("Transcript pane is missing")
        }
        guard let insightRange = source.range(of: "private struct InsightPaneView", range: transcriptRange.upperBound..<source.endIndex) else {
            return XCTFail("Insight pane boundary is missing")
        }
        let transcriptSource = source[transcriptRange.lowerBound..<insightRange.lowerBound]
        XCTAssertFalse(transcriptSource.contains("private var recordingActions: some View"))
        XCTAssertFalse(transcriptSource.contains("Button(\"Retry Transcription\")"))

        guard let nextViewRange = source.range(of: "private struct RecommendedQuestionsPanel", range: insightRange.upperBound..<source.endIndex) else {
            return XCTFail("Insight pane boundary is missing")
        }
        let insightSource = source[insightRange.lowerBound..<nextViewRange.lowerBound]
        XCTAssertFalse(insightSource.contains("private var exports: some View"))
        XCTAssertFalse(insightSource.contains("Text(\"Exports\")"))
    }

    func testSummaryDownloadAndRegenerateControlsAreRemoved() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MeetingAgentApp/MainWindowView.swift")
        let source = try String(contentsOf: sourceURL)

        XCTAssertFalse(source.contains("Label(\"Summary\", systemImage: \"text.badge.checkmark\")"))
        XCTAssertFalse(source.contains("Button(\"Regenerate Summary\")"))
    }

    func testInsightPaneDoesNotRenderSummaryStatusBadges() throws {
        let source = try appSource(named: "MainWindowView.swift")

        guard let insightRange = source.range(of: "private struct InsightPaneView") else {
            return XCTFail("InsightPaneView is missing")
        }
        guard let summaryListRange = source.range(of: "private struct SummaryListView", range: insightRange.upperBound..<source.endIndex) else {
            return XCTFail("InsightPaneView boundary is missing")
        }

        let insightSource = source[insightRange.lowerBound..<summaryListRange.lowerBound]
        XCTAssertTrue(insightSource.contains("Text(\"Summary\").commandCenterEyebrow()"))
        XCTAssertTrue(insightSource.contains("Meeting summary will appear here after recording stops."))
        XCTAssertFalse(insightSource.contains("\"ACTIVE\""))
        XCTAssertFalse(insightSource.contains("\"RECORDED\""))
        XCTAssertFalse(insightSource.contains("\"Summary pending\""))
        XCTAssertFalse(insightSource.contains("\"Summary ready\""))
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

    func testMeetingDetailAllowsEditingAgendaGoalThroughSaveAgenda() throws {
        let source = try appSource(named: "MainWindowView.swift")

        XCTAssertTrue(source.contains("saveAgenda: { meetingID, update in"))
        XCTAssertTrue(source.contains("editAgenda: beginDetailAgendaEdit"))
        XCTAssertTrue(source.contains("editAgendaTarget = meeting"))
        XCTAssertTrue(source.contains("AgendaEditorView("))
        XCTAssertTrue(source.contains("try saveAgenda(meetingID, draft.update())"))
        XCTAssertTrue(source.contains("Label(\"Edit Agenda\", systemImage: \"square.and.pencil\")"))

        let agendaSource = try appSource(named: "TodayAgendaView.swift")
        XCTAssertTrue(agendaSource.contains("labeledTextEditor(\"Meeting Goal\", text: $draft.goalText)"))
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

    func testActionMenuExposesImplementedExportActionsOnly() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MeetingAgentApp/MainWindowView.swift")
        let source = try String(contentsOf: sourceURL)

        XCTAssertTrue(source.contains("exportSRT"))
        XCTAssertTrue(source.contains("exportVTT"))
        XCTAssertTrue(source.contains("Label(\"Export SRT\", systemImage: \"captions.bubble\")"))
        XCTAssertTrue(source.contains("Label(\"Export VTT\", systemImage: \"captions.bubble\")"))
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
