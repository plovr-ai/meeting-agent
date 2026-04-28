# Agenda Single Feed Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the split meeting list/detail agenda with a single feed that shows today's meetings and recent date-grouped history with visible metadata.

**Architecture:** Keep `MeetingAgentViewModel` unchanged. Replace the `NavigationSplitView` shell in `MainWindowView` with a command-center shell that routes between agenda, meeting detail, and settings. Add focused SwiftUI views in `MainWindowView.swift` for the agenda feed, date grouping, and meeting cards.

**Tech Stack:** Swift 5.9, SwiftUI, macOS 14.2, XCTest source-layout tests, existing command-center styling helpers.

---

## File Structure

- Modify `Sources/MeetingAgentApp/MainWindowView.swift`: remove `NavigationSplitView`, add `MainWindowDestination`, `AgendaShellView`, `AgendaFeedView`, `AgendaMeetingCard`, and date grouping helpers.
- Modify `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`: replace split-view/sidebar assertions with agenda-feed assertions while preserving existing detail/control checks.

### Task 1: Source-Layout Regression Tests

**Files:**
- Modify: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

- [ ] **Step 1: Replace sidebar split-view tests with agenda tests**

Update the tests that currently assert the split sidebar:

```swift
func testMainWindowUsesAgendaFeedInsteadOfNavigationSplitView() throws {
    let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/MeetingAgentApp/MainWindowView.swift")
    let source = try String(contentsOf: sourceURL)

    XCTAssertFalse(source.contains("NavigationSplitView"))
    XCTAssertTrue(source.contains("AgendaShellView("))
    XCTAssertTrue(source.contains("AgendaFeedView("))
    XCTAssertTrue(source.contains("AgendaMeetingCard("))
}

func testAgendaFeedShowsTodayAndRecentHistoryWithoutStaticYesterdaySection() throws {
    let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/MeetingAgentApp/MainWindowView.swift")
    let source = try String(contentsOf: sourceURL)

    XCTAssertTrue(source.contains("Text(\"Today\")"))
    XCTAssertTrue(source.contains("Text(\"Recent\")"))
    XCTAssertTrue(source.contains("recentHistoryDays = 7"))
    XCTAssertTrue(source.contains("recentHistoryStart"))
    XCTAssertFalse(source.contains("Text(\"Yesterday\")"))
}

func testAgendaCardsExposeMeetingMetadata() throws {
    let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/MeetingAgentApp/MainWindowView.swift")
    let source = try String(contentsOf: sourceURL)

    XCTAssertTrue(source.contains("statusText(for: meeting)"))
    XCTAssertTrue(source.contains("durationText(for: meeting)"))
    XCTAssertTrue(source.contains("artifactText(for: meeting)"))
    XCTAssertTrue(source.contains("meeting.speechLocaleIdentifier"))
    XCTAssertTrue(source.contains("meeting.startedAt.formatted(date: .abbreviated, time: .shortened)"))
}

func testSettingsEntryRemainsFixedInAgendaShell() throws {
    let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/MeetingAgentApp/MainWindowView.swift")
    let source = try String(contentsOf: sourceURL)

    XCTAssertTrue(source.contains("AgendaShellView("))
    XCTAssertTrue(source.contains("Label(\"Agenda\", systemImage: \"calendar\")"))
    XCTAssertTrue(source.contains("Label(\"Settings\", systemImage: \"gearshape\")"))
    XCTAssertTrue(source.contains("destination = .settings"))
}
```

- [ ] **Step 2: Run focused layout tests and verify failure**

Run:

```bash
swift test --filter MainWindowViewLayoutTests
```

Expected: FAIL because `MainWindowView` still contains `NavigationSplitView` and no agenda feed views.

### Task 2: Agenda Shell and Routing

