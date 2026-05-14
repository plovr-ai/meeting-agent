import AppKit
import MeetingAgentCore
import SwiftUI

private enum MainWindowDestination: Hashable {
    case today
    case meetings
    case library
    case workspace
    case settings
}

struct MainWindowView: View {
    @ObservedObject var viewModel: MeetingAgentViewModel
    @State private var destination: MainWindowDestination = .today
    @State private var workspaceReturnDestination: MainWindowDestination = .today

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                VStack(spacing: 6) {
                    Text("Meeting Agent")
                        .font(CommandCenterTypography.sectionTitle)
                        .foregroundStyle(CommandCenterPalette.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 6)

                    Button("Today") {
                        destination = .today
                    }
                    .buttonStyle(SidebarNavigationButtonStyle(isSelected: destination == .today))

                    Button("Meetings") {
                        destination = .meetings
                    }
                    .buttonStyle(SidebarNavigationButtonStyle(isSelected: destination == .meetings))

                    Button("Library") {
                        destination = .library
                    }
                    .buttonStyle(SidebarNavigationButtonStyle(isSelected: destination == .library))
                }
                .padding(12)

                Spacer()

                Divider()
                    .overlay(CommandCenterPalette.border)

                Button {
                    destination = .settings
                } label: {
                    Label("Settings", systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(destination == .settings ? CommandCenterPalette.primary : CommandCenterPalette.text)
                .padding(12)
                .background(destination == .settings ? CommandCenterPalette.primary.opacity(0.12) : Color.clear)
            }
            .background(CommandCenterPalette.surface)
            .frame(minWidth: 180, idealWidth: 210)
        } detail: {
            switch destination {
            case .settings:
                SettingsView(
                    configuration: viewModel.speechConfiguration,
                    profiles: BilingualPipelineFactory.builtInProfiles,
                    localeIdentifiers: MeetingAgentViewModel.supportedLocaleIdentifiers,
                    isRecording: viewModel.isRecording,
                    status: viewModel.speechConfigurationStatus,
                    primaryChainPreflightResult: viewModel.primaryChainPreflightResult,
                    save: { viewModel.saveSpeechConfiguration($0) }
                )
            case .today, .meetings, .library:
                TodayAgendaView(
                    mode: agendaMode(for: destination),
                    title: agendaTitle(for: destination),
                    emptyTitle: agendaEmptyTitle(for: destination),
                    emptyDescription: agendaEmptyDescription(for: destination),
                    meetings: meetings(for: destination),
                    selectedMeetingID: viewModel.selectedMeetingID,
                    activeMeetingID: viewModel.activeMeetingID,
                    pendingCandidate: viewModel.pendingCandidate,
                    isRecording: viewModel.isRecording,
                    openWorkspace: { meeting in
                        openWorkspace(from: destination, selecting: meeting)
                    },
                    startRecording: { meeting in
                        guard let target = viewModel.pendingCandidate else {
                            openWorkspace(from: destination, selecting: meeting)
                            return
                        }
                        let returnDestination = destination.agendaReturnDestination
                        Task {
                            do {
                                try await viewModel.startRecording(for: target, meetingID: meeting.id)
                                workspaceReturnDestination = returnDestination
                                destination = .workspace
                            } catch {
                                viewModel.setRecordingStartError(error)
                            }
                        }
                    },
                    startOfflineRecording: {
                        let returnDestination = destination.agendaReturnDestination
                        Task {
                            do {
                                try await viewModel.startOfflineMicrophoneRecording()
                                workspaceReturnDestination = returnDestination
                                destination = .workspace
                            } catch {
                                viewModel.setRecordingStartError(error)
                            }
                        }
                    },
                    createMeeting: destination == .today ? {
                        try viewModel.createAgendaMeeting()
                    } : nil
                )
            case .workspace:
                MeetingDetailView(
                    meeting: viewModel.selectedMeeting,
                    speechConfiguration: viewModel.speechConfiguration,
                    primaryChainPreflightResult: viewModel.primaryChainPreflightResult,
                    statusText: viewModel.statusText,
                    isRecording: viewModel.isRecording,
                    liveCaptionTurns: viewModel.liveCaptionTurns,
                    recommendedQuestions: viewModel.recommendedQuestions,
                    meetingProgressState: viewModel.meetingProgressState,
                    backToMeetings: {
                        destination = workspaceReturnDestination
                    },
                    saveAgenda: { meetingID, update in
                        try viewModel.saveAgenda(for: meetingID, update: update)
                    },
                    stopRecording: {
                        Task {
                            do {
                                try await viewModel.stopRecordingAndGenerateSummary()
                            } catch {
                                viewModel.setRecordingStartError(error)
                            }
                        }
                    },
                    copySummary: { meeting in
                        copySummary(for: meeting)
                    },
                    exportTranscript: { meeting in
                        export("transcript.txt", for: meeting) { destination in
                            try viewModel.exportTranscript(for: meeting.id, to: destination)
                        }
                    },
                    exportMeetingData: { meeting in
                        export("meeting.json", for: meeting) { destination in
                            try viewModel.exportMeetingData(for: meeting.id, to: destination)
                        }
                    },
                    exportSRT: { meeting in
                        export("captions.srt", for: meeting) { destination in
                            try viewModel.exportSubtitles(for: meeting.id, format: .srt, to: destination)
                        }
                    },
                    exportVTT: { meeting in
                        export("captions.vtt", for: meeting) { destination in
                            try viewModel.exportSubtitles(for: meeting.id, format: .vtt, to: destination)
                        }
                    },
                    exportKnowledgePackage: { meeting in
                        export("knowledge-package", for: meeting) { destination in
                            try viewModel.exportKnowledgePackage(for: meeting.id, to: destination)
                        }
                    },
                    retryTranscription: { meeting in
                        Task {
                            await viewModel.retryTranscription(for: meeting.id)
                        }
                    },
                    updateSpeakerLabel: { meeting, speakerID, label in
                        Task {
                            do {
                                try await viewModel.updateSpeakerLabel(for: meeting.id, speakerID: speakerID, label: label)
                            } catch {
                                NSSound.beep()
                            }
                        }
                    }
                )
            }
        }
        .background(CommandCenterPalette.window)
        .foregroundStyle(CommandCenterPalette.text)
        .toolbarBackground(CommandCenterPalette.surface, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbarColorScheme(.dark, for: .windowToolbar)
        .alert(
            "Meeting detected",
            isPresented: Binding(
                get: { viewModel.pendingCandidate != nil },
                set: { _ in }
            ),
            presenting: viewModel.pendingCandidate
        ) { target in
            Button("Start Recording") {
                Task {
                    do {
                        try await viewModel.startRecording(for: target)
                        destination = .workspace
                    } catch {
                        viewModel.setRecordingStartError(error)
                    }
                }
            }
            Button("Not Now", role: .cancel) {
                viewModel.ignorePendingCandidate()
            }
        } message: { target in
            Text("\(target.displayName) detected. Start recording?")
        }
    }

