import AppKit
import MeetingAgentCore
import SwiftUI

struct MainWindowView: View {
    @ObservedObject var viewModel: MeetingAgentViewModel
    @State private var showSettings = false

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: Binding(
                    get: { showSettings ? nil : viewModel.selectedMeetingID },
                    set: { id in
                        showSettings = false
                        viewModel.selectMeeting(id)
                    }
                )) {
                    Section("Meetings") {
                        ForEach(viewModel.meetings) { meeting in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(meeting.name)
                                    .font(.headline)
                                    .foregroundStyle(CommandCenterPalette.text)
                                Text(meeting.startedAt, style: .date)
                                    .font(.caption)
                                    .foregroundStyle(CommandCenterPalette.secondaryText)
                            }
                            .padding(.vertical, 4)
                            .tag(Optional(meeting.id))
                        }
                    }
                }
                .scrollContentBackground(.hidden)

                Spacer()

                Divider()
                    .overlay(CommandCenterPalette.border)

                Button {
                    showSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(showSettings ? CommandCenterPalette.primary : CommandCenterPalette.text)
                .padding(12)
                .background(showSettings ? CommandCenterPalette.primary.opacity(0.12) : Color.clear)
            }
            .background(CommandCenterPalette.surface)
            .navigationTitle("Meeting Agent")
        } detail: {
            if showSettings {
                SettingsView(
                    configuration: viewModel.speechConfiguration,
                    profiles: BilingualPipelineFactory.builtInProfiles,
                    localeIdentifiers: MeetingAgentViewModel.supportedLocaleIdentifiers,
                    isRecording: viewModel.isRecording,
                    status: viewModel.speechConfigurationStatus,
                    primaryChainPreflightResult: viewModel.primaryChainPreflightResult,
                    save: { viewModel.saveSpeechConfiguration($0) }
                )
            } else {
                MeetingDetailView(
                    meeting: viewModel.selectedMeeting,
                    speechConfiguration: viewModel.speechConfiguration,
                    primaryChainPreflightResult: viewModel.primaryChainPreflightResult,
                    statusText: viewModel.statusText,
                    isRecording: viewModel.isRecording,
                    realtimeTranslationStatus: viewModel.realtimeTranslationStatus,
                    liveCaptionTurns: viewModel.liveCaptionTurns,
                    meetingGoal: viewModel.meetingGoal,
                    meetingProgressState: viewModel.meetingProgressState,
                    meetingProgressHealth: viewModel.meetingProgressHealth,
                    liveTranslationTurns: viewModel.liveTranslationTurns,
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
                    exportReadinessReport: { meeting in
                        export("readiness-report.md", for: meeting) { destination in
                            try viewModel.exportReadinessReport(for: meeting.id, to: destination)
                        }
                    },
                    retryTranscription: { meeting in
                        Task {
                            await viewModel.retryTranscription(for: meeting.id)
                        }
                    },
                    startRealtimeTranslation: { locale in
                        Task {
                            await viewModel.startRealtimeTranslation(targetLocale: locale)
                        }
                    },
                    stopRealtimeTranslation: {
                        Task {
                            await viewModel.stopRealtimeTranslation()
                        }
                    },
                    setMeetingGoal: { goal in
                        viewModel.setMeetingGoal(goal)
                        Task {
                            await viewModel.refreshMeetingProgress()
                        }
                    }
                )
            }
        }
        .background(CommandCenterPalette.window)
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

private struct MeetingDetailView: View {
    let meeting: MeetingRecord?
    let speechConfiguration: SpeechTranscriptionConfiguration
    let primaryChainPreflightResult: PrimaryChainPreflightResult
    let statusText: String
    let isRecording: Bool
    let realtimeTranslationStatus: RealtimeTranslationStatus
    let liveCaptionTurns: [LiveCaptionTurn]
    let meetingGoal: MeetingGoal?
    let meetingProgressState: MeetingProgressState?
    let meetingProgressHealth: MeetingProgressHealth
    let liveTranslationTurns: [LiveTranslationTurn]
    let stopRecording: () -> Void
    let copySummary: (MeetingRecord) -> Void
    let exportTranscript: (MeetingRecord) -> Void
    let exportMeetingData: (MeetingRecord) -> Void
    let exportReadinessReport: (MeetingRecord) -> Void
    let retryTranscription: (MeetingRecord) -> Void
    let startRealtimeTranslation: (String) -> Void
    let stopRealtimeTranslation: () -> Void
    let setMeetingGoal: (MeetingGoal?) -> Void
    @State private var targetLocale = "zh-CN"

