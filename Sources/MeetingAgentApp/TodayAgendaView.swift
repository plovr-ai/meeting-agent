import MeetingAgentCore
import SwiftUI

struct TodayAgendaView: View {
    let meetings: [MeetingRecord]
    let selectedMeetingID: UUID?
    let activeMeetingID: UUID?
    let pendingCandidate: AudioCaptureTarget?
    let isRecording: Bool
    let selectMeeting: (MeetingRecord) -> Void
    let openWorkspace: (MeetingRecord) -> Void
    let startRecording: (MeetingRecord) -> Void
    let saveAgenda: (UUID, MeetingAgendaUpdate) throws -> Void
    let createMeeting: () throws -> Void

    @State private var draft = AgendaDraft()
    @State private var draftMeetingID: UUID?
    @State private var saveError: String?
    @State private var createError: String?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                agendaList
            }
            .frame(minWidth: 520)

            Divider()
                .overlay(CommandCenterPalette.border)

            AgendaEditorView(
                meeting: selectedMeeting,
                draft: $draft,
                saveError: saveError,
                save: saveSelectedAgenda,
                cancel: resetDraftFromSelection
            )
            .frame(minWidth: 360, idealWidth: 400, maxWidth: 440)
        }
        .background(CommandCenterPalette.window)
        .onAppear(perform: resetDraftFromSelection)
        .onChange(of: selectedMeetingID) { _, _ in
            resetDraftFromSelection()
        }
        .onChange(of: meetings) { _, _ in
            guard draftMeetingID == selectedMeetingID else {
                resetDraftFromSelection()
                return
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Today")
                    .font(CommandCenterTypography.title)
                    .foregroundStyle(CommandCenterPalette.text)
                Text(Date().formatted(date: .complete, time: .omitted))
                    .font(CommandCenterTypography.caption)
                    .foregroundStyle(CommandCenterPalette.secondaryText)
            }
            Spacer()
            CommandCenterChip(title: "\(todayMeetings.count) meetings")
            if let activeMeetingID, meetings.contains(where: { $0.id == activeMeetingID }) {
                CommandCenterChip(title: "Live recording", tint: CommandCenterPalette.primary, filled: true)
            }
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

    @ViewBuilder
    private var agendaList: some View {
        if todayMeetings.isEmpty {
            CommandCenterPanel {
                VStack(alignment: .leading, spacing: 12) {
                    Text("No meetings scheduled today")
                        .font(CommandCenterTypography.title)
                        .foregroundStyle(CommandCenterPalette.text)
                    Text("Create a local agenda item to prepare attendees, topics, and meeting goals before recording.")
                        .font(CommandCenterTypography.secondaryBody)
                        .foregroundStyle(CommandCenterPalette.secondaryText)
                    if let createError {
                        Text(createError)
                            .font(CommandCenterTypography.caption)
                            .foregroundStyle(CommandCenterPalette.danger)
                    }
                    Button("Create Meeting") {
                        do {
                            try createMeeting()
                            createError = nil
                        } catch {
                            createError = "Could not create meeting: \(error)"
                        }
                    }
                    .buttonStyle(CommandCenterActionButtonStyle(variant: .primary))
                }
            }
            .padding(24)
        } else {
            CommandCenterScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(todayMeetings) { meeting in
                        AgendaRowView(
                            meeting: meeting,
                            isSelected: meeting.id == selectedMeetingID,
                            isActive: meeting.id == activeMeetingID,
                            actionTitle: actionTitle(for: meeting),
                            select: {
                                selectMeeting(meeting)
                            },
                            primaryAction: {
                                primaryAction(for: meeting)
                            }
                        )
                    }
                }
                .padding(22)
            }
        }
    }

    private var todayMeetings: [MeetingRecord] {
        meetings.sorted { lhs, rhs in
            displayDate(for: lhs) < displayDate(for: rhs)
        }
    }

    private var selectedMeeting: MeetingRecord? {
        if let selectedMeetingID,
           let selected = meetings.first(where: { $0.id == selectedMeetingID }) {
            return selected
        }
        return todayMeetings.first
    }

    private func actionTitle(for meeting: MeetingRecord) -> String {
        if hasReadableTranscript(meeting) {
            return "Open Transcript"
        }
        if pendingCandidate != nil && !isRecording {
            return "Start Recording"
        }
        return "Open Workspace"
    }

    private func primaryAction(for meeting: MeetingRecord) {
        if pendingCandidate != nil && !isRecording && !hasReadableTranscript(meeting) {
            startRecording(meeting)
        } else {
            openWorkspace(meeting)
        }
    }

    private func displayDate(for meeting: MeetingRecord) -> Date {
        meeting.scheduledStartAt ?? meeting.startedAt
    }

    private func hasReadableTranscript(_ meeting: MeetingRecord) -> Bool {
        guard let transcriptURL = meeting.transcriptURL else { return false }
        return FileManager.default.isReadableFile(atPath: transcriptURL.path)
    }

    private func resetDraftFromSelection() {
        guard let selectedMeeting else {
            draft = AgendaDraft()
            draftMeetingID = nil
            saveError = nil
            return
        }
        draft = AgendaDraft(meeting: selectedMeeting)
        draftMeetingID = selectedMeeting.id
        saveError = nil
    }

    private func saveSelectedAgenda() {
        guard let meetingID = selectedMeeting?.id else { return }
        do {
            try saveAgenda(meetingID, draft.update())
            saveError = nil
            draftMeetingID = meetingID
        } catch {
            saveError = "Could not save agenda: \(error)"
        }
    }
}