    private func openWorkspace(from destination: MainWindowDestination, selecting meeting: MeetingRecord) {
        workspaceReturnDestination = destination.agendaReturnDestination
        viewModel.selectMeeting(meeting.id)
        self.destination = .workspace
    }

    private func meetings(for destination: MainWindowDestination) -> [MeetingRecord] {
        switch destination {
        case .today:
            return viewModel.meetings.filter { isToday($0) }
        case .meetings:
            return viewModel.meetings.filter { !isCompleted($0) }
        case .library:
            return viewModel.meetings.filter { isCompleted($0) }
        case .workspace:
            return viewModel.meetings
        case .settings:
            return []
        }
    }

    private func agendaTitle(for destination: MainWindowDestination) -> String {
        switch destination {
        case .today:
            return "Today"
        case .meetings:
            return "Meetings"
        case .library:
            return "Library"
        case .workspace:
            return "All Meetings"
        case .settings:
            return "Meetings"
        }
    }

    private func agendaMode(for destination: MainWindowDestination) -> AgendaListMode {
        switch destination {
        case .today:
            return .today
        case .meetings:
            return .meetings
        case .library:
            return .library
        case .workspace, .settings:
            return .meetings
        }
    }

    private func agendaEmptyTitle(for destination: MainWindowDestination) -> String {
        switch destination {
        case .today:
            return "No meetings scheduled today"
        case .meetings:
            return "No scheduled meetings"
        case .library:
            return "No meeting library items"
        case .workspace:
            return "No meetings"
        case .settings:
            return ""
        }
    }

    private func agendaEmptyDescription(for destination: MainWindowDestination) -> String {
        switch destination {
        case .today:
            return "Create a local agenda item to prepare attendees, topics, and meeting goals before recording."
        case .meetings:
            return "Scheduled meetings will appear here with their agenda details."
        case .library:
            return "Completed meetings will appear here with their transcripts, summaries, and exports."
        case .workspace, .settings:
            return ""
        }
    }

    private func isToday(_ meeting: MeetingRecord, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let meetingDate = meetingDisplayDate(meeting)
        return calendar.isDate(meetingDate, inSameDayAs: now)
    }

    private func isThisWeek(_ meeting: MeetingRecord, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let meetingDate = meetingDisplayDate(meeting)
        return calendar.isDate(meetingDate, equalTo: now, toGranularity: .weekOfYear)
            && calendar.isDate(meetingDate, equalTo: now, toGranularity: .yearForWeekOfYear)
    }

    private func isCompleted(_ meeting: MeetingRecord) -> Bool {
        if meeting.endedAt != nil {
            return true
        }
        switch meeting.transcriptionStatus {
        case .transcribed, .failed, .retryRequested:
            return true
        case .notStarted, .transcribing:
            return false
        }
    }

    private func meetingDisplayDate(_ meeting: MeetingRecord) -> Date {
        meeting.scheduledStartAt ?? meeting.startedAt
    }

    private func copySummary(for meeting: MeetingRecord) {
        do {
            let summary = try viewModel.summaryTextForClipboard(for: meeting.id)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(summary, forType: .string)
        } catch {
            NSSound.beep()
        }
    }

    private func export(_ suggestedName: String, for meeting: MeetingRecord, operation: (URL) throws -> Void) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(sanitizedFileNameComponent(meeting.name))-\(suggestedName)"
        panel.title = "Export \(suggestedName)"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try operation(url)
        } catch {
            NSSound.beep()
        }
    }

    private func sanitizedFileNameComponent(_ value: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/:")
            .union(.controlCharacters)
            .union(.newlines)
        let sanitized = value
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "meeting" : sanitized
    }

}

private extension MainWindowDestination {
    var agendaReturnDestination: MainWindowDestination {
        switch self {
        case .today, .meetings, .library:
            return self
        case .workspace, .settings:
            return .today
        }
    }
}

