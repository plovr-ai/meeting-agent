import XCTest
@testable import MeetingAgentCore

@MainActor
final class MeetingAgentViewModelTests: XCTestCase {
    func testLoadsMeetingsOnStart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        _ = try store.createMeeting(name: "Google Chrome", startedAt: Date(timeIntervalSince1970: 100))

        let viewModel = MeetingAgentViewModel(store: store)
        try viewModel.loadMeetings()

        XCTAssertEqual(viewModel.meetings.map(\.name), ["Google Chrome"])
    }

    func testCandidateCanBeAcceptedAndRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let viewModel = MeetingAgentViewModel(store: store)
        let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")

        viewModel.setPendingCandidate(target)
        XCTAssertEqual(viewModel.pendingCandidate?.processID, 10)

        try viewModel.acceptPendingCandidate(startedAt: Date(timeIntervalSince1970: 100))
        XCTAssertNil(viewModel.pendingCandidate)
        XCTAssertEqual(viewModel.meetings.first?.name, "zoom.us")
    }

    func testPendingCandidateCanBeRejectedAndIgnored() throws {
        let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
        let viewModel = MeetingAgentViewModel(processTargetsProvider: { [target] })

        viewModel.setPendingCandidate(target)
        viewModel.rejectPendingCandidate()
        XCTAssertNil(viewModel.pendingCandidate)
        XCTAssertEqual(viewModel.statusText, "Idle")

        viewModel.setPendingCandidate(target)
        viewModel.ignorePendingCandidate()
        XCTAssertNil(viewModel.pendingCandidate)
        XCTAssertNil(viewModel.pollForMeetingCandidates())
    }

    func testAcceptPendingCandidateWithoutCandidateIsNoop() throws {
        let viewModel = MeetingAgentViewModel(processTargetsProvider: { [] })

        try viewModel.acceptPendingCandidate()

        XCTAssertTrue(viewModel.meetings.isEmpty)
        XCTAssertEqual(viewModel.statusText, "Idle")
    }

    func testStopRecordingUpdatesSelectedMeetingAndReturnsToIdle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let viewModel = MeetingAgentViewModel(store: store)
        let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")

        viewModel.setPendingCandidate(target)
        try viewModel.acceptPendingCandidate(startedAt: Date(timeIntervalSince1970: 100))

        viewModel.stopRecording(at: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(viewModel.meetings.first?.endedAt, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(viewModel.statusText, "Idle")
        XCTAssertFalse(viewModel.isRecording)
    }

    func testStopRecordingAndGenerateSummaryWritesArtifacts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let viewModel = MeetingAgentViewModel(store: store, speechLocaleIdentifier: "en-US")
        let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")

        viewModel.setPendingCandidate(target)
        try viewModel.acceptPendingCandidate(startedAt: Date(timeIntervalSince1970: 100))
        let record = try XCTUnwrap(viewModel.meetings.first)
        let transcriptWriter = try TranscriptFileWriter(url: XCTUnwrap(record.transcriptURL))
        try transcriptWriter.replace(with: [
            TranscriptSegment(id: "segment-1", text: "We decided to launch on May 1.", language: "en-US"),
            TranscriptSegment(id: "segment-2", text: "Alex will follow up with legal.", language: "en-US")
        ])
        try transcriptWriter.close()

        try await viewModel.stopRecordingAndGenerateSummary(
            at: Date(timeIntervalSince1970: 200),
            generatedAt: Date(timeIntervalSince1970: 300)
        )

        let stopped = try XCTUnwrap(viewModel.meetings.first)
        let summary = try MeetingSummaryWriter.read(from: XCTUnwrap(stopped.summaryJSONURL))
        XCTAssertEqual(stopped.endedAt, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(summary.status, .succeeded)
        XCTAssertEqual(summary.decisions.first?.sourceSegmentIDs, ["segment-1"])
        XCTAssertEqual(summary.actionItems.first?.sourceSegmentIDs, ["segment-2"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(stopped.summaryMarkdownURL).path))
        XCTAssertEqual(viewModel.statusText, "Summary generated")
        XCTAssertFalse(viewModel.isRecording)
    }

    func testStartRecordingForPendingCandidateUsesConfiguredLocaleAndRecordingState() async throws {
        let fixture = try ViewModelRecorderFixture()
        let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
        let viewModel = MeetingAgentViewModel(
            store: fixture.store,
            recorder: fixture.recorder,
            speechConfiguration: SpeechTranscriptionConfiguration(
                provider: .local,
                localeIdentifier: "en-US",
                whisperBinaryPath: nil,
                whisperModelPath: nil
            ),
            processTargetsProvider: { [target] }
        )

        viewModel.setPendingCandidate(target)
        try await viewModel.startRecordingForPendingCandidate(localeIdentifier: " zh-CN ")

        XCTAssertNil(viewModel.pendingCandidate)
        XCTAssertTrue(viewModel.isRecording)
        XCTAssertEqual(viewModel.statusText, "Recording zoom.us")
        XCTAssertEqual(viewModel.meetings.first?.name, "zoom.us")
        XCTAssertEqual(fixture.session.startedTargets, [target])
        XCTAssertEqual(fixture.transcriberFactory.requests.first?.localeIdentifier, "zh-CN")
    }

    func testStartRecordingForPendingCandidateWithoutCandidateIsNoop() async throws {
        let fixture = try ViewModelRecorderFixture()
        let viewModel = MeetingAgentViewModel(
            store: fixture.store,
            recorder: fixture.recorder,
            processTargetsProvider: { [] }
        )

        try await viewModel.startRecordingForPendingCandidate()

        XCTAssertTrue(viewModel.meetings.isEmpty)
        XCTAssertTrue(fixture.session.startedTargets.isEmpty)
        XCTAssertEqual(viewModel.statusText, "Idle")
    }

    func testStartRecordingCleansUpWhenRecorderStartFails() async throws {
        let fixture = try ViewModelRecorderFixture()
        fixture.session.startError = ProbeError.coreAudio("capture denied")
        let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
        let viewModel = MeetingAgentViewModel(
            store: fixture.store,
            recorder: fixture.recorder,
            processTargetsProvider: { [target] }
        )

        await XCTAssertThrowsErrorAsync(
            try await viewModel.startRecording(for: target)
        ) { error in
            XCTAssertEqual(String(describing: error), "Core Audio error: capture denied")
        }

        XCTAssertFalse(viewModel.isRecording)
        XCTAssertNil(viewModel.pendingCandidate)
        XCTAssertEqual(fixture.session.stopCallCount, 0)
    }

    func testSetRecordingStartErrorUpdatesStatus() {
        let viewModel = MeetingAgentViewModel(processTargetsProvider: { [] })

        viewModel.setRecordingStartError(ProbeError.coreAudio("permission denied"))

        XCTAssertEqual(viewModel.statusText, "Recording failed: Core Audio error: permission denied")
    }

    func testDrainRecordingFramesRefreshesLiveCaptureStatuses() async throws {
        let framesAndStatuses: [(AudioFrame?, String)] = [
            (nil, "Recording zoom.us, but no audio detected"),
            (AudioFrame(pcm: Data([0x00, 0x7f, 0x00, 0x7f]), sampleRate: 16_000, channelCount: 1, timestampNanos: 1), "Recording zoom.us"),
            (AudioFrame(pcm: Data([0, 0, 0, 0]), sampleRate: 16_000, channelCount: 1, timestampNanos: 1), "Recording silent audio from zoom.us")
        ]
        for (frame, expectedText) in framesAndStatuses {
            let fixture = try ViewModelRecorderFixture()
            let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
            let viewModel = MeetingAgentViewModel(
                store: fixture.store,
                recorder: fixture.recorder,
                processTargetsProvider: { [target] }
            )
            try await viewModel.startRecording(for: target)
            if let frame {
                fixture.session.frameBuffer.push(frame)
            }

            viewModel.drainRecordingFrames()

            XCTAssertEqual(viewModel.statusText, expectedText)
        }
    }

    func testStopRecordingAndGenerateSummaryReturnsIdleWhenRecorderHasNoStoppedRecord() async throws {
        let viewModel = MeetingAgentViewModel(processTargetsProvider: { [] })

        try await viewModel.stopRecordingAndGenerateSummary()

        XCTAssertEqual(viewModel.statusText, "Idle")
    }

    func testDrainRecordingFramesStopsWhenTargetProcessEnds() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let targets: [AudioCaptureTarget] = []
        let endedAt = Date(timeIntervalSince1970: 200)
        let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
        let viewModel = MeetingAgentViewModel(
            store: store,
            processTargetsProvider: { targets }
        )

        viewModel.setPendingCandidate(target)
        try viewModel.acceptPendingCandidate(startedAt: Date(timeIntervalSince1970: 100))

        viewModel.drainRecordingFrames(endedAt: endedAt)

        XCTAssertEqual(viewModel.meetings.first?.endedAt, endedAt)
        XCTAssertEqual(viewModel.statusText, "Target process ended: zoom.us")
        XCTAssertFalse(viewModel.isRecording)

        let data = try Data(contentsOf: XCTUnwrap(viewModel.meetings.first?.diagnosticsURL))
        let diagnostics = try JSONDecoder.meetingAgent.decode(CaptureDiagnostics.self, from: data)
        XCTAssertEqual(diagnostics.endedReason, .targetProcessEnded)
        XCTAssertEqual(diagnostics.status, .targetProcessEnded)
    }

    func testSpeechLocaleCanBeConfiguredForAppRecording() {
        let viewModel = MeetingAgentViewModel(
            speechConfiguration: SpeechTranscriptionConfiguration(
                provider: .whisper,
                localeIdentifier: "zh-CN",
                whisperBinaryPath: nil,
                whisperModelPath: nil
            )
        )

        XCTAssertEqual(viewModel.speechLocaleIdentifier, "zh-CN")
        XCTAssertEqual(viewModel.speechProvider, .whisper)

        viewModel.updateSpeechLocaleIdentifier(" ja-JP ")

        XCTAssertEqual(viewModel.speechLocaleIdentifier, "ja-JP")
    }

    func testSpeechConfigurationCanBeUpdatedForAppRecording() {
        let suiteName = "meeting-vm-settings-\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let viewModel = MeetingAgentViewModel(
            speechConfiguration: SpeechTranscriptionConfiguration(
                provider: .whisper,
                localeIdentifier: "en-US",
                whisperBinaryPath: nil,
                whisperModelPath: nil
            ),
            speechConfigurationStore: SpeechTranscriptionConfigurationStore(userDefaults: userDefaults)
        )

        viewModel.updateSpeechProvider(.local)
        viewModel.updateSpeechLocaleIdentifier(" zh-CN ")
        viewModel.updateWhisperBinaryPath(" /opt/homebrew/bin/whisper-cli ")
        viewModel.updateWhisperModelPath(" /Users/allan/models/ggml-small.bin ")

        XCTAssertEqual(viewModel.speechConfiguration.provider, .local)
        XCTAssertEqual(viewModel.speechConfiguration.localeIdentifier, "zh-CN")
        XCTAssertEqual(viewModel.speechConfiguration.whisperBinaryPath, "/opt/homebrew/bin/whisper-cli")
        XCTAssertEqual(viewModel.speechConfiguration.whisperModelPath, "/Users/allan/models/ggml-small.bin")
    }

    func testExplicitSpeechInitializerArgumentsOverridePersistedSettings() throws {
        let suiteName = "meeting-vm-settings-\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let configurationStore = SpeechTranscriptionConfigurationStore(userDefaults: userDefaults)
        try configurationStore.save(SpeechTranscriptionConfiguration(
            provider: .local,
            localeIdentifier: "ja-JP",
            whisperBinaryPath: nil,
            whisperModelPath: nil
        ))

        let viewModel = MeetingAgentViewModel(
            speechLocaleIdentifier: "zh-CN",
            speechProvider: .whisper,
            speechConfigurationStore: configurationStore
        )

        XCTAssertEqual(viewModel.speechProvider, .whisper)
        XCTAssertEqual(viewModel.speechLocaleIdentifier, "zh-CN")
    }

    func testExportsSelectedMeetingTranscriptAndUpdatesStatus() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let stored = try store.createMeeting(name: "Google Meet", startedAt: Date(timeIntervalSince1970: 100))
        try "Transcript text".write(to: XCTUnwrap(stored.record.transcriptURL), atomically: true, encoding: .utf8)
        let viewModel = MeetingAgentViewModel(store: store)
        try viewModel.loadMeetings()
        let destination = root.appendingPathComponent("exported-transcript.txt")

        try viewModel.exportTranscript(for: stored.record.id, to: destination)

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "Transcript text")
        XCTAssertEqual(viewModel.statusText, "Transcript exported")
    }

    func testExportHelpersWriteSummaryDataAndReadinessReports() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let stored = try store.createMeeting(name: "Google Meet", startedAt: Date(timeIntervalSince1970: 100))
        let summary = MeetingSummary(
            overview: "Overview",
            keyTopics: [],
            decisions: [],
            actionItems: [],
            openQuestions: [],
            risks: [],
            followUps: [],
            language: "en-US",
            sourceSegmentIDs: [],
            generatedAt: Date(timeIntervalSince1970: 200),
            provider: "test",
            status: .succeeded,
            failureReason: nil
        )
        try MeetingSummaryWriter.write(summary, jsonURL: stored.record.summaryJSONURL!, markdownURL: stored.record.summaryMarkdownURL!)
        let viewModel = MeetingAgentViewModel(store: store, processTargetsProvider: { [] })
        try viewModel.loadMeetings()

        let summaryDestination = root.appendingPathComponent("summary.md")
        let dataDestination = root.appendingPathComponent("meeting.json")
        let readinessDestination = root.appendingPathComponent("readiness.json")
        try viewModel.exportSummary(for: stored.record.id, to: summaryDestination)
        XCTAssertEqual(viewModel.statusText, "Summary exported")
        try viewModel.exportMeetingData(for: stored.record.id, to: dataDestination)
        XCTAssertEqual(viewModel.statusText, "Meeting data exported")
        try viewModel.exportReadinessReport(for: stored.record.id, to: readinessDestination)
        XCTAssertEqual(viewModel.statusText, "Readiness report exported")
        XCTAssertTrue(FileManager.default.fileExists(atPath: summaryDestination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dataDestination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: readinessDestination.path))
    }

    func testExportAndClipboardReportMissingMeetingAndSuccess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let stored = try store.createMeeting(name: "Google Meet", startedAt: Date(timeIntervalSince1970: 100))
        let summary = MeetingSummary(
            overview: "Overview",
            keyTopics: [],
            decisions: [],
            actionItems: [],
            openQuestions: [],
            risks: [],
            followUps: [],
            language: "en-US",
            sourceSegmentIDs: [],
            generatedAt: Date(timeIntervalSince1970: 200),
            provider: "test",
            status: .succeeded,
            failureReason: nil
        )
        try MeetingSummaryWriter.write(summary, jsonURL: stored.record.summaryJSONURL!, markdownURL: stored.record.summaryMarkdownURL!)
        let viewModel = MeetingAgentViewModel(store: store, processTargetsProvider: { [] })
        try viewModel.loadMeetings()

        XCTAssertThrowsError(try viewModel.exportTranscript(for: UUID(), to: root.appendingPathComponent("missing.txt")))
        XCTAssertEqual(viewModel.statusText, "Transcript export failed: Missing meeting artifact")
        XCTAssertThrowsError(try viewModel.summaryTextForClipboard(for: UUID()))
        XCTAssertEqual(viewModel.statusText, "Copy summary failed: Missing meeting artifact")

        let clipboardText = try viewModel.summaryTextForClipboard(for: stored.record.id)
        XCTAssertTrue(clipboardText.contains("Overview"))
        XCTAssertEqual(viewModel.statusText, "Summary copied")
    }

    func testSummaryClipboardTextFailsWithClearStatusWhenSummaryMissing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let stored = try store.createMeeting(name: "Google Meet", startedAt: Date(timeIntervalSince1970: 100))
        let viewModel = MeetingAgentViewModel(store: store)
        try viewModel.loadMeetings()

        XCTAssertThrowsError(try viewModel.summaryTextForClipboard(for: stored.record.id))
        XCTAssertEqual(viewModel.statusText, "Copy summary failed: Missing summary artifact")
    }

    func testGenerateSummaryWritesArtifacts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        var stored = try store.createMeeting(
            id: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
            name: "Launch Review",
            startedAt: Date(timeIntervalSince1970: 1_777_000_000)
        )
        stored.record.endedAt = Date(timeIntervalSince1970: 1_777_000_600)
        try store.save(stored.record)
        let transcriptWriter = try TranscriptFileWriter(url: stored.record.transcriptURL!)
        try transcriptWriter.replace(with: [
            TranscriptSegment(id: "segment-1", text: "We decided to launch on May 1.", language: "en-US"),
            TranscriptSegment(id: "segment-2", text: "Alex will follow up with legal.", language: "en-US")
        ])
        try transcriptWriter.close()
        let viewModel = MeetingAgentViewModel(store: store, speechLocaleIdentifier: "en-US")
        try viewModel.loadMeetings()

        try await viewModel.generateSummary(
            for: stored.record.id,
            generatedAt: Date(timeIntervalSince1970: 1_777_000_700)
        )

        let summary = try MeetingSummaryWriter.read(from: stored.record.summaryJSONURL!)
        XCTAssertEqual(summary.status, .succeeded)
        XCTAssertEqual(summary.decisions.first?.sourceSegmentIDs, ["segment-1"])
        XCTAssertEqual(summary.actionItems.first?.sourceSegmentIDs, ["segment-2"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: stored.record.summaryMarkdownURL!.path))
        XCTAssertEqual(viewModel.statusText, "Summary generated")
    }

    func testRetryTranscriptionClearsDownstreamSummaryArtifacts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let record = try store.createMeeting(name: "Demo", startedAt: Date()).record
        let transcriptWriter = try TranscriptFileWriter(url: XCTUnwrap(record.transcriptURL))
        try transcriptWriter.replace(with: [
            TranscriptSegment(text: "old", language: "en-US", sourceProvider: "test")
        ])
        try transcriptWriter.close()
        try MeetingSummaryWriter.write(MeetingSummary(
            overview: "old summary",
            keyTopics: [],
            decisions: [],
            actionItems: [],
            openQuestions: [],
            risks: [],
            followUps: [],
            language: "en-US",
            sourceSegmentIDs: [],
            generatedAt: Date(),
            provider: "test",
            status: .succeeded,
            failureReason: nil
        ), jsonURL: XCTUnwrap(record.summaryJSONURL), markdownURL: XCTUnwrap(record.summaryMarkdownURL))

        let viewModel = MeetingAgentViewModel(store: store, processTargetsProvider: { [] })
        try viewModel.loadMeetings()

        await viewModel.invalidateDownstreamArtifactsAfterTranscriptChange(for: record.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(record.summaryJSONURL).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(record.summaryMarkdownURL).path))
        XCTAssertEqual(viewModel.statusText, "Transcript updated; summary needs regeneration")
    }

    func testGenerateSummaryReportsMissingInputsAndFailedSummaryStatus() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let stored = try store.createMeeting(name: "Empty Review", startedAt: Date(timeIntervalSince1970: 100))
        let transcriptWriter = try TranscriptFileWriter(url: stored.record.transcriptURL!)
        try transcriptWriter.replace(with: [TranscriptSegment(id: "blank", text: "   ")])
        try transcriptWriter.close()
        let viewModel = MeetingAgentViewModel(store: store, speechLocaleIdentifier: "en-US", processTargetsProvider: { [] })
        try viewModel.loadMeetings()

        await XCTAssertThrowsErrorAsync(try await viewModel.generateSummary(for: UUID())) { error in
            XCTAssertEqual(String(describing: error), "Invalid arguments: Meeting not found")
        }

        try await viewModel.generateSummary(for: stored.record.id)
        XCTAssertEqual(viewModel.statusText, "Summary failed")
    }

    func testGenerateSummaryReportsMissingStructuredTranscriptURL() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        var stored = try store.createMeeting(name: "Legacy Meeting", startedAt: Date(timeIntervalSince1970: 100)).record
        stored.transcriptJSONURL = nil
        try store.save(stored)
        let viewModel = MeetingAgentViewModel(store: store, processTargetsProvider: { [] })
        try viewModel.loadMeetings()

        await XCTAssertThrowsErrorAsync(try await viewModel.generateSummary(for: stored.id)) { error in
            XCTAssertEqual(String(describing: error), "Invalid arguments: Meeting has no structured transcript URL")
        }
    }

    func testGenerateSummaryBackfillsLegacySummaryOutputURLs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        var stored = try store.createMeeting(name: "Legacy Meeting", startedAt: Date(timeIntervalSince1970: 100)).record
        stored.summaryJSONURL = nil
        try store.save(stored)
        let transcriptWriter = try TranscriptFileWriter(url: stored.transcriptURL!, structuredURL: stored.transcriptJSONURL!)
        try transcriptWriter.replace(with: [
            TranscriptSegment(id: "segment-1", text: "We decided to launch.", language: "en-US")
        ])
        try transcriptWriter.close()
        let viewModel = MeetingAgentViewModel(store: store, processTargetsProvider: { [] })
        try viewModel.loadMeetings()

        try await viewModel.generateSummary(for: stored.id)

        XCTAssertNotNil(viewModel.meetings.first?.summaryJSONURL)
        XCTAssertEqual(viewModel.statusText, "Summary generated")
    }

    func testSaveSpeechConfigurationPersistsBilingualSettings() throws {
        let suiteName = "meeting-vm-settings-save-\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let configurationStore = SpeechTranscriptionConfigurationStore(userDefaults: userDefaults)
        let viewModel = MeetingAgentViewModel(
            speechConfigurationStore: configurationStore,
            processTargetsProvider: { [] }
        )

        let configuration = SpeechTranscriptionConfiguration(
            provider: .local,
            localeIdentifier: "ja-JP",
            targetLocaleIdentifier: "zh-CN",
            bilingualPipelineProfileID: "local-whisper-local-translation",
            whisperBinaryPath: "/opt/homebrew/bin/whisper-cli",
            whisperModelPath: "/Users/allan/models/ggml-medium.bin",
            transcriptionExecutionMode: .hosted,
            translationExecutionMode: .hosted,
            localTranscriptionProviderID: "macos-speech-local",
            localTranslationProviderID: "nllb-local",
            hostedTranscriptionProviderID: "openrouter-transcribe",
            hostedTranslationProviderID: "openrouter-translation",
            hostedTranscriptionModelID: "google/gemini-2.5-flash",
            hostedTranslationModelID: "openai/gpt-4.1-mini",
            openRouterAPIKey: "settings-key",
            openAIRealtimeAPIKey: "realtime-settings-key"
        )

        viewModel.saveSpeechConfiguration(configuration)

        var expectedConfiguration = configuration
        expectedConfiguration.bilingualPipelineProfileID = "hosted-transcribe-hosted-translation"
        XCTAssertEqual(viewModel.speechConfiguration, expectedConfiguration)
        var expectedPersistedConfiguration = expectedConfiguration
        expectedPersistedConfiguration.openRouterAPIKey = nil
        expectedPersistedConfiguration.openAIRealtimeAPIKey = nil
        expectedPersistedConfiguration.deepgramAPIKey = nil
        XCTAssertEqual(try configurationStore.load(), expectedPersistedConfiguration)
        XCTAssertEqual(viewModel.statusText, "Settings saved")
    }

    func testSaveSpeechConfigurationDerivesPipelineProfileFromStepModes() throws {
        let suiteName = "meeting-vm-derived-profile-\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let configurationStore = SpeechTranscriptionConfigurationStore(userDefaults: userDefaults)
        let viewModel = MeetingAgentViewModel(
            speechConfigurationStore: configurationStore,
            processTargetsProvider: { [] }
        )
        let staleProfileConfiguration = SpeechTranscriptionConfiguration(
            provider: .whisper,
            localeIdentifier: "en-US",
            targetLocaleIdentifier: "zh-CN",
            bilingualPipelineProfileID: "local-whisper-local-translation",
            whisperBinaryPath: nil,
            whisperModelPath: nil,
            transcriptionExecutionMode: .hosted,
            translationExecutionMode: .hosted
        )

        viewModel.saveSpeechConfiguration(staleProfileConfiguration)

        XCTAssertEqual(viewModel.speechConfiguration.bilingualPipelineProfileID, "hosted-transcribe-hosted-translation")
        XCTAssertEqual(try configurationStore.load().bilingualPipelineProfileID, "hosted-transcribe-hosted-translation")
    }

    func testSaveSpeechConfigurationDerivesLocalAndMixedProfilesAndValidationStatus() throws {
        let suiteName = "meeting-vm-derived-profile-more-\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let configurationStore = SpeechTranscriptionConfigurationStore(userDefaults: userDefaults)
        let viewModel = MeetingAgentViewModel(
            speechConfigurationStore: configurationStore,
            processTargetsProvider: { [] }
        )

        viewModel.saveSpeechConfiguration(SpeechTranscriptionConfiguration(
            provider: .local,
            localeIdentifier: " ",
            targetLocaleIdentifier: "zh-CN",
            bilingualPipelineProfileID: "stale",
            whisperBinaryPath: nil,
            whisperModelPath: nil,
            transcriptionExecutionMode: .local,
            translationExecutionMode: .local
        ))
        XCTAssertEqual(viewModel.speechConfiguration.bilingualPipelineProfileID, "local-whisper-local-translation")
        XCTAssertEqual(viewModel.speechConfigurationStatus, .available)

        viewModel.saveSpeechConfiguration(SpeechTranscriptionConfiguration(
            provider: .local,
            localeIdentifier: "en-US",
            targetLocaleIdentifier: "zh-CN",
            bilingualPipelineProfileID: "stale",
            whisperBinaryPath: nil,
            whisperModelPath: nil,
            transcriptionExecutionMode: .local,
            translationExecutionMode: .hosted
        ))
        XCTAssertEqual(viewModel.speechConfiguration.bilingualPipelineProfileID, "local-whisper-hosted-translation")
    }

    func testSupportedLocaleIdentifiersIncludeInitialSettingsChoices() {
        XCTAssertEqual(MeetingAgentViewModel.supportedLocaleIdentifiers, [
            "en-US",
            "zh-CN",
            "zh-TW",
            "ja-JP",
            "ko-KR",
            "fr-FR",
            "de-DE",
            "es-ES"
        ])
    }

    func testStartRealtimeTranslationRequiresRecording() async {
        let viewModel = MeetingAgentViewModel()

        await viewModel.startRealtimeTranslation(targetLocale: "zh-CN")

        XCTAssertEqual(viewModel.realtimeTranslationStatus, .failed("Start recording before live translation"))
    }

    func testStartRealtimeTranslationUsesConfiguredRealtimeAPIKey() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let provider = ViewModelFakeRealtimeProvider()
        let controller = RealtimeTranslationController(provider: provider)
        let viewModel = MeetingAgentViewModel(
            store: store,
            speechConfiguration: SpeechTranscriptionConfiguration(
                provider: .whisper,
                localeIdentifier: "en-US",
                whisperBinaryPath: nil,
                whisperModelPath: nil,
                openAIRealtimeAPIKey: " settings-realtime-key "
            ),
            realtimeTranslationController: controller
        )
        let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
        viewModel.setPendingCandidate(target)
        try viewModel.acceptPendingCandidate(startedAt: Date(timeIntervalSince1970: 100))

        await viewModel.startRealtimeTranslation(targetLocale: "ja-JP")

        XCTAssertEqual(provider.startedConfigurations.first?.apiKey, "settings-realtime-key")
        XCTAssertEqual(provider.startedConfigurations.first?.targetLocale, "ja-JP")
    }

    func testStartRealtimeTranslationCanUseEnvironmentAPIKeyFallback() async throws {
        let fixture = try ViewModelRecorderFixture()
        let provider = ViewModelFakeRealtimeProvider()
        let controller = RealtimeTranslationController(provider: provider)
        let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
        let viewModel = MeetingAgentViewModel(
            store: fixture.store,
            recorder: fixture.recorder,
            speechConfiguration: SpeechTranscriptionConfiguration(
                provider: .local,
                localeIdentifier: "en-US",
                whisperBinaryPath: nil,
                whisperModelPath: nil,
                openAIRealtimeAPIKey: nil
            ),
            realtimeTranslationController: controller,
            processTargetsProvider: { [target] }
        )
        try await viewModel.startRecording(for: target)

        await viewModel.startRealtimeTranslation(targetLocale: "fr-FR")

        XCTAssertNil(provider.startedConfigurations.first?.apiKey)
        XCTAssertEqual(provider.startedConfigurations.first?.targetLocale, "fr-FR")
    }

    func testStopRealtimeTranslationResetsState() async {
        let controller = RealtimeTranslationController(provider: ViewModelFakeRealtimeProvider())
        let viewModel = MeetingAgentViewModel(realtimeTranslationController: controller)

        await viewModel.stopRealtimeTranslation()

        XCTAssertEqual(viewModel.realtimeTranslationStatus, .idle)
    }

    func testPollForMeetingCandidatesDetectsOnlyNewNonRecordingTargets() throws {
        let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
        let viewModel = MeetingAgentViewModel(processTargetsProvider: { [target] })

        XCTAssertEqual(viewModel.pollForMeetingCandidates(), target)
        XCTAssertEqual(viewModel.pendingCandidate, target)
        XCTAssertNil(viewModel.pollForMeetingCandidates())
    }

    func testRetryTranscriptionMarksMeetingFailedWhenSavedAudioIsMissing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        var stored = try store.createMeeting(name: "Google Meet", startedAt: Date(timeIntervalSince1970: 100)).record
        stored.audioURL = nil
        try store.save(stored)
        let viewModel = MeetingAgentViewModel(store: store, processTargetsProvider: { [] })
        try viewModel.loadMeetings()

        await viewModel.retryTranscription(for: stored.id)

        XCTAssertEqual(viewModel.meetings.first?.transcriptionStatus, .failed)
        XCTAssertEqual(
            viewModel.meetings.first?.transcriptionFailureReason,
            "No saved audio is available for transcription retry"
        )
    }

    func testRetryTranscriptionMarksMeetingFailedWhenProviderCannotRetrySavedAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let stored = try store.createMeeting(name: "Google Meet", startedAt: Date(timeIntervalSince1970: 100)).record
        FileManager.default.createFile(atPath: stored.audioURL!.path, contents: Data([0x52, 0x49, 0x46, 0x46]))
        try "previous transcript".write(to: stored.transcriptURL!, atomically: true, encoding: .utf8)
        let viewModel = MeetingAgentViewModel(
            store: store,
            speechConfiguration: SpeechTranscriptionConfiguration(
                provider: .local,
                localeIdentifier: "en-US",
                whisperBinaryPath: nil,
                whisperModelPath: nil
            ),
            processTargetsProvider: { [] }
        )
        try viewModel.loadMeetings()

        await viewModel.retryTranscription(for: stored.id)

        XCTAssertEqual(viewModel.meetings.first?.transcriptionStatus, .failed)
        XCTAssertEqual(viewModel.statusText, "Transcription failed")
        XCTAssertTrue(viewModel.meetings.first?.transcriptionFailureReason?.contains("does not support retrying") == true)
    }

    func testRetryTranscriptionIgnoresUnknownMeeting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let stored = try store.createMeeting(name: "Google Meet", startedAt: Date(timeIntervalSince1970: 100)).record
        let viewModel = MeetingAgentViewModel(store: store, processTargetsProvider: { [] })
        try viewModel.loadMeetings()

        await viewModel.retryTranscription(for: UUID())

        XCTAssertEqual(viewModel.meetings.first?.id, stored.id)
        XCTAssertEqual(viewModel.meetings.first?.transcriptionStatus, .notStarted)
    }

    func testSelectMeetingUpdatesSelectedMeeting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let first = try store.createMeeting(name: "First", startedAt: Date(timeIntervalSince1970: 1))
        let second = try store.createMeeting(name: "Second", startedAt: Date(timeIntervalSince1970: 2))
        let viewModel = MeetingAgentViewModel(store: store, processTargetsProvider: { [] })
        try viewModel.loadMeetings()

        viewModel.selectMeeting(second.record.id)
        XCTAssertEqual(viewModel.selectedMeeting?.id, second.record.id)
        viewModel.selectMeeting(first.record.id)
        XCTAssertEqual(viewModel.selectedMeeting?.id, first.record.id)
    }
}