    var body: some View {
        ZStack {
            CommandCenterPalette.window.ignoresSafeArea()
            if let meeting {
                MeetingCommandCenterView(
                    meeting: meeting,
                    pipelineDisplayName: pipelineDisplayName(for: speechConfiguration),
                    transcriptionLinkText: transcriptionLinkText(for: speechConfiguration),
                    transcriptionModelText: transcriptionModelText(for: speechConfiguration),
                    translationLinkText: translationLinkText(for: speechConfiguration),
                    translationModelText: translationModelText(for: speechConfiguration),
                    preflightText: preflightText,
                    actualTranscriptionSourceText: actualTranscriptionSourceText(for: meeting),
                    statusText: statusText,
                    isRecording: isRecording,
                    realtimeTranslationStatus: realtimeTranslationStatus,
                    liveCaptionTurns: liveCaptionTurns,
                    meetingGoal: meetingGoal,
                    meetingProgressState: meetingProgressState,
                    meetingProgressHealth: meetingProgressHealth,
                    liveTranslationTurns: liveTranslationTurns,
                    targetLocale: $targetLocale,
                    transcriptText: transcriptText(for: meeting),
                    transcriptionStatusText: transcriptionStatusText(for: meeting),
                    liveTranslationStatusText: liveTranslationStatusText(realtimeTranslationStatus),
                    liveTranslationStatusColor: liveTranslationStatusColor(realtimeTranslationStatus),
                    summary: summary(for: meeting),
                    stopRecording: stopRecording,
                    copySummary: { copySummary(meeting) },
                    exportTranscript: { exportTranscript(meeting) },
                    exportMeetingData: { exportMeetingData(meeting) },
                    exportReadinessReport: { exportReadinessReport(meeting) },
                    retryTranscription: { retryTranscription(meeting) },
                    startRealtimeTranslation: { startRealtimeTranslation(targetLocale) },
                    stopRealtimeTranslation: stopRealtimeTranslation,
                    setMeetingGoal: setMeetingGoal,
                    liveTranslationCanStop: liveTranslationCanStop(realtimeTranslationStatus)
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

    private func translationLinkText(for configuration: SpeechTranscriptionConfiguration) -> String {
        let providerID = configuration.translationExecutionMode == .hosted
            ? configuration.hostedTranslationProviderID
            : configuration.localTranslationProviderID
        return "\(modeDisplayName(configuration.translationExecutionMode)) / \(providerDisplayName(providerID))"
    }

    private func translationModelText(for configuration: SpeechTranscriptionConfiguration) -> String {
        guard configuration.translationExecutionMode == .hosted else {
            return "Local model"
        }
        return modelDisplayName(
            configuration.hostedTranslationModelID,
            in: BilingualPipelineFactory.hostedTranslationModelOptions
        )
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

    private func liveTranslationCanStop(_ status: RealtimeTranslationStatus) -> Bool {
        switch status {
        case .connecting, .connected, .degraded:
            return true
        case .idle, .failed:
            return false
        }
    }

    private func liveTranslationStatusText(_ status: RealtimeTranslationStatus) -> String {
        switch status {
        case .idle:
            return "Live translation idle"
        case .connecting:
            return "Connecting live translation"
        case .connected:
            return "Live translation connected"
        case .degraded(let message):
            return "Live translation degraded: \(message)"
        case .failed(let message):
            return "Live translation failed: \(message)"
        }
    }

    private func liveTranslationStatusColor(_ status: RealtimeTranslationStatus) -> Color {
        switch status {
        case .failed:
            return CommandCenterPalette.danger
        case .degraded:
            return CommandCenterPalette.warning
        default:
            return CommandCenterPalette.secondaryText
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
    let translationLinkText: String
    let translationModelText: String
    let preflightText: String
    let actualTranscriptionSourceText: String
    let statusText: String
    let isRecording: Bool
    let realtimeTranslationStatus: RealtimeTranslationStatus
    let liveCaptionTurns: [LiveCaptionTurn]
    let meetingGoal: MeetingGoal?
    let meetingProgressState: MeetingProgressState?
    let meetingProgressHealth: MeetingProgressHealth
    let liveTranslationTurns: [LiveTranslationTurn]
    @Binding var targetLocale: String
    let transcriptText: String
    let transcriptionStatusText: String
    let liveTranslationStatusText: String
    let liveTranslationStatusColor: Color
    let summary: MeetingSummary?
    let stopRecording: () -> Void
    let copySummary: () -> Void
    let exportTranscript: () -> Void
    let exportMeetingData: () -> Void
    let exportReadinessReport: () -> Void
    let retryTranscription: () -> Void
    let startRealtimeTranslation: () -> Void
    let stopRealtimeTranslation: () -> Void
    let setMeetingGoal: (MeetingGoal?) -> Void
    let liveTranslationCanStop: Bool

    var body: some View {
        HStack(spacing: 0) {
            TranscriptPaneView(
                meeting: meeting,
                pipelineDisplayName: pipelineDisplayName,
                transcriptionLinkText: transcriptionLinkText,
                transcriptionModelText: transcriptionModelText,
                translationLinkText: translationLinkText,
                translationModelText: translationModelText,
                preflightText: preflightText,
                actualTranscriptionSourceText: actualTranscriptionSourceText,
                statusText: statusText,
                isRecording: isRecording,
                realtimeTranslationStatus: realtimeTranslationStatus,
                liveCaptionTurns: liveCaptionTurns,
                liveTranslationTurns: liveTranslationTurns,
                targetLocale: $targetLocale,
                transcriptText: transcriptText,
                transcriptionStatusText: transcriptionStatusText,
                liveTranslationStatusText: liveTranslationStatusText,
                liveTranslationStatusColor: liveTranslationStatusColor,
                stopRecording: stopRecording,
                retryTranscription: retryTranscription,
                startRealtimeTranslation: startRealtimeTranslation,
                stopRealtimeTranslation: stopRealtimeTranslation,
                liveTranslationCanStop: liveTranslationCanStop
            )
            .frame(minWidth: 520)

            Divider()
                .overlay(CommandCenterPalette.border)

            InsightPaneView(
                meeting: meeting,
                isRecording: isRecording,
                liveCaptionTurns: liveCaptionTurns,
                meetingGoal: meetingGoal,
                meetingProgressState: meetingProgressState,
                meetingProgressHealth: meetingProgressHealth,
                summary: summary,
                copySummary: copySummary,
                exportTranscript: exportTranscript,
                exportMeetingData: exportMeetingData,
                exportReadinessReport: exportReadinessReport,
                setMeetingGoal: setMeetingGoal
            )
            .frame(minWidth: 360, idealWidth: 440, maxWidth: 520)
        }
        .background(CommandCenterPalette.window)
    }
}

private struct TranscriptPaneView: View {
    let meeting: MeetingRecord
    let pipelineDisplayName: String
    let transcriptionLinkText: String
    let transcriptionModelText: String
    let translationLinkText: String
    let translationModelText: String
    let preflightText: String
    let actualTranscriptionSourceText: String
    let statusText: String
    let isRecording: Bool
    let realtimeTranslationStatus: RealtimeTranslationStatus
    let liveCaptionTurns: [LiveCaptionTurn]
    let liveTranslationTurns: [LiveTranslationTurn]
    @Binding var targetLocale: String
    let transcriptText: String
    let transcriptionStatusText: String
    let liveTranslationStatusText: String
    let liveTranslationStatusColor: Color
    let stopRecording: () -> Void
    let retryTranscription: () -> Void
    let startRealtimeTranslation: () -> Void
    let stopRealtimeTranslation: () -> Void
    let liveTranslationCanStop: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            progress
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    metadata
                    recordingActions
                    failureReason
                    transcript
                    liveTranslation
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(28)
            }
            composer
        }
        .background(CommandCenterPalette.window)
    }

    private var header: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isRecording ? CommandCenterPalette.danger : CommandCenterPalette.mutedText)
                    .frame(width: 9, height: 9)
                Text(isRecording ? "LIVE" : "READY")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .tracking(2)
            }
            .foregroundStyle(CommandCenterPalette.text)

            Text(elapsedText)
                .commandCenterMono()

            Divider()
                .frame(height: 18)
                .overlay(CommandCenterPalette.border)

            Text(meeting.name)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(CommandCenterPalette.text)
                .lineLimit(1)

            Spacer()

            CommandCenterChip(title: "\(meeting.speechLocaleIdentifier) -> \(targetLocale)", tint: CommandCenterPalette.secondaryText)
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

    private var progress: some View {
        HStack(spacing: 14) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(CommandCenterPalette.panel)
                    Capsule()
                        .fill(CommandCenterPalette.primary.opacity(0.65))
                        .frame(width: proxy.size.width * progressFraction)
                }
            }
            .frame(height: 6)

            Text("Phase 2 - Regional P&L - 2 of 5")
                .commandCenterMono()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Current Pipeline").commandCenterEyebrow()
            HStack(spacing: 8) {
                CommandCenterChip(title: transcriptionStatusText, tint: transcriptionTint, filled: true)
                CommandCenterChip(title: "Actual STT Source: \(actualTranscriptionSourceText)", tint: CommandCenterPalette.secondaryText)
                CommandCenterChip(title: meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                if let endedAt = meeting.endedAt {
                    CommandCenterChip(title: "Ended \(endedAt.formatted(date: .omitted, time: .shortened))")
                }
            }

            HStack(spacing: 8) {
                CommandCenterChip(title: pipelineDisplayName, tint: CommandCenterPalette.primary)
                CommandCenterChip(title: "Transcription Link: \(transcriptionLinkText)", tint: CommandCenterPalette.cyan)
                CommandCenterChip(title: "Transcription Model: \(transcriptionModelText)")
                CommandCenterChip(title: "Translation Link: \(translationLinkText)", tint: CommandCenterPalette.purple)
                CommandCenterChip(title: "Translation Model: \(translationModelText)")
                CommandCenterChip(title: "Preflight: \(preflightText)", tint: preflightTint)
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
                .font(.caption)
                .foregroundStyle(CommandCenterPalette.danger)
                .textSelection(.enabled)
        }
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Transcript").commandCenterEyebrow()
            Text(transcriptText)
                .font(.system(size: 17))
                .lineSpacing(6)
                .foregroundStyle(CommandCenterPalette.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private var liveTranslation: some View {
        CommandCenterPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Live Translation").commandCenterEyebrow()
                    Spacer()
                    Text(liveTranslationStatusText)
                        .font(.caption)
                        .foregroundStyle(liveTranslationStatusColor)
                }

                if liveTranslationTurns.isEmpty {
                    Text("Translated turns will appear here while the meeting is live.")
                        .foregroundStyle(CommandCenterPalette.secondaryText)
                } else {
                    ForEach(liveTranslationTurns.suffix(5)) { turn in
                        Text(turn.text)
                            .foregroundStyle(turn.isFinal ? CommandCenterPalette.text : CommandCenterPalette.secondaryText)
                            .textSelection(.enabled)
                    }
                }

                HStack {
                    Picker("Target", selection: $targetLocale) {
                        ForEach(MeetingAgentViewModel.supportedLocaleIdentifiers, id: \.self) { locale in
                            Text(locale).tag(locale)
                        }
                    }
                    .frame(maxWidth: 160)

                    Button("Start Live Translation") {
                        startRealtimeTranslation()
                    }
                    .buttonStyle(CommandCenterActionButtonStyle(variant: .secondary))
                    .disabled(!isRecording || realtimeTranslationStatus == .connecting || realtimeTranslationStatus == .connected)

                    Button("Stop Live Translation") {
                        stopRealtimeTranslation()
                    }
                    .buttonStyle(CommandCenterActionButtonStyle(variant: .danger))
                    .disabled(!liveTranslationCanStop)
                }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "mic")
                    .foregroundStyle(CommandCenterPalette.danger)
                    .frame(width: 42, height: 42)
                    .background(CommandCenterPalette.danger.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(CommandCenterPalette.danger.opacity(0.45), lineWidth: 1)
                    )

                Text("Type what you want to say in Chinese or English")
                    .foregroundStyle(CommandCenterPalette.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(CommandCenterPalette.panelRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                Button {
                    startRealtimeTranslation()
                } label: {
                    Label("Send to call", systemImage: "paperplane")
                }
                .buttonStyle(CommandCenterActionButtonStyle(variant: .primary))
                .disabled(!isRecording || realtimeTranslationStatus == .connecting || realtimeTranslationStatus == .connected)
            }

            HStack {
                Text("Mic into app is isolated - your speech will not leak into the meeting")
                Spacer()
                Text(statusText)
            }
            .font(.caption)
            .foregroundStyle(CommandCenterPalette.mutedText)
        }
        .padding(18)
        .background(CommandCenterPalette.surface)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(CommandCenterPalette.border)
                .frame(height: 1)
        }
    }