private struct SidebarNavigationButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(CommandCenterTypography.button)
            .foregroundStyle(isSelected ? CommandCenterPalette.primary : CommandCenterPalette.text)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .background(isSelected ? CommandCenterPalette.primary.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

private struct MeetingDetailView: View {
    let meeting: MeetingRecord?
    let speechConfiguration: SpeechTranscriptionConfiguration
    let primaryChainPreflightResult: PrimaryChainPreflightResult
    let statusText: String
    let isRecording: Bool
    let liveCaptionTurns: [LiveCaptionTurn]
    let recommendedQuestions: [FollowUpQuestionSuggestion]
    let meetingProgressState: MeetingProgressState?
    let backToMeetings: () -> Void
    let saveAgenda: (UUID, MeetingAgendaUpdate) throws -> Void
    let stopRecording: () -> Void
    let copySummary: (MeetingRecord) -> Void
    let exportTranscript: (MeetingRecord) -> Void
    let exportMeetingData: (MeetingRecord) -> Void
    let exportSRT: (MeetingRecord) -> Void
    let exportVTT: (MeetingRecord) -> Void
    let exportKnowledgePackage: (MeetingRecord) -> Void
    let retryTranscription: (MeetingRecord) -> Void
    let updateSpeakerLabel: (MeetingRecord, String, String) -> Void

    var body: some View {
        ZStack {
            CommandCenterPalette.window.ignoresSafeArea()
            if let meeting {
                MeetingCommandCenterView(
                    meeting: meeting,
                    backToMeetings: backToMeetings,
                    pipelineDisplayName: pipelineDisplayName(for: speechConfiguration),
                    transcriptionLinkText: transcriptionLinkText(for: speechConfiguration),
                    transcriptionModelText: transcriptionModelText(for: speechConfiguration),
                    preflightText: preflightText,
                    actualTranscriptionSourceText: actualTranscriptionSourceText(for: meeting),
                    statusText: statusText,
                    isRecording: isRecording,
                    sourceLocale: speechConfiguration.localeIdentifier,
                    targetLocale: speechConfiguration.targetLocaleIdentifier,
                    liveCaptionTurns: liveCaptionTurns,
                    transcriptText: transcriptText(for: meeting),
                    transcriptionStatusText: transcriptionStatusText(for: meeting),
                    summary: summary(for: meeting),
                    recommendedQuestions: recommendedQuestions,
                    meetingProgressState: meetingProgressState,
                    saveAgenda: saveAgenda,
                    stopRecording: stopRecording,
                    copySummary: { copySummary(meeting) },
                    exportTranscript: { exportTranscript(meeting) },
                    exportMeetingData: { exportMeetingData(meeting) },
                    exportSRT: { exportSRT(meeting) },
                    exportVTT: { exportVTT(meeting) },
                    exportKnowledgePackage: { exportKnowledgePackage(meeting) },
                    retryTranscription: { retryTranscription(meeting) },
                    updateSpeakerLabel: { speakerID, label in
                        updateSpeakerLabel(meeting, speakerID, label)
                    }
                )
            } else {
                CommandCenterPanel {
                    ContentUnavailableView(
                        "No Meeting Selected",
                        systemImage: "waveform",
                        description: Text("Detected and recorded meetings will appear here.")
                    )
                    .foregroundStyle(CommandCenterPalette.secondaryText)
                }
                .padding(24)
            }
        }
    }

    private func pipelineDisplayName(for configuration: SpeechTranscriptionConfiguration) -> String {
        BilingualPipelineFactory.builtInProfiles
            .first { $0.id == configuration.bilingualPipelineProfileID }?
            .displayName ?? configuration.bilingualPipelineProfileID
    }

    private func transcriptionLinkText(for configuration: SpeechTranscriptionConfiguration) -> String {
        let providerID = configuration.transcriptionExecutionMode == .hosted
            ? configuration.hostedTranscriptionProviderID
            : configuration.localTranscriptionProviderID
        return "\(modeDisplayName(configuration.transcriptionExecutionMode)) / \(providerDisplayName(providerID))"
    }

    private func transcriptionModelText(for configuration: SpeechTranscriptionConfiguration) -> String {
        if configuration.usesDeepgram {
            return modelDisplayName(configuration.deepgramModelID, in: BilingualPipelineFactory.hostedTranscriptionModelOptions)
        }
        if configuration.hostedTranscriptionProviderID == SpeechTranscriptionConfiguration.defaultOpenAIRealtimeTranscriptionProviderID {
            return openAIRealtimeTranscriptionModelDisplayName(configuration.hostedTranscriptionModelID)
        }
        if configuration.transcriptionExecutionMode == .hosted {
            return modelDisplayName(
                configuration.hostedTranscriptionModelID,
                in: BilingualPipelineFactory.hostedTranscriptionModelOptions
            )
        }
        if configuration.localTranscriptionProviderID == SpeechTranscriptionConfiguration.defaultLocalTranscriptionProviderID {
            return configuration.whisperModelPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Not configured"
        }
        return "System model"
    }

    private var preflightText: String {
        switch primaryChainPreflightResult.status {
        case .available:
            return "Primary chain ready"
        case .unavailable:
            return primaryChainPreflightResult.messages.joined(separator: "; ")
        }
    }

    private func actualTranscriptionSourceText(for meeting: MeetingRecord) -> String {
        guard let transcriptJSONURL = meeting.transcriptJSONURL,
              let document = try? TranscriptFileWriter.readDocument(from: transcriptJSONURL)
        else {
            return meeting.transcriptionProviderID
        }
        let providers = Array(Set(document.segments.map(\.sourceProvider))).sorted()
        return providers.isEmpty ? meeting.transcriptionProviderID : providers.joined(separator: ", ")
    }

    private func modeDisplayName(_ mode: ProviderExecutionMode) -> String {
        switch mode {
        case .local:
            return "Local"
        case .hosted:
            return "Hosted"
        }
    }

    private func providerDisplayName(_ providerID: String) -> String {
        BilingualPipelineFactory.builtInRegistry.descriptor(id: providerID)?.displayName ?? providerID
    }

    private func modelDisplayName(_ modelID: String, in options: [BilingualPipelineFactory.ModelOption]) -> String {
        options.first { $0.id == modelID }?.displayName ?? modelID
    }

    private func openAIRealtimeTranscriptionModelDisplayName(_ modelID: String) -> String {
        switch modelID {
        case "gpt-4o-transcribe":
            return "GPT-4o Transcribe"
        case "gpt-4o-mini-transcribe":
            return "GPT-4o Mini Transcribe"
        default:
            return modelID
        }
    }

    private func transcriptText(for meeting: MeetingRecord) -> String {
        guard let text = TranscriptFileWriter.renderedTranscript(
            textURL: meeting.transcriptURL,
            structuredURL: meeting.transcriptJSONURL
        ) else {
            return "Transcript will appear here while recording."
        }
        return text
    }

    private func transcriptionStatusText(for meeting: MeetingRecord) -> String {
        switch meeting.transcriptionStatus {
        case .notStarted:
            return "Not started"
        case .transcribing:
            return "Transcribing"
        case .transcribed:
            return "Transcribed"
        case .failed:
            return "Failed"
        case .retryRequested:
            return "Retry requested"
        }
    }

    private func summary(for meeting: MeetingRecord) -> MeetingSummary? {
        guard let summaryJSONURL = meeting.summaryJSONURL else { return nil }
        return try? MeetingSummaryWriter.read(from: summaryJSONURL)
    }
}

private struct MeetingCommandCenterView: View {
    let meeting: MeetingRecord
    let backToMeetings: () -> Void
    let pipelineDisplayName: String
    let transcriptionLinkText: String
    let transcriptionModelText: String
    let preflightText: String
    let actualTranscriptionSourceText: String
    let statusText: String
    let isRecording: Bool
    let sourceLocale: String
    let targetLocale: String
    let liveCaptionTurns: [LiveCaptionTurn]
    let transcriptText: String
    let transcriptionStatusText: String
    let summary: MeetingSummary?
    let recommendedQuestions: [FollowUpQuestionSuggestion]
    let meetingProgressState: MeetingProgressState?
    let saveAgenda: (UUID, MeetingAgendaUpdate) throws -> Void
    let stopRecording: () -> Void
    let copySummary: () -> Void
    let exportTranscript: () -> Void
    let exportMeetingData: () -> Void
    let exportSRT: () -> Void
    let exportVTT: () -> Void
    let exportKnowledgePackage: () -> Void
    let retryTranscription: () -> Void
    let updateSpeakerLabel: (String, String) -> Void
    @State private var editAgendaTarget: MeetingRecord?
    @State private var draft = AgendaDraft()
    @State private var agendaRecordBackedDraft = AgendaDraft()
    @State private var agendaSaveError: String?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                topCommandRow
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
                .background(CommandCenterPalette.surface)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(CommandCenterPalette.border)
                        .frame(height: 1)
                }

                HStack(spacing: 0) {
                    TranscriptPaneView(
                        meeting: meeting,
                        pipelineDisplayName: pipelineDisplayName,
                        transcriptionLinkText: transcriptionLinkText,
                        transcriptionModelText: transcriptionModelText,
                        preflightText: preflightText,
                        actualTranscriptionSourceText: actualTranscriptionSourceText,
                        statusText: statusText,
                        isRecording: isRecording,
                        sourceLocale: sourceLocale,
                        targetLocale: targetLocale,
                        liveCaptionTurns: liveCaptionTurns,
                        transcriptText: transcriptText,
                        transcriptionStatusText: transcriptionStatusText,
                        updateSpeakerLabel: updateSpeakerLabel
                    )
                    .frame(minWidth: 520)

                    Divider()
                        .overlay(CommandCenterPalette.border)

                    InsightPaneView(
                        meeting: meeting,
                        isRecording: isRecording,
                        summary: summary,
                        recommendedQuestions: recommendedQuestions,
                        meetingProgressState: meetingProgressState,
                        exportKnowledgePackage: exportKnowledgePackage
                    )
                    .frame(minWidth: 360, idealWidth: 440, maxWidth: 520)
                }
            }

            if editAgendaTarget != nil {
                AgendaEditorView(
                    meeting: editAgendaTarget,
                    draft: $draft,
                    saveError: agendaSaveError,
                    save: saveDetailAgenda,
                    cancel: cancelDetailAgendaEdit
                )
                .shadow(color: .black.opacity(0.24), radius: 18, x: 0, y: 12)
                .padding(.top, 54)
                .padding(.trailing, 18)
            }
        }
        .background(CommandCenterPalette.window)
    }

    private var topCommandRow: some View {
        HStack(spacing: 12) {
            Button(action: backToMeetings) {
                Label("Back", systemImage: "chevron.left")
            }
            .buttonStyle(.plain)
            .font(CommandCenterTypography.button)
            .foregroundStyle(CommandCenterPalette.primary)

            Button(action: beginDetailAgendaEdit) {
                CommandCenterChip(
                    title: goalDisplay,
                    tint: CommandCenterPalette.primary,
                    filled: meeting.meetingGoal != nil
                )
            }
            .buttonStyle(.plain)
            .help("Edit meeting goal")

            Button(action: beginDetailAgendaEdit) {
                CommandCenterChip(
                    title: attendeesDisplay,
                    tint: CommandCenterPalette.cyan,
                    filled: !meeting.attendees.isEmpty
                )
            }
            .buttonStyle(.plain)
            .help("Edit attendees")

            Spacer()

            recordingCommand
            overflowMenu
        }
    }

    @ViewBuilder
    private var recordingCommand: some View {
        if isRecording {
            Button {
                stopRecording()
            } label: {
                Label("Stop Recording", systemImage: "stop.fill")
            }
            .buttonStyle(CommandCenterActionButtonStyle(variant: .danger))
        } else {
            Button {
            } label: {
                Label("Record", systemImage: "record.circle")
            }
            .buttonStyle(CommandCenterActionButtonStyle())
            .disabled(true)
            .help("Recording can be started from an agenda item.")
        }
    }

    private var overflowMenu: some View {
        Menu {
            Button {
                copySummary()
            } label: {
                Label("Copy Summary", systemImage: "doc.on.clipboard")
            }
            .disabled(isRecording || meeting.summaryURL == nil)

            Button {
                exportTranscript()
            } label: {
                Label("Export Transcript", systemImage: "doc.text")
            }
            .disabled(isRecording || meeting.transcriptURL == nil)

            Button {
                exportMeetingData()
            } label: {
                Label("Export Meeting JSON", systemImage: "curlybraces")
            }

            Button {
                exportSRT()
            } label: {
                Label("Export SRT", systemImage: "captions.bubble")
            }

            Button {
                exportVTT()
            } label: {
                Label("Export VTT", systemImage: "captions.bubble")
            }

            Button {
                exportKnowledgePackage()
            } label: {
                Label("Export Knowledge Package", systemImage: "brain")
            }
            .disabled(isRecording || meeting.transcriptJSONURL == nil)

            Divider()

            Button {
                retryTranscription()
            } label: {
                Label("Retry Transcription", systemImage: "arrow.clockwise")
            }
            .disabled(isRecording || meeting.audioURL == nil)
        } label: {
            Image(systemName: "ellipsis.circle")
                .accessibilityLabel("Meeting actions")
        }
        .buttonStyle(CommandCenterIconButtonStyle())
        .help("Meeting actions")
    }

    private var goalDisplay: String {
        let titles = meetingGoalTitles(for: meeting)
        guard let first = titles.first else { return "No goals" }
        let remaining = titles.count - 1
        return remaining > 0 ? "\(first) +\(remaining)" : first
    }

    private var attendeesDisplay: String {
        meeting.attendees.isEmpty ? "No attendees" : "\(meeting.attendees.count) attendees"
    }

    private func beginDetailAgendaEdit() {
        editAgendaTarget = meeting
        draft = AgendaDraft(meeting: meeting)
        agendaRecordBackedDraft = draft
        agendaSaveError = nil
    }

    private func saveDetailAgenda() {
        guard let meetingID = editAgendaTarget?.id else { return }
        do {
            try saveAgenda(meetingID, draft.update())
            agendaRecordBackedDraft = draft
            editAgendaTarget = nil
            agendaSaveError = nil
        } catch {
            agendaSaveError = "Could not save agenda: \(error)"
        }
    }

    private func cancelDetailAgendaEdit() {
        draft = agendaRecordBackedDraft
        editAgendaTarget = nil
        agendaSaveError = nil
    }
}

