import AppKit
import MeetingAgentCore
import SwiftUI

struct MainWindowView: View {
    @ObservedObject var viewModel: MeetingAgentViewModel
    @State private var showSettings = false

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
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

                List(selection: Binding(
                    get: { showSettings ? nil : viewModel.selectedMeetingID },
                    set: { id in
                        showSettings = false
                        viewModel.selectMeeting(id)
                    }
                )) {
                    Section {
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
                    } header: {
                        Text("Meetings")
                            .foregroundStyle(CommandCenterPalette.secondaryText)
                    }
                }
                .scrollContentBackground(.hidden)
                .foregroundStyle(CommandCenterPalette.text)

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
        .background(CommandCenterPalette.window)
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

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    metadata
                    recordingActions
                    failureReason
                    liveCaptions
                    transcript
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(28)
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

    private var liveCaptions: some View {
        CommandCenterPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Live Captions").commandCenterEyebrow()
                    Spacer()
                    CommandCenterChip(
                        title: liveCaptionTurns.isEmpty ? "Waiting for speech" : "\(liveCaptionTurns.count) turns",
                        tint: liveCaptionTurns.isEmpty ? CommandCenterPalette.secondaryText : CommandCenterPalette.primary
                    )
                }

                if liveCaptionTurns.isEmpty {
                    Text(isRecording ? "Listening..." : "Recorded captions will appear here.")
                        .foregroundStyle(CommandCenterPalette.secondaryText)
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(liveCaptionTurns.suffix(8)) { turn in
                            CaptionTurnView(
                                turn: turn,
                                editSpeaker: turn.speaker.identifier == nil ? nil : {
                                    speakerLabelDraft = turn.speaker.label ?? turn.speaker.identifier ?? ""
                                    speakerEditTarget = turn
                                },
                                editText: {
                                    transcriptTextDraft = turn.originalText
                                    transcriptEditTarget = turn
                                }
                            )
                            if turn.id != liveCaptionTurns.suffix(8).last?.id {
                                Divider().overlay(CommandCenterPalette.border)
                            }
                        }
                    }
                }
            }
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
    let exportSRT: () -> Void
    let exportVTT: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    phaseSummary
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

private struct CaptionTurnView: View {
    let turn: LiveCaptionTurn
    var editSpeaker: (() -> Void)? = nil
    var editText: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(turn.speaker.label ?? turn.speaker.identifier ?? "Speaker")
                    .commandCenterMono()
                Text(turn.isFinal ? "final" : "partial")
                    .commandCenterMono()
                Spacer()
                if let editSpeaker {
                    Button {
                        editSpeaker()
                    } label: {
                        Image(systemName: "person.crop.circle.badge.pencil")
                    }
                    .buttonStyle(CommandCenterIconButtonStyle())
                    .help("Edit speaker")
                }
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

private struct CaptionEditSheet: View {
    let title: String
    @Binding var text: String
    let saveTitle: String
    let save: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).commandCenterEyebrow()
            TextEditor(text: $text)
                .font(.system(size: 15))
                .foregroundStyle(CommandCenterPalette.text)
                .scrollContentBackground(.hidden)
                .frame(width: 420, height: 130)
                .padding(8)
                .background(CommandCenterPalette.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(CommandCenterPalette.border, lineWidth: 1)
                )
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