private struct AgendaRowView: View {
    let meeting: MeetingRecord
    let isSelected: Bool
    let isActive: Bool
    let actionTitle: String
    let select: () -> Void
    let primaryAction: () -> Void

    var body: some View {
        Button {
            select()
        } label: {
            HStack(alignment: .top, spacing: 14) {
                Text(timeRange)
                    .font(CommandCenterTypography.mono)
                    .foregroundStyle(CommandCenterPalette.secondaryText)
                    .frame(width: 76, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(meeting.name)
                            .font(CommandCenterTypography.title)
                            .foregroundStyle(CommandCenterPalette.text)
                            .lineLimit(2)
                        if isActive {
                            CommandCenterChip(title: "Live", tint: CommandCenterPalette.primary, filled: true)
                        }
                    }
                    Text(goalText)
                        .font(CommandCenterTypography.secondaryBody)
                        .foregroundStyle(CommandCenterPalette.secondaryText)
                        .lineLimit(2)
                    chips
                }

                Spacer(minLength: 12)

                Button(actionTitle) {
                    primaryAction()
                }
                .buttonStyle(CommandCenterActionButtonStyle(variant: actionTitle == "Start Recording" ? .primary : .secondary))
            }
            .padding(14)
            .background(isSelected ? CommandCenterPalette.panelRaised : CommandCenterPalette.panel)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? CommandCenterPalette.primary.opacity(0.45) : CommandCenterPalette.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var chips: some View {
        HStack(spacing: 8) {
            ForEach(meeting.attendees.prefix(2)) { attendee in
                CommandCenterChip(title: attendee.name, tint: CommandCenterPalette.cyan)
            }
            if meeting.attendees.count > 2 {
                CommandCenterChip(title: "+\(meeting.attendees.count - 2)")
            }
            ForEach(meeting.agendaTopics.prefix(3)) { topic in
                CommandCenterChip(title: topic.title)
            }
            if meeting.agendaTopics.count > 3 {
                CommandCenterChip(title: "+\(meeting.agendaTopics.count - 3) topics")
            }
        }
    }

    private var goalText: String {
        let title = meeting.meetingGoal?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "No goal" : title
    }

    private var timeRange: String {
        let start = (meeting.scheduledStartAt ?? meeting.startedAt).formatted(date: .omitted, time: .shortened)
        guard let end = meeting.scheduledEndAt else { return start }
        return "\(start)\n\(end.formatted(date: .omitted, time: .shortened))"
    }
}

private struct AgendaEditorView: View {
    let meeting: MeetingRecord?
    @Binding var draft: AgendaDraft
    let saveError: String?
    let save: () -> Void
    let cancel: () -> Void