private struct TranscriptPaneView: View {
    let meeting: MeetingRecord
    let pipelineDisplayName: String
    let transcriptionLinkText: String
    let transcriptionModelText: String
    let preflightText: String
    let actualTranscriptionSourceText: String
    let statusText: String
    let isRecording: Bool
    let sourceLocale: String
    let targetLocale: String
    let liveCaptionTurns: [LiveCaptionTurn]
    let transcriptText: String
    let transcriptionStatusText: String
    let updateSpeakerLabel: (String, String) -> Void
    @State private var speakerEditTarget: LiveCaptionTurn?
    @State private var speakerLabelDraft = ""
    @State private var autoFollowsLatest = true

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                CommandCenterScrollView(content: {
                    VStack(alignment: .leading, spacing: 22) {
                        metadata
                        failureReason
                        UnifiedTranscriptView(
                            turns: liveCaptionTurns,
                            transcriptText: transcriptText,
                            isRecording: isRecording,
                            autoFollowsLatest: autoFollowsLatest,
                            returnToLatest: {
                                returnToLatest(proxy: proxy)
                            },
                            pauseFollowing: {
                                autoFollowsLatest = false
                            },
                            editSpeaker: { turn in
                                speakerLabelDraft = turn.speaker.label ?? turn.speaker.identifier ?? ""
                                speakerEditTarget = turn
                            }
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(28)
                })
                .onChange(of: liveCaptionTurns.last?.id) { _, latestID in
                    guard autoFollowsLatest, let latestID else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(latestID, anchor: .bottom)
                    }
                }
            }
        }
        .background(CommandCenterPalette.window)
        .sheet(item: $speakerEditTarget) { turn in
            CaptionEditSheet(
                title: "Edit Speaker",
                text: $speakerLabelDraft,
                saveTitle: "Save Speaker",
                save: {
                    if let speakerID = turn.speaker.identifier {
                        updateSpeakerLabel(speakerID, speakerLabelDraft)
                    }
                    speakerEditTarget = nil
                },
                cancel: { speakerEditTarget = nil }
            )
        }
    }

    private func returnToLatest(proxy: ScrollViewProxy) {
        autoFollowsLatest = true
        guard let latestID = liveCaptionTurns.last?.id else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(latestID, anchor: .bottom)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isRecording ? CommandCenterPalette.danger : CommandCenterPalette.mutedText)
                    .frame(width: 9, height: 9)
                Text(isRecording ? "LIVE" : "READY")
                    .font(CommandCenterTypography.eyebrow)
                    .tracking(2)
            }
            .foregroundStyle(CommandCenterPalette.text)

            Text(elapsedText)
                .commandCenterMono()

            Divider()
                .frame(height: 18)
                .overlay(CommandCenterPalette.border)

            Text(meeting.name)
                .commandCenterTitle()
                .lineLimit(1)

            Spacer()
            CommandCenterChip(title: meeting.speechLocaleIdentifier, tint: CommandCenterPalette.secondaryText)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(CommandCenterPalette.surface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(CommandCenterPalette.border)
                .frame(height: 1)
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Current Pipeline").commandCenterEyebrow()
                Image(systemName: "exclamationmark.circle")
                    .font(CommandCenterTypography.eyebrow)
                    .foregroundStyle(CommandCenterPalette.warning)
                    .help(pipelineDebugHelpText)
            }

            HStack(spacing: 8) {
                CommandCenterChip(title: transcriptionStatusText, tint: transcriptionTint, filled: true)
                CommandCenterChip(title: meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                if let endedAt = meeting.endedAt {
                    CommandCenterChip(title: "Ended \(endedAt.formatted(date: .omitted, time: .shortened))")
                }
            }
        }
    }

    @ViewBuilder
    private var failureReason: some View {
        if let failureReason = meeting.transcriptionFailureReason {
            Text(failureReason)
                .commandCenterCaption(CommandCenterPalette.danger)
                .textSelection(.enabled)
        }
    }

    private var elapsedText: String {
        let interval = (meeting.endedAt ?? Date()).timeIntervalSince(meeting.startedAt)
        let minutes = max(Int(interval) / 60, 0)
        let seconds = max(Int(interval) % 60, 0)
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private var transcriptionTint: Color {
        switch meeting.transcriptionStatus {
        case .failed:
            return CommandCenterPalette.danger
        case .transcribed:
            return CommandCenterPalette.primary
        case .transcribing, .retryRequested:
            return CommandCenterPalette.warning
        case .notStarted:
            return CommandCenterPalette.secondaryText
        }
    }

    private var pipelineDebugHelpText: String {
        [
            "Pipeline: \(pipelineDisplayName)",
            "Actual STT Source: \(actualTranscriptionSourceText)",
            "Transcription Link: \(transcriptionLinkText)",
            "Transcription Model: \(transcriptionModelText)",
            "Preflight: \(preflightText)",
            "Transcript Latency: \(transcriptLatencyText)"
        ].joined(separator: "\n")
    }

    private var transcriptLatencyText: String {
        PipelineLatencySummary(meeting: meeting).transcriptLatencyText
    }
}

