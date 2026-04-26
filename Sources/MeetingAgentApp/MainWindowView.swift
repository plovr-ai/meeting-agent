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
                                Text(meeting.startedAt, style: .date)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(Optional(meeting.id))
                        }
                    }
                }

                Spacer()

                Divider()

                Button {
                    showSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(12)
                .background(showSettings ? Color.accentColor.opacity(0.12) : Color.clear)
            }
            .navigationTitle("Meeting Agent")
        } detail: {
            if showSettings {
                SettingsView(
                    configuration: viewModel.speechConfiguration,
                    profiles: BilingualPipelineFactory.builtInProfiles,
                    localeIdentifiers: MeetingAgentViewModel.supportedLocaleIdentifiers,
                    isRecording: viewModel.isRecording,
                    status: viewModel.speechConfigurationStatus,
                    save: { viewModel.saveSpeechConfiguration($0) }
                )
            } else {
                MeetingDetailView(
                    meeting: viewModel.selectedMeeting,
                    statusText: viewModel.statusText,
                    isRecording: viewModel.isRecording,
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
                    }
                )
            }
        }
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
    let statusText: String
    let isRecording: Bool
    let stopRecording: () -> Void
    let copySummary: (MeetingRecord) -> Void
    let exportTranscript: (MeetingRecord) -> Void
    let exportMeetingData: (MeetingRecord) -> Void
    let exportReadinessReport: (MeetingRecord) -> Void
    let retryTranscription: (MeetingRecord) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let meeting {
                    Text(meeting.name)
                        .font(.largeTitle)
                    Text(statusText)
                        .foregroundStyle(.secondary)
                    LabeledContent("Started", value: meeting.startedAt.formatted(date: .abbreviated, time: .standard))
                    if let endedAt = meeting.endedAt {
                        LabeledContent("Ended", value: endedAt.formatted(date: .abbreviated, time: .standard))
                    }
                    LabeledContent("Audio", value: meeting.audioURL?.path ?? "Not recorded")
                    LabeledContent("STT Provider", value: meeting.speechProvider.rawValue)
                    LabeledContent("Language", value: meeting.speechLocaleIdentifier)
                    LabeledContent("Transcription", value: transcriptionStatusText(for: meeting))
                    if let failureReason = meeting.transcriptionFailureReason {
                        Text(failureReason)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    HStack(spacing: 12) {
                        Button("Stop Recording") {
                            stopRecording()
                        }
                        .disabled(!isRecording)
                        Button("Retry Transcription") {
                            retryTranscription(meeting)
                        }
                        .disabled(isRecording || meeting.audioURL == nil)
                    }
                    Divider()
                    Text("Exports")
                        .font(.headline)
                    HStack {
                        Button {
                            copySummary(meeting)
                        } label: {
                            Label("Copy Summary", systemImage: "doc.on.clipboard")
                        }
                        .disabled(isRecording || meeting.summaryURL == nil)

                        Button {
                            exportTranscript(meeting)
                        } label: {
                            Label("Transcript", systemImage: "doc.text")
                        }
                        .disabled(isRecording || meeting.transcriptURL == nil)
                    }
                    HStack {
                        Button {
                            exportMeetingData(meeting)
                        } label: {
                            Label("Meeting JSON", systemImage: "curlybraces")
                        }

                        Button {
                            exportReadinessReport(meeting)
                        } label: {
                            Label("Readiness Report", systemImage: "checklist")
                        }
                    }
                    Divider()
                    Text("Summary")
                        .font(.headline)
                    summaryView(for: meeting)
                    Divider()
                    Text("Transcript")
                        .font(.headline)
                    Text(transcriptText(for: meeting))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                } else {
                    ContentUnavailableView(
                        "No Meeting Selected",
                        systemImage: "waveform",
                        description: Text("Detected and recorded meetings will appear here.")
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
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

    @ViewBuilder
    private func summaryView(for meeting: MeetingRecord) -> some View {
        if let summary = summary(for: meeting) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if summary.status == .failed {
                        Text(summary.failureReason ?? "Summary generation failed.")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    } else {
                        if !summary.overview.isEmpty {
                            Text(summary.overview)
                                .textSelection(.enabled)
                        }
                        summaryList(title: "Decisions", items: summary.decisions.map(\.description))
                        summaryList(title: "Action Items", items: summary.actionItems.map(\.description))
                        summaryList(title: "Open Questions", items: summary.openQuestions)
                        summaryList(title: "Risks", items: summary.risks)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 120, maxHeight: 220)
        } else {
            Text("No summary generated yet.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func summaryList(title: String, items: [String]) -> some View {
        let visibleItems = items.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !visibleItems.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline)
                    .bold()
                ForEach(Array(visibleItems.enumerated()), id: \.offset) { _, item in
                    Text("- \(item)")
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func summary(for meeting: MeetingRecord) -> MeetingSummary? {
        guard let summaryJSONURL = meeting.summaryJSONURL else { return nil }
        return try? MeetingSummaryWriter.read(from: summaryJSONURL)
    }
}