private struct ViewModelRecorderFixture {
    let root: URL
    let store: MeetingStore
    let session: ViewModelFakeCaptureSession
    let writer: ViewModelFakeAudioFrameWriter
    let transcriber: ViewModelFakeAudioFrameTranscriber
    let transcriberFactory: ViewModelFakeTranscriberFactory
    let recorder: MeetingRecorder

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-recorder-\(UUID().uuidString)", isDirectory: true)
        let store = MeetingStore(baseDirectory: root)
        let session = ViewModelFakeCaptureSession(sampleRate: 16_000, channelCount: 1)
        let writer = ViewModelFakeAudioFrameWriter()
        let transcriber = ViewModelFakeAudioFrameTranscriber()
        let transcriberFactory = ViewModelFakeTranscriberFactory(transcriber: transcriber)
        self.root = root
        self.store = store
        self.session = session
        self.writer = writer
        self.transcriber = transcriber
        self.transcriberFactory = transcriberFactory
        recorder = MeetingRecorder(
            store: store,
            captureSessionFactory: { session },
            wavWriterFactory: { _, _, _ in writer },
            transcriberFactory: transcriberFactory.startTranscriber
        )
    }
}

private final class ViewModelFakeCaptureSession: AudioCaptureSessionManaging {
    let frameBuffer = AudioFrameRingBuffer(capacity: 8)
    let outputSampleRate: Double
    let outputChannelCount: Int
    var startError: Error?
    var startedTargets: [AudioCaptureTarget] = []
    var stopCallCount = 0