private struct PipelineLatencySummary {
    let meeting: MeetingRecord

    var transcriptLatencyText: String {
        guard let event = latestTranscriptEvent,
              let latency = latencySeconds(for: event) else {
            return "unavailable"
        }
        return format(seconds: latency)
    }

    private var latestTranscriptEvent: PerformanceEvent? {
        performanceEvents.last(where: { $0.event == "transcript_segment_written" && $0.audioTimeSeconds != nil })
            ?? performanceEvents.last(where: { $0.event == "stt_segment_received" && $0.audioTimeSeconds != nil })
    }

    private var performanceEvents: [PerformanceEvent] {
        guard let url = meeting.performanceEventsURL,
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return content
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                try? decoder.decode(PerformanceEvent.self, from: Data(line.utf8))
            }
    }

    private func latencySeconds(for event: PerformanceEvent) -> TimeInterval? {
        guard let audioTimeSeconds = event.audioTimeSeconds else {
            return nil
        }
        let expectedWallTime = meeting.startedAt.addingTimeInterval(audioTimeSeconds)
        return max(0, event.wallTime.timeIntervalSince(expectedWallTime))
    }

    private func format(seconds: TimeInterval) -> String {
        if seconds < 1 {
            return "\(Int((seconds * 1_000).rounded())) ms"
        }
        return String(format: "%.1f s", seconds)
    }
}