    private var elapsedText: String {
        let interval = (meeting.endedAt ?? Date()).timeIntervalSince(meeting.startedAt)
        let minutes = max(Int(interval) / 60, 0)
        let seconds = max(Int(interval) % 60, 0)
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private var progressFraction: CGFloat {
        guard isRecording else { return 1 }
        let interval = Date().timeIntervalSince(meeting.startedAt)
        return min(max(interval / 3600, 0.05), 1)
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

    private var preflightTint: Color {
        preflightText == "Primary chain ready" ? CommandCenterPalette.primary : CommandCenterPalette.danger
    }
}

private struct InsightPaneView: View {
    let meeting: MeetingRecord
    let isRecording: Bool
    let liveCaptionTurns: [LiveCaptionTurn]
    let meetingGoal: MeetingGoal?
    let meetingProgressState: MeetingProgressState?
    let meetingProgressHealth: MeetingProgressHealth
    let summary: MeetingSummary?
    let copySummary: () -> Void
    let exportTranscript: () -> Void
    let exportMeetingData: () -> Void
    let exportReadinessReport: () -> Void
    let setMeetingGoal: (MeetingGoal?) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    phaseSummary
                    liveGoalCockpit
                    goalComposer
                    suggestedReplies
                    exports
                    summaryPanel
                }
                .padding(22)
            }
        }
        .background(CommandCenterPalette.surface)
    }

    private var phaseSummary: some View {
        CommandCenterPanel {
            VStack(alignment: .leading, spacing: 12) {
                Text("Phase Summary - Regional P&L").commandCenterEyebrow()
                Text(summary?.overview.isEmpty == false ? summary?.overview ?? "" : "Meeting progress, risks, and decisions will appear here as the transcript develops.")
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

    private var suggestedReplies: some View {
        CommandCenterPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Suggested Replies").commandCenterEyebrow()
                    Spacer()
                    Text("from live translation")
                        .commandCenterMono()
                }
                Text("Use the live translation controls to prepare localized wording during the meeting.")
                    .foregroundStyle(CommandCenterPalette.secondaryText)
                CommandCenterChip(title: "REFRAME", tint: CommandCenterPalette.cyan)
            }
        }
    }

    private var liveGoalCockpit: some View {
        LiveMeetingDashboardView(
            captions: liveCaptionTurns,
            progress: meetingProgressState,
            health: meetingProgressHealth,
            copyEnglishQuestion: copyToPasteboard
        )
    }

    private var goalComposer: some View {
        GoalComposerPanel(
            currentGoal: meetingProgressState?.goal,
            draftGoal: meetingGoal,
            setMeetingGoal: setMeetingGoal
        )
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
                        exportReadinessReport()
                    } label: {
                        Label("Readiness Report", systemImage: "checklist")
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
                Text("Goal Progress").commandCenterEyebrow()
                if let summary {
                    if summary.status == .failed {
                        Text(summary.failureReason ?? "Summary generation failed.")
                            .foregroundStyle(CommandCenterPalette.danger)
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

private struct LiveMeetingDashboardView: View {
    let captions: [LiveCaptionTurn]
    let progress: MeetingProgressState?
    let health: MeetingProgressHealth
    let copyEnglishQuestion: (String) -> Void

    var body: some View {
        CommandCenterPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Text("Live Goal Cockpit").commandCenterEyebrow()
                    Spacer()
                    LiveHealthChip(title: "Captions", health: health.caption)
                    LiveHealthChip(title: "Translation", health: health.translation)
                    LiveHealthChip(title: "Analysis", health: health.analysis)
                }

                if let latestCaption = captions.last {
                    CaptionTurnView(turn: latestCaption)
                }

                GoalStatusPanel(progress: progress, copyEnglishQuestion: copyEnglishQuestion)
            }
        }
    }
}