**Files:**
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift`

- [ ] **Step 1: Add destination state**

Replace `@State private var showSettings = false` with:

```swift
@State private var destination: MainWindowDestination = .agenda
```

Add near the top-level view declarations:

```swift
private enum MainWindowDestination: Equatable {
    case agenda
    case detail
    case settings
}
```

- [ ] **Step 2: Replace `NavigationSplitView` with `AgendaShellView`**

In `MainWindowView.body`, render:

```swift
AgendaShellView(
    destination: $destination,
    selectedMeetingID: viewModel.selectedMeetingID,
    meetings: viewModel.meetings,
    selectMeeting: { id in
        viewModel.selectMeeting(id)
        destination = .detail
    },
    detail: {
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
            copySummary: { meeting in copySummary(for: meeting) },
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
                Task { await viewModel.retryTranscription(for: meeting.id) }
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
    },
    settings: {
        SettingsView(
            configuration: viewModel.speechConfiguration,
            profiles: BilingualPipelineFactory.builtInProfiles,
            localeIdentifiers: MeetingAgentViewModel.supportedLocaleIdentifiers,
            isRecording: viewModel.isRecording,
            status: viewModel.speechConfigurationStatus,
            primaryChainPreflightResult: viewModel.primaryChainPreflightResult,
            save: { viewModel.saveSpeechConfiguration($0) }
        )
    }
)
```

- [ ] **Step 3: Run focused tests and verify shell assertions still fail until shell types exist**

Run:

```bash
swift test --filter MainWindowViewLayoutTests/testMainWindowUsesAgendaFeedInsteadOfNavigationSplitView
```

Expected: FAIL until `AgendaShellView`, `AgendaFeedView`, and `AgendaMeetingCard` are added.

### Task 3: Agenda Feed Views

**Files:**
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift`

- [ ] **Step 1: Add `AgendaShellView`**

Add a private generic shell below `MainWindowView`:

```swift
private struct AgendaShellView<Detail: View, Settings: View>: View {
    @Binding var destination: MainWindowDestination
    let selectedMeetingID: UUID?
    let meetings: [MeetingRecord]
    let selectMeeting: (UUID) -> Void
    @ViewBuilder let detail: () -> Detail
    @ViewBuilder let settings: () -> Settings

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Text("Meeting Agent")
                    .commandCenterEyebrow()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 16)

                Button {
                    destination = .agenda
                } label: {
                    Label("Agenda", systemImage: "calendar")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(destination == .agenda ? CommandCenterPalette.primary : CommandCenterPalette.text)
                .padding(12)
                .background(destination == .agenda ? CommandCenterPalette.primary.opacity(0.12) : Color.clear)

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
            .frame(minWidth: 180, idealWidth: 210, maxWidth: 240)

            Divider()
                .overlay(CommandCenterPalette.border)

            Group {
                switch destination {
                case .agenda:
                    AgendaFeedView(
                        meetings: meetings,
                        selectedMeetingID: selectedMeetingID,
                        selectMeeting: selectMeeting
                    )
                case .detail:
                    detail()
                case .settings:
                    settings()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(CommandCenterPalette.window)
    }
}
```

- [ ] **Step 2: Add `AgendaFeedView` with Today and Recent grouping**

Add:

```swift
private struct AgendaFeedView: View {
    private let recentHistoryDays = 7
    let meetings: [MeetingRecord]
    let selectedMeetingID: UUID?
    let selectMeeting: (UUID) -> Void

    var body: some View {
        CommandCenterScrollView(content: {
            VStack(alignment: .leading, spacing: 22) {
                header
                section(title: "Today", meetings: todayMeetings, prominent: true)
                recentSection
            }
            .padding(28)
        })
        .background(CommandCenterPalette.window)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Agenda").commandCenterTitle()
            Text("Meeting schedule and metadata")
                .commandCenterCaption(CommandCenterPalette.secondaryText)
        }
    }

    private var todayMeetings: [MeetingRecord] {
        sortedMeetings.filter { Calendar.current.isDateInToday($0.startedAt) }
    }

    private var recentGroups: [(Date, [MeetingRecord])] {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let recentHistoryStart = calendar.date(byAdding: .day, value: -recentHistoryDays, to: startOfToday) ?? startOfToday
        let recentMeetings = sortedMeetings.filter { meeting in
            let day = calendar.startOfDay(for: meeting.startedAt)
            return day >= recentHistoryStart && day < startOfToday
        }
        let grouped = Dictionary(grouping: recentMeetings) { meeting in
            calendar.startOfDay(for: meeting.startedAt)
        }
        return grouped.keys.sorted(by: >).map { day in
            (day, grouped[day] ?? [])
        }
    }

    private var sortedMeetings: [MeetingRecord] {
        meetings.sorted { $0.startedAt > $1.startedAt }
    }

    @ViewBuilder
    private var recentSection: some View {
        if !recentGroups.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Recent").commandCenterEyebrow()
                ForEach(recentGroups, id: \.0) { day, meetings in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(day.formatted(date: .abbreviated, time: .omitted))
                            .font(CommandCenterTypography.sectionTitle)
                            .foregroundStyle(CommandCenterPalette.text)
                        ForEach(meetings) { meeting in
                            AgendaMeetingCard(
                                meeting: meeting,
                                isSelected: selectedMeetingID == meeting.id,
                                prominent: false,
                                open: { selectMeeting(meeting.id) }
                            )
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func section(title: String, meetings: [MeetingRecord], prominent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).commandCenterEyebrow()
            if meetings.isEmpty {
                CommandCenterPanel {
                    Text("No meetings scheduled for this section.")
                        .commandCenterCaption(CommandCenterPalette.secondaryText)
                }
            } else {
                ForEach(meetings) { meeting in
                    AgendaMeetingCard(
                        meeting: meeting,
                        isSelected: selectedMeetingID == meeting.id,
                        prominent: prominent,
                        open: { selectMeeting(meeting.id) }
                    )
                }
            }
        }
    }
}
```