private struct InsightPaneView: View {
    let meeting: MeetingRecord
    let isRecording: Bool
    let summary: MeetingSummary?
    let recommendedQuestions: [FollowUpQuestionSuggestion]
    let meetingProgressState: MeetingProgressState?
    let exportKnowledgePackage: () -> Void
    @State private var selectedTab: MeetingInsightTab = .overview

    var body: some View {
        VStack(spacing: 0) {
            CommandCenterScrollView(background: CommandCenterPalette.surface, content: {
                VStack(alignment: .leading, spacing: 16) {
                    insightPicker
                    switch selectedTab {
                    case .overview:
                        overviewContent
                    case .knowledge:
                        knowledgeContent
                    }
                }
                .padding(22)
            })
        }
        .background(CommandCenterPalette.surface)
    }

    private var insightPicker: some View {
        Picker("Insight view", selection: $selectedTab) {
            Text("Overview").tag(MeetingInsightTab.overview)
            Text("Knowledge").tag(MeetingInsightTab.knowledge)
        }
        .pickerStyle(.segmented)
    }

    private var overviewContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            GoalTrackerPanel(
                meeting: meeting,
                meetingProgressState: meetingProgressState
            )
            if !recommendedQuestions.isEmpty {
                RecommendedQuestionsPanel(questions: recommendedQuestions)
            }
            phaseSummary
            summaryPanel
        }
    }

    private var knowledgeContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            CommandCenterPanel {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Knowledge Deltas").commandCenterEyebrow()
                    Text("Proposed knowledge updates are generated from the meeting summary and transcript evidence.")
                        .commandCenterCaption(CommandCenterPalette.secondaryText)
                        .textSelection(.enabled)
                    Button {
                        exportKnowledgePackage()
                    } label: {
                        Label("Export Knowledge Package", systemImage: "brain")
                    }
                    .buttonStyle(CommandCenterActionButtonStyle())
                    .disabled(isRecording || meeting.transcriptJSONURL == nil)
                }
            }

            if let summary {
                let knowledge = MeetingKnowledgeExtractor.fromSummary(summary, segments: transcriptSegments)
                KnowledgeSectionView(title: "Facts", items: knowledge.facts, mode: .statement)
                KnowledgeSectionView(title: "Judgments", items: knowledge.judgments, mode: .statement)
                KnowledgeSectionView(title: "Decisions", items: knowledge.decisions, mode: .statement)
                KnowledgeSectionView(title: "Actions", items: knowledge.actions, mode: .statement)
                KnowledgeSectionView(title: "Open Questions", items: knowledge.openQuestions, mode: .question)
                KnowledgeSectionView(title: "Entity Updates", items: knowledge.entityUpdates, mode: .statement)
            } else {
                CommandCenterPanel {
                    Text("Generate a summary before reviewing proposed knowledge updates.")
                        .commandCenterCaption(CommandCenterPalette.secondaryText)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var transcriptSegments: [TranscriptSegment] {
        guard let transcriptJSONURL = meeting.transcriptJSONURL,
              let document = try? TranscriptFileWriter.readDocument(from: transcriptJSONURL)
        else {
            return []
        }
        return document.segments
    }

    private var phaseSummary: some View {
        CommandCenterPanel {
            VStack(alignment: .leading, spacing: 12) {
                Text("Summary").commandCenterEyebrow()
                if let summary, !summary.tags.isEmpty {
                    SummaryTagChipsView(tags: summary.tags)
                }
                Text(summary?.overview.isEmpty == false ? summary?.overview ?? "" : "Meeting summary will appear here after recording stops.")
                    .commandCenterBody()
                    .lineSpacing(4)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var summaryPanel: some View {
        CommandCenterPanel {
            VStack(alignment: .leading, spacing: 12) {
                Text("Details").commandCenterEyebrow()
                if let summary {
                    if summary.status == .failed {
                        Text(summary.failureReason ?? "Summary generation failed.")
                            .commandCenterCaption(CommandCenterPalette.danger)
                            .textSelection(.enabled)
                    } else if !hasStructuredSummaryDetails(summary) {
                        Text("No decisions, action items, open questions, or risks were found.")
                            .foregroundStyle(CommandCenterPalette.secondaryText)
                            .textSelection(.enabled)
                    } else {
                        SummaryListView(title: "Decisions", items: summary.decisions.map(\.description))
                        SummaryListView(title: "Action Items", items: summary.actionItems.map(\.description))
                        SummaryListView(title: "Open Questions", items: summary.openQuestions)
                        SummaryListView(title: "Risks", items: summary.risks)
                    }
                } else {
                    Text("No summary generated yet.")
                        .foregroundStyle(CommandCenterPalette.secondaryText)
                }
            }
        }
    }

    private func hasStructuredSummaryDetails(_ summary: MeetingSummary) -> Bool {
        !summary.decisions.map(\.description).allSatisfy(isBlank)
            || !summary.actionItems.map(\.description).allSatisfy(isBlank)
            || !summary.openQuestions.allSatisfy(isBlank)
            || !summary.risks.allSatisfy(isBlank)
    }

    private func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private enum MeetingInsightTab {
    case overview
    case knowledge
}

private enum KnowledgeItemDisplayMode {
    case statement
    case question
}

private struct KnowledgeSectionView: View {
    let title: String
    let items: [MeetingKnowledgeItem]
    let mode: KnowledgeItemDisplayMode

    var body: some View {
        CommandCenterPanel {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).commandCenterEyebrow()
                if items.isEmpty {
                    Text("No proposed items.")
                        .commandCenterCaption(CommandCenterPalette.secondaryText)
                } else {
                    ForEach(items, id: \.id) { item in
                        KnowledgeItemRow(item: item, mode: mode)
                    }
                }
            }
        }
    }
}

private struct KnowledgeItemRow: View {
    let item: MeetingKnowledgeItem
    let mode: KnowledgeItemDisplayMode

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: iconName)
                    .font(CommandCenterTypography.caption)
                    .foregroundStyle(CommandCenterPalette.primary)
                    .frame(width: 16)
                Text(primaryText)
                    .font(CommandCenterTypography.secondaryBody)
                    .foregroundStyle(CommandCenterPalette.text)
                    .textSelection(.enabled)
            }
            metadataRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
    }

    private var metadataRow: some View {
        HStack(spacing: 8) {
            if let confidence = item.confidence {
                CommandCenterChip(title: confidence.rawValue, tint: CommandCenterPalette.primary, filled: false)
            }
            CommandCenterChip(title: item.status, tint: CommandCenterPalette.secondaryText, filled: false)
            if !item.evidence.isEmpty {
                CommandCenterChip(title: "\(item.evidence.count) evidence", tint: CommandCenterPalette.cyan, filled: false)
            }
            Spacer(minLength: 0)
        }
    }

    private var primaryText: String {
        switch mode {
        case .statement:
            return item.statement ?? item.question ?? "Untitled knowledge item"
        case .question:
            return item.question ?? item.statement ?? "Untitled question"
        }
    }

    private var iconName: String {
        switch mode {
        case .statement:
            return "smallcircle.filled.circle"
        case .question:
            return "questionmark.circle"
        }
    }
}