private struct CaptionTurnView: View {
    let turn: LiveCaptionTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(turn.speaker.label ?? turn.speaker.identifier ?? "Speaker")
                    .commandCenterMono()
                Text(turn.isFinal ? "final" : "partial")
                    .commandCenterMono()
            }
            Text(turn.originalText)
                .font(.system(size: 17, weight: .regular))
                .lineSpacing(5)
                .foregroundStyle(turn.isFinal ? CommandCenterPalette.text : CommandCenterPalette.secondaryText)
                .textSelection(.enabled)
            if let translatedText = turn.translatedText, !translatedText.isEmpty {
                Text(translatedText)
                    .font(.system(size: 15, weight: .regular))
                    .lineSpacing(4)
                    .foregroundStyle(CommandCenterPalette.secondaryText)
                    .textSelection(.enabled)
            } else if turn.translationHealth == .pending {
                Text("Translating...")
                    .commandCenterMono()
            }
        }
    }
}

private struct GoalStatusPanel: View {
    let progress: MeetingProgressState?
    let copyEnglishQuestion: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let progress {
                HStack {
                    Text(progress.goal.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(CommandCenterPalette.text)
                        .lineLimit(1)
                    Spacer()
                    CommandCenterChip(title: progress.status.displayText.uppercased(), tint: statusTint, filled: true)
                }

                ForEach(progress.objectives, id: \.objectiveID) { objective in
                    HStack(spacing: 8) {
                        Image(systemName: objective.status == .confirmed ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(objective.status == .confirmed ? CommandCenterPalette.primary : CommandCenterPalette.secondaryText)
                        Text(objective.title)
                            .foregroundStyle(CommandCenterPalette.secondaryText)
                            .lineLimit(2)
                    }
                }

                ForEach(progress.suggestedQuestions.prefix(3)) { suggestion in
                    SuggestedQuestionRow(suggestion: suggestion, copyEnglishQuestion: copyEnglishQuestion)
                }
            } else {
                Text("No meeting goal set.")
                    .foregroundStyle(CommandCenterPalette.secondaryText)
            }
        }
    }