    var body: some View {
        CommandCenterScrollView(background: CommandCenterPalette.surface) {
            if meeting == nil {
                CommandCenterPanel {
                    Text("Select a meeting")
                        .font(CommandCenterTypography.title)
                        .foregroundStyle(CommandCenterPalette.secondaryText)
                }
                .padding(22)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Selected Agenda")
                        .font(CommandCenterTypography.title)
                        .foregroundStyle(CommandCenterPalette.text)
                    Text("Edit attendees, topics, time, and goal before opening the workspace.")
                        .font(CommandCenterTypography.caption)
                        .foregroundStyle(CommandCenterPalette.secondaryText)

                    if let saveError {
                        Text(saveError)
                            .font(CommandCenterTypography.caption)
                            .foregroundStyle(CommandCenterPalette.danger)
                            .textSelection(.enabled)
                    }

                    labeledTextField("Title", text: $draft.name)
                    labeledDatePicker("Scheduled Start", date: $draft.scheduledStartAt)
                    labeledDatePicker("Scheduled End", date: $draft.scheduledEndAt)
                    labeledTextEditor("Attendees", text: $draft.attendeesText)
                    labeledTextEditor("Topics", text: $draft.topicsText)
                    labeledTextEditor("Meeting Goal", text: $draft.goalText)

                    // Dirty navigation confirmation uses Save / Discard / Cancel.
                    HStack {
                        Spacer()
                        Button("Cancel") {
                            cancel()
                        }
                        .buttonStyle(CommandCenterActionButtonStyle())
                        Button("Save") {
                            save()
                        }
                        .buttonStyle(CommandCenterActionButtonStyle(variant: .primary))
                    }
                }
                .padding(22)
            }
        }
    }

    private func labeledTextField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).commandCenterEyebrow()
            TextField(title, text: text)
                .textFieldStyle(.plain)
                .font(CommandCenterTypography.secondaryBody)
                .foregroundStyle(CommandCenterPalette.text)
                .padding(10)
                .background(CommandCenterPalette.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(CommandCenterPalette.border, lineWidth: 1)
                )
        }
    }

    private func labeledTextEditor(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).commandCenterEyebrow()
            TextEditor(text: text)
                .font(CommandCenterTypography.secondaryBody)
                .foregroundStyle(CommandCenterPalette.text)
                .commandCenterScrollableSurface(CommandCenterPalette.panelRaised)
                .frame(minHeight: 76)
                .padding(8)
                .background(CommandCenterPalette.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(CommandCenterPalette.border, lineWidth: 1)
                )
        }
    }

    private func labeledDatePicker(_ title: String, date: Binding<Date?>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).commandCenterEyebrow()
            DatePicker(
                title,
                selection: Binding(
                    get: { date.wrappedValue ?? Date() },
                    set: { date.wrappedValue = $0 }
                ),
                displayedComponents: [.date, .hourAndMinute]
            )
            .labelsHidden()
            .datePickerStyle(.compact)
            .tint(CommandCenterPalette.primary)
        }
    }
}

private struct AgendaDraft: Equatable {
    var name = ""
    var attendeesText = ""
    var topicsText = ""
    var scheduledStartAt: Date?
    var scheduledEndAt: Date?
    var goalText = ""

    init() {}

    init(meeting: MeetingRecord) {
        name = meeting.name
        attendeesText = meeting.attendees
            .map { attendee in
                if let role = attendee.role, !role.isEmpty {
                    return "\(attendee.name), \(role)"
                }
                return attendee.name
            }
            .joined(separator: "\n")
        topicsText = meeting.agendaTopics.map(\.title).joined(separator: "\n")
        scheduledStartAt = meeting.scheduledStartAt ?? meeting.startedAt
        scheduledEndAt = meeting.scheduledEndAt
        goalText = meeting.meetingGoal?.title ?? ""
    }

    func update() -> MeetingAgendaUpdate {
        MeetingAgendaUpdate(
            name: name,
            attendees: attendeesText
                .split(whereSeparator: \.isNewline)
                .map { line in
                    let parts = line.split(separator: ",", maxSplits: 1).map(String.init)
                    return MeetingAttendee(name: parts.first ?? "", role: parts.dropFirst().first)
                },
            agendaTopics: topicsText
                .split(whereSeparator: \.isNewline)
                .map { MeetingAgendaTopic(title: String($0)) },
            scheduledStartAt: scheduledStartAt,
            scheduledEndAt: scheduledEndAt,
            meetingGoal: MeetingGoal(
                title: goalText,
                objectives: [],
                requiredQuestions: [],
                expectedDecisions: [],
                keyTerms: []
            )
        )
    }
}