private struct GoalTrackerPanel: View {
    let meeting: MeetingRecord
    let meetingProgressState: MeetingProgressState?

    var body: some View {
        CommandCenterPanel {
            VStack(alignment: .leading, spacing: 12) {
                Text("Goals").commandCenterEyebrow()
                let titles = meetingGoalTitles(for: meeting)
                if titles.isEmpty {
                    Text("No goals set.")
                        .commandCenterCaption(CommandCenterPalette.secondaryText)
                } else {
                    ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                        HStack(spacing: 10) {
                            Text(title)
                                .font(CommandCenterTypography.secondaryBody)
                                .foregroundStyle(CommandCenterPalette.text)
                                .lineLimit(2)
                            Spacer(minLength: 8)
                            CommandCenterChip(
                                title: statusText(forGoalAt: index),
                                tint: statusTint(forGoalAt: index),
                                filled: index == 0 && firstGoalHasProgress
                            )
                        }
                    }
                }
            }
        }
    }

    private var firstGoalHasProgress: Bool {
        guard let progressGoalID = meetingProgressState?.goal.id,
              let firstGoalID = goalList.first?.id
        else {
            return false
        }
        return progressGoalID == firstGoalID
    }

    private var goalList: [MeetingGoal] {
        meeting.meetingGoals.isEmpty ? meeting.meetingGoal.map { [$0] } ?? [] : meeting.meetingGoals
    }

    private func statusText(forGoalAt index: Int) -> String {
        guard index == 0, firstGoalHasProgress else { return "Pending" }
        return meetingProgressState?.status.displayText ?? "Pending"
    }

    private func statusTint(forGoalAt index: Int) -> Color {
        guard index == 0, let status = meetingProgressState?.status, firstGoalHasProgress else {
            return CommandCenterPalette.secondaryText
        }
        switch status {
        case .blocked:
            return CommandCenterPalette.danger
        case .partiallyCovered:
            return CommandCenterPalette.warning
        case .onTrack:
            return CommandCenterPalette.primary
        case .notStarted:
            return CommandCenterPalette.secondaryText
        }
    }
}