    private var statusTint: Color {
        switch progress?.status {
        case .onTrack:
            return CommandCenterPalette.primary
        case .partiallyCovered:
            return CommandCenterPalette.warning
        case .blocked:
            return CommandCenterPalette.danger
        case .notStarted, nil:
            return CommandCenterPalette.secondaryText
        }
    }
}

private struct GoalComposerPanel: View {
    let currentGoal: MeetingGoal?
    let draftGoal: MeetingGoal?
    let setMeetingGoal: (MeetingGoal?) -> Void
    @State private var title = ""
    @State private var objectivesText = ""
    @State private var requiredQuestionsText = ""
    @State private var keyTermsText = ""

    var body: some View {
        CommandCenterPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Meeting Goal").commandCenterEyebrow()
                    Spacer()
                    if currentGoal != nil || draftGoal != nil {
                        CommandCenterChip(title: "SET", tint: CommandCenterPalette.primary, filled: true)
                    }
                }

                TextField("Goal title", text: $title)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(CommandCenterPalette.panelRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 8) {
                    LabeledTextEditor(title: "Objectives", text: $objectivesText, minHeight: 76)
                    LabeledTextEditor(title: "Required Questions", text: $requiredQuestionsText, minHeight: 64)
                    LabeledTextEditor(title: "Key Terms", text: $keyTermsText, minHeight: 54)
                }

