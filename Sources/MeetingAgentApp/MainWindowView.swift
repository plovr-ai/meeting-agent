import AppKit
import MeetingAgentCore
import SwiftUI

private enum MainWindowDestination: Hashable {
    case today
    case recordings
    case workspace
    case settings
}

struct MainWindowView: View {
    @ObservedObject var viewModel: MeetingAgentViewModel
    @State private var destination: MainWindowDestination = .today

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                sidebarHeader

                VStack(spacing: 6) {
                    Button("Today") {
                        destination = .today
                    }
                    .buttonStyle(SidebarNavigationButtonStyle(isSelected: destination == .today))

                    Button("Recordings") {
                        destination = .recordings
                    }
                    .buttonStyle(SidebarNavigationButtonStyle(isSelected: destination == .recordings))
                }
                .padding(12)

                List(selection: Binding(
                    get: { destination == .settings ? nil : viewModel.selectedMeetingID },
                    set: { id in
                        destination = .workspace
                        viewModel.selectMeeting(id)
                    }
                )) {
                    Section {
                        ForEach(viewModel.meetings) { meeting in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(meeting.name)
                                    .font(CommandCenterTypography.title)
                                    .foregroundStyle(CommandCenterPalette.text)
                                Text(meeting.startedAt, style: .date)
                                    .font(CommandCenterTypography.caption)
                                    .foregroundStyle(CommandCenterPalette.secondaryText)
                            }
                            .padding(.vertical, 4)
                            .tag(Optional(meeting.id))
                        }
                    } header: {
                        Text("Recent Recordings")
                            .foregroundStyle(CommandCenterPalette.secondaryText)
                    }
                }
                .scrollContentBackground(.hidden)
                .background(CommandCenterPalette.surface)
                .environment(\.colorScheme, .dark)
                .foregroundStyle(CommandCenterPalette.text)

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
            .frame(minWidth: 260, idealWidth: 300)
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
            case .today:
                TodayAgendaView(
                    meetings: viewModel.meetings,
                    selectedMeetingID: viewModel.selectedMeetingID,
                    activeMeetingID: viewModel.activeMeetingID,
                    pendingCandidate: viewModel.pendingCandidate,
                    isRecording: viewModel.isRecording,
                    selectMeeting: { meeting in
                        viewModel.selectMeeting(meeting.id)
                    },
                    openWorkspace: { meeting in
                        viewModel.selectMeeting(meeting.id)
                        destination = .workspace
                    },
                    startRecording: { meeting in
                        guard let target = viewModel.pendingCandidate else {
                            viewModel.selectMeeting(meeting.id)
                            destination = .workspace
                            return
                        }
                        Task {
                            do {
                                try await viewModel.startRecording(for: target, meetingID: meeting.id)
                                destination = .workspace
                            } catch {
                                viewModel.setRecordingStartError(error)
                            }
                        }
                    },
                    saveAgenda: { meetingID, update in
                        try viewModel.saveAgenda(for: meetingID, update: update)
                    },
                    createMeeting: {
                        let created = try viewModel.createAgendaMeeting()
                        viewModel.selectMeeting(created.id)
                    }
                )
            case .recordings, .workspace:
                MeetingDetailView(
                    meeting: viewModel.selectedMeeting,
                    speechConfiguration: viewModel.speechConfiguration,
                    primaryChainPreflightResult: viewModel.primaryChainPreflightResult,
                    statusText: viewModel.statusText,
                    isRecording: viewModel.isRecording,
                    liveCaptionTurns: viewModel.liveCaptionTurns,
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
                    },
                    updateTranscriptSegmentText: { meeting, segmentID, text in
                        Task {
                            do {
                                try await viewModel.updateTranscriptSegmentText(for: meeting.id, segmentID: segmentID, text: text)
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

    private var sidebarHeader: some View {
        HStack {
            Text("Meeting Agent")
                .commandCenterEyebrow()
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
        .background(CommandCenterPalette.surface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(CommandCenterPalette.border)
                .frame(height: 1)
        }
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

private struct SidebarNavigationButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(CommandCenterTypography.button)
            .foregroundStyle(isSelected ? CommandCenterPalette.primary : CommandCenterPalette.text)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
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
    let stopRecording: () -> Void
    let copySummary: (MeetingRecord) -> Void
    let exportTranscript: (MeetingRecord) -> Void
    let exportMeetingData: (MeetingRecord) -> Void
    let exportSRT: (MeetingRecord) -> Void
    let exportVTT: (MeetingRecord) -> Void
    let retryTranscription: (MeetingRecord) -> Void
    let updateSpeakerLabel: (MeetingRecord, String, String) -> Void
    let updateTranscriptSegmentText: (MeetingRecord, String, String) -> Void

    var body: some View {
        ZStack {
            CommandCenterPalette.window.ignoresSafeArea()
            if let meeting {
                MeetingCommandCenterView(
                    meeting: meeting,
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
                    stopRecording: stopRecording,
                    copySummary: { copySummary(meeting) },
                    exportTranscript: { exportTranscript(meeting) },
                    exportMeetingData: { exportMeetingData(meeting) },
                    exportSRT: { exportSRT(meeting) },
                    exportVTT: { exportVTT(meeting) },
                    retryTranscription: { retryTranscription(meeting) },
                    updateSpeakerLabel: { speakerID, label in
                        updateSpeakerLabel(meeting, speakerID, label)
                    },
                    updateTranscriptSegmentText: { segmentID, text in
                        updateTranscriptSegmentText(meeting, segmentID, text)
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
    let stopRecording: () -> Void
    let copySummary: () -> Void
    let exportTranscript: () -> Void
    let exportMeetingData: () -> Void
    let exportSRT: () -> Void
    let exportVTT: () -> Void
    let retryTranscription: () -> Void
    let updateSpeakerLabel: (String, String) -> Void
    let updateTranscriptSegmentText: (String, String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            AgendaContextStrip(
                meeting: meeting,
                attendees: meeting.attendees,
                topics: meeting.agendaTopics,
                goalTitle: meeting.meetingGoal?.title
            )

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
                    stopRecording: stopRecording,
                    retryTranscription: retryTranscription,
                    updateSpeakerLabel: updateSpeakerLabel,
                    updateTranscriptSegmentText: updateTranscriptSegmentText
                )
                .frame(minWidth: 520)

                Divider()
                    .overlay(CommandCenterPalette.border)

                InsightPaneView(
                    meeting: meeting,
                    isRecording: isRecording,
                    summary: summary,
                    copySummary: copySummary,
                    exportTranscript: exportTranscript,
                    exportMeetingData: exportMeetingData,
                    exportSRT: exportSRT,
                    exportVTT: exportVTT
                )
                .frame(minWidth: 360, idealWidth: 440, maxWidth: 520)
            }
        }
        .background(CommandCenterPalette.window)
    }
}

private struct AgendaContextStrip: View {
    let meeting: MeetingRecord
    let attendees: [MeetingAttendee]
    let topics: [MeetingAgendaTopic]
    let goalTitle: String?

    var body: some View {
        HStack(spacing: 8) {
            CommandCenterChip(title: goalDisplay, tint: CommandCenterPalette.primary, filled: goalTitle != nil)
            CommandCenterChip(title: "\(attendees.count) attendees", tint: CommandCenterPalette.cyan)
            ForEach(topics.prefix(3)) { topic in
                CommandCenterChip(title: topic.title)
            }
            if topics.count > 3 {
                CommandCenterChip(title: "+\(topics.count - 3) topics")
            }
            Spacer()
            if let scheduledStartAt = meeting.scheduledStartAt {
                CommandCenterChip(title: scheduledStartAt.formatted(date: .omitted, time: .shortened))
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        .background(CommandCenterPalette.surface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(CommandCenterPalette.border)
                .frame(height: 1)
        }
    }

    private var goalDisplay: String {
        let normalized = goalTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? "No goal" : normalized
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
    let stopRecording: () -> Void
    let retryTranscription: () -> Void
    let updateSpeakerLabel: (String, String) -> Void
    let updateTranscriptSegmentText: (String, String) -> Void
    @State private var speakerEditTarget: LiveCaptionTurn?
    @State private var speakerLabelDraft = ""
    @State private var transcriptEditTarget: LiveCaptionTurn?
    @State private var transcriptTextDraft = ""
    @State private var autoFollowsLatest = true

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                CommandCenterScrollView(content: {
                    VStack(alignment: .leading, spacing: 22) {
                        metadata
                        recordingActions
                        failureReason
                        UnifiedTranscriptView(
                            turns: liveCaptionTurns,
                            transcriptText: transcriptText,
                            isRecording: isRecording,
                            sourceLocale: sourceLocale,
                            targetLocale: targetLocale,
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
                            },
                            editText: { turn in
                                transcriptTextDraft = turn.originalText
                                transcriptEditTarget = turn
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
        .sheet(item: $transcriptEditTarget) { turn in
            CaptionEditSheet(
                title: "Correct Caption",
                text: $transcriptTextDraft,
                saveTitle: "Save Caption",
                save: {
                    updateTranscriptSegmentText(turn.id, transcriptTextDraft)
                    transcriptEditTarget = nil
                },
                cancel: { transcriptEditTarget = nil }
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
                CommandCenterChip(title: pipelineDisplayName, tint: CommandCenterPalette.primary)
            }
        }
    }

    private var recordingActions: some View {
        HStack(spacing: 10) {
            Button("Stop Recording") {
                stopRecording()
            }
            .buttonStyle(CommandCenterActionButtonStyle(variant: .danger))
            .disabled(!isRecording)

            Button("Retry Transcription") {
                retryTranscription()
            }
            .buttonStyle(CommandCenterActionButtonStyle())
            .disabled(isRecording || meeting.audioURL == nil)
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
            "Actual STT Source: \(actualTranscriptionSourceText)",
            "Transcription Link: \(transcriptionLinkText)",
            "Transcription Model: \(transcriptionModelText)",
            "Preflight: \(preflightText)"
        ].joined(separator: "\n")
    }
}

private struct InsightPaneView: View {
    let meeting: MeetingRecord
    let isRecording: Bool
    let summary: MeetingSummary?
    let copySummary: () -> Void
    let exportTranscript: () -> Void
    let exportMeetingData: () -> Void
    let exportSRT: () -> Void
    let exportVTT: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            CommandCenterScrollView(background: CommandCenterPalette.surface, content: {
                VStack(alignment: .leading, spacing: 16) {
                    phaseSummary
                    exports
                    summaryPanel
                }
                .padding(22)
            })
        }
        .background(CommandCenterPalette.surface)
    }

    private var phaseSummary: some View {
        CommandCenterPanel {
            VStack(alignment: .leading, spacing: 12) {
                Text("Summary").commandCenterEyebrow()
                Text(summary?.overview.isEmpty == false ? summary?.overview ?? "" : "Meeting summary will appear here after recording stops.")
                    .commandCenterBody()
                    .lineSpacing(4)
                    .textSelection(.enabled)
                HStack {
                    CommandCenterChip(title: isRecording ? "ACTIVE" : "RECORDED", tint: CommandCenterPalette.primary, filled: true)
                    CommandCenterChip(title: summary == nil ? "Summary pending" : "Summary ready", tint: summary == nil ? CommandCenterPalette.warning : CommandCenterPalette.primary)
                }
            }
        }
    }

    private var exports: some View {
        CommandCenterPanel {
            VStack(alignment: .leading, spacing: 12) {
                Text("Exports").commandCenterEyebrow()
                HStack {
                    Button {
                        copySummary()
                    } label: {
                        Label("Copy Summary", systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(CommandCenterActionButtonStyle())
                    .disabled(isRecording || meeting.summaryURL == nil)

                    Button {
                        exportTranscript()
                    } label: {
                        Label("Transcript", systemImage: "doc.text")
                    }
                    .buttonStyle(CommandCenterActionButtonStyle())
                    .disabled(isRecording || meeting.transcriptURL == nil)
                }
                HStack {
                    Button {
                        exportMeetingData()
                    } label: {
                        Label("Meeting JSON", systemImage: "curlybraces")
                    }
                    .buttonStyle(CommandCenterActionButtonStyle())

                    Button {
                        exportSRT()
                    } label: {
                        Label("SRT", systemImage: "captions.bubble")
                    }
                    .buttonStyle(CommandCenterActionButtonStyle())

                    Button {
                        exportVTT()
                    } label: {
                        Label("VTT", systemImage: "captions.bubble")
                    }
                    .buttonStyle(CommandCenterActionButtonStyle())
                }
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
}

private struct UnifiedTranscriptView: View {
    let turns: [LiveCaptionTurn]
    let transcriptText: String
    let isRecording: Bool
    let sourceLocale: String
    let targetLocale: String
    let autoFollowsLatest: Bool
    let returnToLatest: () -> Void
    let pauseFollowing: () -> Void
    let editSpeaker: (LiveCaptionTurn) -> Void
    let editText: (LiveCaptionTurn) -> Void

    var body: some View {
        CommandCenterPanel {
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
                                sourceLocale: sourceLocale,
                                targetLocale: targetLocale,
                                editSpeaker: group.speaker.identifier == nil ? nil : {
                                    if let firstTurn = group.turns.first {
                                        editSpeaker(firstTurn)
                                    }
                                },
                                editText: editText
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
        }
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
    let sourceLocale: String
    let targetLocale: String
    var editSpeaker: (() -> Void)? = nil
    var editText: (LiveCaptionTurn) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            speakerLabel
            ForEach(group.turns) { turn in
                BilingualTranscriptBlock(
                    turn: turn,
                    secondLanguageEnabled: secondLanguageEnabled(for: turn),
                    editText: {
                        editText(turn)
                    }
                )
                .id(turn.id)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func secondLanguageEnabled(for turn: LiveCaptionTurn) -> Bool {
        LiveCaptionDisplayState.isSecondLanguageEnabled(
            sourceLocale: turn.sourceLocale.isEmpty ? sourceLocale : turn.sourceLocale,
            targetLocale: turn.targetLocale.isEmpty ? targetLocale : turn.targetLocale,
            hasTranslatedText: !(turn.translatedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        )
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
    let secondLanguageEnabled: Bool
    var editText: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            transcriptText
                .frame(maxWidth: .infinity, alignment: .leading)
            if let editText {
                Button {
                    editText()
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(CommandCenterIconButtonStyle())
                .help("Correct caption")
            }
        }
    }

    @ViewBuilder
    private var transcriptText: some View {
        VStack(alignment: .leading, spacing: 7) {
            switch LiveCaptionDisplayState(turn: turn, secondLanguageEnabled: secondLanguageEnabled) {
            case .translated(let primaryText, let sourceText):
                Text(primaryText)
                    .font(CommandCenterTypography.transcript)
                    .lineSpacing(5)
                    .foregroundStyle(CommandCenterPalette.text)
                    .textSelection(.enabled)
                Text(sourceText)
                    .font(CommandCenterTypography.secondaryBody)
                    .lineSpacing(4)
                    .foregroundStyle(CommandCenterPalette.secondaryText)
                    .textSelection(.enabled)
            case .originalOnly(let text):
                Text(text)
                    .font(CommandCenterTypography.transcript)
                    .lineSpacing(5)
                    .foregroundStyle(CommandCenterPalette.text)
                    .textSelection(.enabled)
            case .pending(let sourceText):
                Text(sourceText)
                    .font(CommandCenterTypography.secondaryBody)
                    .lineSpacing(4)
                    .foregroundStyle(CommandCenterPalette.secondaryText)
                    .textSelection(.enabled)
                Text("Translating...")
                    .commandCenterMono()
            case .failed(let sourceText, _):
                Text(sourceText)
                    .font(CommandCenterTypography.secondaryBody)
                    .lineSpacing(4)
                    .foregroundStyle(CommandCenterPalette.secondaryText)
                    .textSelection(.enabled)
                Text("translation unavailable")
                    .commandCenterMono()
                    .foregroundStyle(CommandCenterPalette.warning)
            }
        }
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
