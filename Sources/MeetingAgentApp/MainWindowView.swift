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
    let liveTranslationTurns: [LiveTranslationTurn]
    let stopRecording: () -> Void
    let copySummary: (MeetingRecord) -> Void
    let exportTranscript: (MeetingRecord) -> Void
    let exportMeetingData: (MeetingRecord) -> Void
    let exportReadinessReport: (MeetingRecord) -> Void
    let retryTranscription: (MeetingRecord) -> Void
    let startRealtimeTranslation: (String) -> Void
    let stopRealtimeTranslation: () -> Void
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
                summary: summary,
                copySummary: copySummary,
                exportTranscript: exportTranscript,
                exportMeetingData: exportMeetingData,
                exportReadinessReport: exportReadinessReport
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
    let summary: MeetingSummary?
    let copySummary: () -> Void
    let exportTranscript: () -> Void
    let exportMeetingData: () -> Void
    let exportReadinessReport: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    phaseSummary
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