                HStack {
                    Button {
                        setMeetingGoal(buildGoal())
                    } label: {
                        Label("Apply Goal", systemImage: "target")
                    }
                    .buttonStyle(CommandCenterActionButtonStyle(variant: .primary))
                    .disabled(!canApply)

                    Button {
                        clearDraft()
                        setMeetingGoal(nil)
                    } label: {
                        Label("Clear", systemImage: "xmark.circle")
                    }
                    .buttonStyle(CommandCenterActionButtonStyle())
                    .disabled(!canClear)
                }
            }
        }
        .onAppear(perform: seedDraftIfNeeded)
        .onChange(of: currentGoal?.id) {
            seedDraftIfNeeded()
        }
        .onChange(of: draftGoal?.id) {
            seedDraftIfNeeded()
        }
    }

    private var canApply: Bool {
        !normalized(title).isEmpty && !parsedLines(objectivesText).isEmpty
    }

    private var canClear: Bool {
        currentGoal != nil || draftGoal != nil || !normalized(title).isEmpty || !normalized(objectivesText).isEmpty
            || !normalized(requiredQuestionsText).isEmpty || !normalized(keyTermsText).isEmpty
    }

    private func buildGoal() -> MeetingGoal {
        let objectives = parsedLines(objectivesText).enumerated().map { index, line in
            MeetingObjective(
                id: "objective-\(index + 1)",
                title: line,
                keywords: keywords(from: line)
            )
        }
        let requiredQuestions = parsedLines(requiredQuestionsText)
        let terms = parsedLines(keyTermsText).map { MeetingKeyTerm(value: $0) }
        return MeetingGoal(
            title: normalized(title),
            objectives: objectives,
            requiredQuestions: requiredQuestions,
            expectedDecisions: [],
            keyTerms: terms
        )
    }

    private func seedDraftIfNeeded() {
        guard let goal = currentGoal ?? draftGoal else { return }
        title = goal.title
        objectivesText = goal.objectives.map(\.title).joined(separator: "\n")
        requiredQuestionsText = goal.requiredQuestions.joined(separator: "\n")
        keyTermsText = goal.keyTerms.map(\.value).joined(separator: "\n")
    }

    private func clearDraft() {
        title = ""
        objectivesText = ""
        requiredQuestionsText = ""
        keyTermsText = ""
    }

    private func parsedLines(_ value: String) -> [String] {
        value
            .components(separatedBy: .newlines)
            .map(normalized)
            .filter { !$0.isEmpty }
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func keywords(from objective: String) -> [String] {
        let words = objective
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map(normalized)
            .filter { $0.count >= 4 }
        return Array(Set(words)).sorted()
    }
}