- [ ] **Step 3: Add `AgendaMeetingCard` metadata display**

Add:

```swift
private struct AgendaMeetingCard: View {
    let meeting: MeetingRecord
    let isSelected: Bool
    let prominent: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            CommandCenterPanel {
                VStack(alignment: .leading, spacing: prominent ? 12 : 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(meeting.name)
                            .font(prominent ? CommandCenterTypography.title : CommandCenterTypography.sectionTitle)
                            .foregroundStyle(CommandCenterPalette.text)
                            .lineLimit(2)
                        Spacer()
                        Text(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                            .commandCenterMono()
                    }

                    HStack(spacing: 8) {
                        CommandCenterChip(title: statusText(for: meeting), tint: statusTint(for: meeting), filled: true)
                        CommandCenterChip(title: durationText(for: meeting))
                        CommandCenterChip(title: meeting.speechLocaleIdentifier, tint: CommandCenterPalette.cyan)
                        CommandCenterChip(title: artifactText(for: meeting), tint: artifactTint(for: meeting))
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

    private func statusText(for meeting: MeetingRecord) -> String {
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

    private func statusTint(for meeting: MeetingRecord) -> Color {
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

    private func durationText(for meeting: MeetingRecord) -> String {
        let interval = (meeting.endedAt ?? Date()).timeIntervalSince(meeting.startedAt)
        let minutes = max(Int(interval) / 60, 0)
        return minutes == 1 ? "1 min" : "\(minutes) min"
    }

    private func artifactText(for meeting: MeetingRecord) -> String {
        if meeting.summaryURL != nil || meeting.summaryJSONURL != nil {
            return "Summary ready"
        }
        if meeting.transcriptURL != nil || meeting.transcriptJSONURL != nil {
            return "Transcript ready"
        }
        return "Artifacts pending"
    }

    private func artifactTint(for meeting: MeetingRecord) -> Color {
        if meeting.summaryURL != nil || meeting.summaryJSONURL != nil || meeting.transcriptURL != nil || meeting.transcriptJSONURL != nil {
            return CommandCenterPalette.primary
        }
        return CommandCenterPalette.secondaryText
    }
}
```

- [ ] **Step 4: Run focused tests and fix compile/source issues**

Run:

```bash
swift test --filter MainWindowViewLayoutTests
```

Expected: PASS.

### Task 4: Full Verification and Commit

**Files:**
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift`
- Modify: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

- [ ] **Step 1: Build the app**

Run:

```bash
swift build --product MeetingAgentApp
```

Expected: PASS.

- [ ] **Step 2: Run required test entrypoint**

Run:

```bash
make test
```

Expected: PASS with coverage enforcement.

- [ ] **Step 3: Commit implementation**

Run:

```bash
git add Sources/MeetingAgentApp/MainWindowView.swift Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift
git commit -m "feat: add agenda single feed (#39)"
```

Expected: commit created.

## Self-Review

- Spec coverage: covers single feed, Today prominence, recent seven-day date grouping, no static Yesterday, metadata cards, settings, and existing detail workflow preservation.
- Placeholder scan: no `TBD`, `TODO`, or unresolved implementation placeholders.
- Type consistency: plan uses existing `MeetingRecord`, `MeetingAgentViewModel`, `CommandCenterPanel`, `CommandCenterScrollView`, `CommandCenterChip`, and command-center typography/palette helpers.