    init(sampleRate: Double, channelCount: Int) {
        outputSampleRate = sampleRate
        outputChannelCount = channelCount
    }

    func start(target: AudioCaptureTarget) throws {
        if let startError {
            throw startError
        }
        startedTargets.append(target)
    }

    func stop() {
        stopCallCount += 1
    }
}

private final class ViewModelFakeAudioFrameWriter: AudioFrameWriting {
    func append(_ frame: AudioFrame) throws {}
    func close() throws {}
}

private final class ViewModelFakeAudioFrameTranscriber: AudioFrameTranscriber {
    func append(_ frame: AudioFrame) throws {}
    func finish() {}
}

private final class ViewModelFakeTranscriberFactory {
    struct Request {
        let localeIdentifier: String
    }

    var requests: [Request] = []
    private let transcriber: ViewModelFakeAudioFrameTranscriber

    init(transcriber: ViewModelFakeAudioFrameTranscriber) {
        self.transcriber = transcriber
    }

    func startTranscriber(
        configuration: SpeechTranscriptionConfiguration,
        transcriptURL: URL,
        sampleRate: Double,
        channelCount: Int
    ) async throws -> AudioFrameTranscriber {
        requests.append(Request(localeIdentifier: configuration.localeIdentifier))
        return transcriber
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> some Any,
    _ verify: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error to be thrown", file: file, line: line)
    } catch {
        verify(error)
    }
}