private struct LabeledTextEditor: View {
    let title: String
    @Binding var text: String
    let minHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .commandCenterMono()
            TextEditor(text: $text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .foregroundStyle(CommandCenterPalette.text)
                .frame(minHeight: minHeight)
                .padding(8)
                .background(CommandCenterPalette.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

private struct SuggestedQuestionRow: View {
    let suggestion: FollowUpQuestionSuggestion
    let copyEnglishQuestion: (String) -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Ask next").commandCenterEyebrow()
            Text("中文：\(suggestion.chinese)")
                .foregroundStyle(CommandCenterPalette.text)
                .textSelection(.enabled)
            HStack(alignment: .top, spacing: 8) {
                Text("EN: \(suggestion.english)")
                    .foregroundStyle(CommandCenterPalette.secondaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    copyEnglishQuestion(suggestion.english)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(CommandCenterActionButtonStyle())
            }
        }
        .padding(.top, 4)
    }
}

private struct LiveHealthChip: View {
    let title: String
    let health: LivePipelineHealth

    var body: some View {
        CommandCenterChip(title: "\(title): \(label)", tint: tint)
    }

    private var label: String {
        switch health {
        case .idle:
            return "idle"
        case .pending:
            return "pending"
        case .live:
            return "live"
        case .degraded:
            return "delayed"
        case .failed:
            return "failed"
        }
    }

    private var tint: Color {
        switch health {
        case .live:
            return CommandCenterPalette.primary
        case .pending, .degraded:
            return CommandCenterPalette.warning
        case .failed:
            return CommandCenterPalette.danger
        case .idle:
            return CommandCenterPalette.secondaryText
        }
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
                    .font(.system(size: 13, weight: .bold))
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