private func meetingGoalTitles(for meeting: MeetingRecord) -> [String] {
    let goals = meeting.meetingGoals.isEmpty ? meeting.meetingGoal.map { [$0] } ?? [] : meeting.meetingGoals
    return goals
        .map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

private struct RecommendedQuestionsPanel: View {
    let questions: [FollowUpQuestionSuggestion]

    var body: some View {
        CommandCenterPanel {
            VStack(alignment: .leading, spacing: 12) {
                Text("Recommended Questions").commandCenterEyebrow()
                ForEach(Array(questions.prefix(2))) { question in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(question.chinese)
                            .font(CommandCenterTypography.sectionTitle)
                            .foregroundStyle(CommandCenterPalette.text)
                            .textSelection(.enabled)
                        Text(question.english)
                            .commandCenterCaption(CommandCenterPalette.secondaryText)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}

private struct UnifiedTranscriptView: View {
    let turns: [LiveCaptionTurn]
    let transcriptText: String
    let isRecording: Bool
    let autoFollowsLatest: Bool
    let returnToLatest: () -> Void
    let pauseFollowing: () -> Void
    let editSpeaker: (LiveCaptionTurn) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Transcript").commandCenterEyebrow()
                Spacer()
                if !autoFollowsLatest, !turns.isEmpty {
                    Button("Return to latest") {
                        returnToLatest()
                    }
                    .buttonStyle(CommandCenterActionButtonStyle())
                }
            }

            if turns.isEmpty {
                fallbackTranscript
            } else {
                LazyVStack(alignment: .leading, spacing: 20) {
                    let groups = LiveCaptionSpeakerGroup.groups(from: turns)
                    ForEach(groups) { group in
                        BilingualTranscriptGroup(
                            group: group,
                            editSpeaker: group.speaker.identifier == nil ? nil : {
                                if let firstTurn = group.turns.first {
                                    editSpeaker(firstTurn)
                                }
                            }
                        )
                        .id(group.id)
                    }
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8).onChanged { _ in
                        if isRecording {
                            pauseFollowing()
                        }
                    }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var fallbackTranscript: some View {
        Group {
            if transcriptText.isEmpty {
                Text(isRecording ? "Listening..." : "Recorded transcript will appear here.")
                    .foregroundStyle(CommandCenterPalette.secondaryText)
            } else {
                Text(transcriptText)
                    .font(CommandCenterTypography.transcript)
                    .lineSpacing(6)
                    .foregroundStyle(CommandCenterPalette.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

}

private struct BilingualTranscriptGroup: View {
    let group: LiveCaptionSpeakerGroup
    var editSpeaker: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            speakerLabel
            ForEach(group.turns) { turn in
                BilingualTranscriptBlock(
                    turn: turn
                )
                .id(turn.id)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var speakerDisplayName: String {
        group.speaker.label ?? group.speaker.identifier ?? "Speaker"
    }

    private var speakerStartTimeText: String {
        group.startedAt.formatted(date: .omitted, time: .standard)
    }

    @ViewBuilder
    private var speakerLabel: some View {
        if let editSpeaker {
            Menu {
                Button("Edit name") {
                    editSpeaker()
                }
            } label: {
                HStack(spacing: 4) {
                    HStack(spacing: 6) {
                        Text(speakerDisplayName)
                            .commandCenterMono()
                        Text(speakerStartTimeText)
                            .font(CommandCenterTypography.caption)
                            .foregroundStyle(CommandCenterPalette.secondaryText)
                    }
                    Image(systemName: "chevron.down")
                        .font(CommandCenterTypography.caption)
                        .foregroundStyle(CommandCenterPalette.secondaryText)
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .help("Edit speaker name")
        } else {
            HStack(spacing: 6) {
                Text(speakerDisplayName)
                    .commandCenterMono()
                Text(speakerStartTimeText)
                    .font(CommandCenterTypography.caption)
                    .foregroundStyle(CommandCenterPalette.secondaryText)
            }
        }
    }
}

private struct BilingualTranscriptBlock: View {
    let turn: LiveCaptionTurn

    var body: some View {
        transcriptText
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var transcriptText: some View {
        Text(turn.originalText)
            .font(CommandCenterTypography.transcript)
            .lineSpacing(5)
            .foregroundStyle(CommandCenterPalette.text)
            .textSelection(.enabled)
    }
}

private struct CaptionEditSheet: View {
    let title: String
    @Binding var text: String
    let saveTitle: String
    let save: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).commandCenterEyebrow()
            CommandCenterTextEditor(text: $text)
            HStack {
                Spacer()
                Button("Cancel") {
                    cancel()
                }
                .buttonStyle(CommandCenterActionButtonStyle(variant: .secondary))
                Button(saveTitle) {
                    save()
                }
                .buttonStyle(CommandCenterActionButtonStyle(variant: .primary))
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .background(CommandCenterPalette.surface)
    }
}

private struct SummaryListView: View {
    let title: String
    let items: [String]

    var body: some View {
        let visibleItems = items.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !visibleItems.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(CommandCenterTypography.sectionTitle)
                    .foregroundStyle(CommandCenterPalette.text)
                ForEach(Array(visibleItems.enumerated()), id: \.offset) { _, item in
                    Text(item)
                        .foregroundStyle(CommandCenterPalette.secondaryText)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

private struct SummaryTagChipsView: View {
    let tags: [MeetingSummaryTag]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 8) {
                tagChips
            }
            VStack(alignment: .leading, spacing: 8) {
                tagChips
            }
        }
    }

    private var visibleTags: [MeetingSummaryTag] {
        tags.filter { !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    @ViewBuilder
    private var tagChips: some View {
        ForEach(Array(visibleTags.enumerated()), id: \.offset) { _, tag in
            CommandCenterChip(title: tag.label, tint: CommandCenterPalette.primary, filled: false)
                .help(helpText(for: tag))
        }
    }

    private func helpText(for tag: MeetingSummaryTag) -> String {
        var lines = [tag.label]
        if let rationale = tag.rationale?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rationale.isEmpty {
            lines.append(rationale)
        }
        lines.append("Confidence: \(confidencePercent(for: tag))%")
        lines.append("Evidence: \(tag.sourceSegmentIDs.count) segments")
        return lines.joined(separator: "\n")
    }

    private func confidencePercent(for tag: MeetingSummaryTag) -> Int {
        Int((tag.confidence * 100).rounded())
    }
}
