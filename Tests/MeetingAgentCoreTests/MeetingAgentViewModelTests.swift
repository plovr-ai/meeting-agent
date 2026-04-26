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
}

final class AppRuntimeCapabilitiesTests: XCTestCase {
    func testUserNotificationsRequireAppBundleRuntime() {
        XCTAssertTrue(AppRuntimeCapabilities.supportsUserNotifications(bundleURL: URL(fileURLWithPath: "/Applications/MeetingAgent.app")))
        XCTAssertFalse(AppRuntimeCapabilities.supportsUserNotifications(bundleURL: URL(fileURLWithPath: "/tmp/meeting-agent/.build/debug")))
    }
}
