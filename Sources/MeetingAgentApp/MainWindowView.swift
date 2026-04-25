import MeetingAgentCore
import SwiftUI

struct MainWindowView: View {
    @ObservedObject var viewModel: MeetingAgentViewModel

    var body: some View {
        NavigationSplitView {
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
            .navigationTitle("Meetings")
        } detail: {
            MeetingDetailView(meeting: viewModel.selectedMeeting, statusText: viewModel.statusText)
        }
    }
}

private struct MeetingDetailView: View {
    let meeting: MeetingRecord?
    let statusText: String

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
        guard let transcriptURL = meeting.transcriptURL,
              let text = try? String(contentsOf: transcriptURL, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return "Transcript will appear here while recording."
        }
        return text
    }
}
