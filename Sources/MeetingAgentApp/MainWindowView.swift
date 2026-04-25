import MeetingAgentCore
import SwiftUI

struct MainWindowView: View {
    @ObservedObject var viewModel: MeetingAgentViewModel

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 12) {
                TextField(
                    "STT Locale",
                    text: Binding(
                        get: { viewModel.speechLocaleIdentifier },
                        set: { viewModel.updateSpeechLocaleIdentifier($0) }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .disabled(viewModel.isRecording)
                .padding([.horizontal, .top], 12)

                List(selection: Binding(
                    get: { viewModel.selectedMeetingID },
                    set: { viewModel.selectMeeting($0) }
                )) {
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
            .navigationTitle("Meetings")
        } detail: {
            MeetingDetailView(
                meeting: viewModel.selectedMeeting,
                statusText: viewModel.statusText,
                isRecording: viewModel.isRecording,
                stopRecording: {
                    viewModel.stopRecording()
                }
            )
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
}

private struct MeetingDetailView: View {
    let meeting: MeetingRecord?
    let statusText: String
    let isRecording: Bool
    let stopRecording: () -> Void

    var body: some View {
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
                Button("Stop Recording") {
                    stopRecording()
                }
                .disabled(!isRecording)
                Divider()
                Text("Transcript")
                    .font(.headline)
                ScrollView {
                    Text(transcriptText(for: meeting))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            } else {
                ContentUnavailableView(
                    "No Meeting Selected",
                    systemImage: "waveform",
                    description: Text("Detected and recorded meetings will appear here.")
                )
            }
        }
        .padding(20)
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
}