private final class ViewModelFakeRealtimeProvider: RealtimeSpeechTranslationProvider {
    private(set) var startedConfigurations: [RealtimeTranslationConfiguration] = []

    let descriptor = ProviderDescriptor(
        id: "fake-view-model-realtime",
        displayName: "Fake View Model Realtime",
        capability: .speechTranslation,
        executionMode: .hosted,
        supportedSourceLocales: ["*"],
        supportedTargetLocales: ["*"],
        requiresNetwork: false,
        requiresAPIKey: false
    )

    func start(configuration: RealtimeTranslationConfiguration) async throws -> RealtimeTranslationSession {
        startedConfigurations.append(configuration)
        return ViewModelFakeRealtimeSession()
    }
}

private final class ViewModelFakeRealtimeSession: RealtimeTranslationSession {
    var events: AsyncStream<RealtimeTranslationEvent> {
        AsyncStream { _ in }
    }

    func append(_ frames: [AudioFrame]) async throws {}

    func stop() async {}
}

final class AppRuntimeCapabilitiesTests: XCTestCase {
    func testUserNotificationsRequireAppBundleRuntime() {
        XCTAssertTrue(AppRuntimeCapabilities.supportsUserNotifications(bundleURL: URL(fileURLWithPath: "/Applications/MeetingAgent.app")))
        XCTAssertFalse(AppRuntimeCapabilities.supportsUserNotifications(bundleURL: URL(fileURLWithPath: "/tmp/meeting-agent/.build/debug")))
    }
}
