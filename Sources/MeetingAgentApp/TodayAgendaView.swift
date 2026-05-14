import MeetingAgentCore
import SwiftUI

enum AgendaListMode {
    case today
    case meetings
    case library
}

struct TodayAgendaView: View {
    let mode: AgendaListMode
    let title: String
    let emptyTitle: String
    let emptyDescription: String
    let meetings: [MeetingRecord]
    let selectedMeetingID: UUID?
    let activeMeetingID: UUID?
    let pendingCandidate: AudioCaptureTarget?
    let isRecording: Bool
    let openWorkspace: (MeetingRecord) -> Void
    let startRecording: (MeetingRecord) -> Void
    let startOfflineRecording: () -> Void
    let createMeeting: (() throws -> MeetingRecord)?

    @State private var createError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            agendaList
        }
        .frame(minWidth: 520)
        .background(CommandCenterPalette.window)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(CommandCenterTypography.title)
                    .foregroundStyle(CommandCenterPalette.text)
                Text(Date().formatted(date: .complete, time: .omitted))
                    .font(CommandCenterTypography.caption)
                    .foregroundStyle(CommandCenterPalette.secondaryText)
            }
            Spacer()
            CommandCenterChip(title: "\(editableMeetings.count) meetings")
            if let activeMeetingID, editableMeetings.contains(where: { $0.id == activeMeetingID }) {
                CommandCenterChip(title: "Live recording", tint: CommandCenterPalette.primary, filled: true)
            }
            Button {
                startOfflineRecording()
            } label: {
                Label("Record Offline", systemImage: "mic")
            }
            .buttonStyle(CommandCenterActionButtonStyle())
            .disabled(isRecording)
            .help("Start an offline microphone recording")
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
        if mode == .today {
            agendaFeed
        } else if mode == .library {
            artifactList
        } else {
            bucketAgendaList
        }
    }

    private var agendaFeed: some View {
        CommandCenterScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Agenda")
                        .font(CommandCenterTypography.title)
                        .foregroundStyle(CommandCenterPalette.text)
                    Text("Meeting schedule and metadata")
                        .font(CommandCenterTypography.caption)
                        .foregroundStyle(CommandCenterPalette.secondaryText)
                }

                AgendaFeedSection(title: "Today", count: todayMeetings.count) {
                    todayFeedContent
                }

                if !completedTodayMeetings.isEmpty {
                    AgendaFeedSection(title: "Completed Today", count: completedTodayMeetings.count) {
                        completedTodayFeedContent
                    }
                }
            }
            .padding(22)
        }
    }

    @ViewBuilder
    private var artifactList: some View {
        if sortedMeetings.isEmpty {
            emptyState
        } else {
            CommandCenterScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(sortedMeetings) { meeting in
                        MeetingArtifactCard(
                            meeting: meeting,
                            isSelected: meeting.id == selectedMeetingID,
                            open: {
                                openWorkspace(meeting)
                            }
                        )
                    }
                }
                .padding(22)
            }
        }
    }

    @ViewBuilder
    private var bucketAgendaList: some View {
        if sortedMeetings.isEmpty {
            emptyState
        } else {
            CommandCenterScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(sortedMeetings) { meeting in
                        AgendaRowView(
                            meeting: meeting,
                            isSelected: meeting.id == selectedMeetingID,
                            isActive: meeting.id == activeMeetingID,
                            actionTitle: actionTitle(for: meeting),
                            select: {
                                openWorkspace(meeting)
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

    @ViewBuilder
    private var todayFeedContent: some View {
        if todayMeetings.isEmpty {
            emptyState
        } else {
            ForEach(todayMeetings) { meeting in
                AgendaRowView(
                    meeting: meeting,
                    isSelected: meeting.id == selectedMeetingID,
                    isActive: meeting.id == activeMeetingID,
                    actionTitle: actionTitle(for: meeting),
                    select: {
                        openWorkspace(meeting)
                    },
                    primaryAction: {
                        primaryAction(for: meeting)
                    }
                )
            }
        }
    }

    private var completedTodayFeedContent: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(completedTodayMeetings) { meeting in
                MeetingArtifactCard(
                    meeting: meeting,
                    isSelected: meeting.id == selectedMeetingID,
                    open: {
                        openWorkspace(meeting)
                    }
                )
            }
        }
    }

    private var emptyState: some View {
        CommandCenterPanel {
            VStack(alignment: .leading, spacing: 12) {
                Text(emptyTitle)
                    .font(CommandCenterTypography.title)
                    .foregroundStyle(CommandCenterPalette.text)
                Text(emptyDescription)
                    .font(CommandCenterTypography.secondaryBody)
                    .foregroundStyle(CommandCenterPalette.secondaryText)
                if let createError {
                    Text(createError)
                        .font(CommandCenterTypography.caption)
                        .foregroundStyle(CommandCenterPalette.danger)
                }
                if let createMeeting {
                    Button("Create Meeting") {
                        do {
                            let meeting = try createMeeting()
                            openWorkspace(meeting)
                            createError = nil
                        } catch {
                            createError = "Could not create meeting: \(error)"
                        }
                    }
                    .buttonStyle(CommandCenterActionButtonStyle(variant: .primary))
                }
            }
        }
    }

    private var sortedMeetings: [MeetingRecord] {
        meetings.sorted { lhs, rhs in
            displayDate(for: lhs) < displayDate(for: rhs)
        }
    }

    private var todayMeetings: [MeetingRecord] {
        meetings.filter { meeting in
            Calendar.current.isDate(displayDate(for: meeting), inSameDayAs: Date()) && !isCompleted(meeting)
        }
            .sorted { lhs, rhs in
                displayDate(for: lhs) < displayDate(for: rhs)
            }
    }

    private var completedTodayMeetings: [MeetingRecord] {
        meetings.filter { meeting in
            Calendar.current.isDate(displayDate(for: meeting), inSameDayAs: Date()) && isCompleted(meeting)
        }
        .sorted { lhs, rhs in
            displayDate(for: lhs) > displayDate(for: rhs)
        }
    }

    private var editableMeetings: [MeetingRecord] {
        mode == .today ? todayMeetings : sortedMeetings
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
}

private struct AgendaFeedSection<Content: View>: View {
    let title: String
    let count: Int
    let content: () -> Content

    init(title: String, count: Int, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.count = count
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).commandCenterEyebrow()
                CommandCenterChip(title: "\(count)")
            }
            content()
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
        let titles = meetingGoalTitles(for: meeting)
        guard let first = titles.first else { return "No goals" }
        let remaining = titles.count - 1
        return remaining > 0 ? "\(first) +\(remaining)" : first
    }

    private var timeRange: String {
        let start = (meeting.scheduledStartAt ?? meeting.startedAt).formatted(date: .omitted, time: .shortened)
        guard let end = meeting.scheduledEndAt else { return start }
        return "\(start)\n\(end.formatted(date: .omitted, time: .shortened))"
    }
}

private func meetingGoalTitles(for meeting: MeetingRecord) -> [String] {
    let goals = meeting.meetingGoals.isEmpty ? meeting.meetingGoal.map { [$0] } ?? [] : meeting.meetingGoals
    return goals
        .map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

private struct MeetingArtifactCard: View {
    let meeting: MeetingRecord
    let isSelected: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            CommandCenterPanel {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(meeting.name)
                            .font(CommandCenterTypography.sectionTitle)
                            .foregroundStyle(CommandCenterPalette.text)
                            .lineLimit(2)
                        Spacer()
                        Text(displayDate.formatted(date: .abbreviated, time: .shortened))
                            .commandCenterMono()
                    }

                    HStack(spacing: 8) {
                        CommandCenterChip(title: statusText, tint: statusTint, filled: true)
                        CommandCenterChip(title: durationText)
                        CommandCenterChip(title: meeting.speechLocaleIdentifier, tint: CommandCenterPalette.cyan)
                        CommandCenterChip(title: artifactText, tint: artifactTint)
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? CommandCenterPalette.primary : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var statusText: String {
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

    private var statusTint: Color {
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

    private var durationText: String {
        let interval = (meeting.endedAt ?? Date()).timeIntervalSince(meeting.startedAt)
        let minutes = max(Int(interval) / 60, 0)
        return minutes == 1 ? "1 min" : "\(minutes) min"
    }

    private var displayDate: Date {
        meeting.scheduledStartAt ?? meeting.startedAt
    }

    private var artifactText: String {
        if meeting.summaryURL != nil || meeting.summaryJSONURL != nil {
            return "Summary ready"
        }
        if meeting.transcriptURL != nil || meeting.transcriptJSONURL != nil {
            return "Transcript ready"
        }
        return "Artifacts pending"
    }

    private var artifactTint: Color {
        if meeting.summaryURL != nil || meeting.summaryJSONURL != nil || meeting.transcriptURL != nil || meeting.transcriptJSONURL != nil {
            return CommandCenterPalette.primary
        }
        return CommandCenterPalette.secondaryText
    }
}

struct AgendaEditorView: View {
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
                    Text("Edit attendees, topics, time, and goal for this meeting.")
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
                    goalsEditor

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

    private var goalsEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Goals").commandCenterEyebrow()
            ForEach(draft.goalTexts.indices, id: \.self) { index in
                HStack(spacing: 8) {
                    TextField("Goal", text: $draft.goalTexts[index])
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
                    Button {
                        draft.removeGoal(at: index)
                    } label: {
                        Image(systemName: "trash")
                            .accessibilityLabel("Remove Goal")
                    }
                    .buttonStyle(CommandCenterIconButtonStyle())
                    .disabled(draft.goalTexts.count == 1)
                }
            }
            Button("Add Goal") {
                draft.addGoal()
            }
            .buttonStyle(CommandCenterActionButtonStyle())
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

struct AgendaDraft: Equatable {
    var name = ""
    var attendeesText = ""
    var topicsText = ""
    var scheduledStartAt: Date?
    var scheduledEndAt: Date?
    var goalTexts: [String] = [""]

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
        let goals = meeting.meetingGoals.isEmpty ? meeting.meetingGoal.map { [$0] } ?? [] : meeting.meetingGoals
        goalTexts = goals.map(\.title)
        ensureGoalRow()
    }

    func update() -> MeetingAgendaUpdate {
        let goalValues = goalTexts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map {
                MeetingGoal(
                    title: $0,
                    objectives: [],
                    requiredQuestions: [],
                    expectedDecisions: [],
                    keyTerms: []
                )
            }
        return MeetingAgendaUpdate(
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
            meetingGoal: goalValues.first,
            meetingGoals: goalValues
        )
    }

    mutating func addGoal() {
        goalTexts.append("")
    }

    mutating func removeGoal(at index: Int) {
        guard goalTexts.indices.contains(index) else { return }
        goalTexts.remove(at: index)
        ensureGoalRow()
    }

    private mutating func ensureGoalRow() {
        if goalTexts.isEmpty {
            goalTexts = [""]
        }
    }
}
