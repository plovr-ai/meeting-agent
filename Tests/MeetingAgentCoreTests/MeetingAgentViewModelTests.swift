import Combine
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


    func testStopRecordingAllowsSameRunningTargetToPromptAgain() async throws {
        let fixture = try ViewModelRecorderFixture()
        let target = AudioCaptureTarget(
            processID: 10,
            displayName: "zoom.us",
            bundleIdentifier: "us.zoom.xos",
            isAudioOutputActive: true
        )
        let viewModel = MeetingAgentViewModel(
            store: fixture.store,
            recorder: fixture.recorder,
            processTargetsProvider: { [target] }
        )

        XCTAssertEqual(viewModel.pollForMeetingCandidates(), target)
        try await viewModel.startRecordingForPendingCandidate()

        viewModel.stopRecording(at: Date(timeIntervalSince1970: 200))
        let candidate = viewModel.pollForMeetingCandidates()

        XCTAssertEqual(candidate, target)
        XCTAssertEqual(viewModel.pendingCandidate, target)
        XCTAssertEqual(viewModel.statusText, "Meeting detected: zoom.us")
    }

    func testSecondDetectedMeetingShowsTranscribingAfterFirstMeetingStops() async throws {
        let fixture = try ViewModelRecorderFixture()
        var currentTarget = AudioCaptureTarget(
            processID: 10,
            displayName: "zoom.us",
            bundleIdentifier: "us.zoom.xos",
            isAudioOutputActive: true
        )
        let viewModel = MeetingAgentViewModel(
            store: fixture.store,
            recorder: fixture.recorder,
            processTargetsProvider: { [currentTarget] }
        )

        XCTAssertEqual(viewModel.pollForMeetingCandidates(), currentTarget)
        try await viewModel.startRecordingForPendingCandidate()
        viewModel.stopRecording(at: Date(timeIntervalSince1970: 200))

        currentTarget = AudioCaptureTarget(
            processID: 11,
            displayName: "Google Meet",
            bundleIdentifier: "com.google.Chrome",
            isAudioOutputActive: true
        )
        XCTAssertEqual(viewModel.pollForMeetingCandidates(), currentTarget)
        try await viewModel.startRecordingForPendingCandidate()

        XCTAssertEqual(viewModel.selectedMeeting?.name, "Google Meet")
        XCTAssertEqual(viewModel.selectedMeeting?.transcriptionStatus, .transcribing)
        XCTAssertEqual(fixture.session.startedTargets, [
            AudioCaptureTarget(
                processID: 10,
                displayName: "zoom.us",
                bundleIdentifier: "us.zoom.xos",
                isAudioOutputActive: true
            ),
            currentTarget
        ])
        XCTAssertEqual(fixture.transcriberFactory.requests.count, 2)
    }

    func testStartOfflineMicrophoneRecordingCreatesMeetingWithoutCandidate() async throws {
        let fixture = try ViewModelRecorderFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = MeetingAgentViewModel(
            store: fixture.store,
            recorder: fixture.recorder,
            processTargetsProvider: { [] }
        )

        try await viewModel.startOfflineMicrophoneRecording(startedAt: Date(timeIntervalSince1970: 100))

        XCTAssertNil(viewModel.pendingCandidate)
        XCTAssertEqual(viewModel.selectedMeeting?.name, "New Meeting")
        XCTAssertEqual(viewModel.activeMeetingID, viewModel.selectedMeeting?.id)
        XCTAssertEqual(viewModel.statusText, "Recording New Meeting")
        XCTAssertEqual(fixture.session.startedSources, [.microphone(displayName: "Computer Microphone")])
    }

    func testStartOfflineMicrophoneRecordingUsesConfiguredSpeechLocale() async throws {
        let fixture = try ViewModelRecorderFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = MeetingAgentViewModel(
            store: fixture.store,
            recorder: fixture.recorder,
            speechConfiguration: SpeechTranscriptionConfiguration(
                provider: .whisper,
                localeIdentifier: "zh-CN",
                whisperBinaryPath: nil,
                whisperModelPath: nil
            ),
            processTargetsProvider: { [] }
        )

        try await viewModel.startOfflineMicrophoneRecording(startedAt: Date(timeIntervalSince1970: 100))

        XCTAssertEqual(viewModel.selectedMeeting?.speechLocaleIdentifier, "zh-CN")
        XCTAssertEqual(fixture.transcriberFactory.requests.first?.localeIdentifier, "zh-CN")
    }

    func testSpeakerIdentityResolutionUpdatesLiveCaptionDisplayLabelWithoutChangingSpeakerID() async throws {
        let viewModel = MeetingAgentViewModel()
        let segment = TranscriptSegment(
            id: "segment-1",
            speaker: TranscriptSpeaker(identifier: "deepgram-speaker-2"),
            startTimeSeconds: 0,
            endTimeSeconds: 3,
            text: "hello from the same person",
            language: "en-US",
            isFinal: true
        )
        await viewModel.applyTranscriptAccumulationResultsForTesting([
            TranscriptSegmentAccumulationResult(
                document: TranscriptDocument(segments: [segment]),
                changedSegmentIDs: ["segment-1"],
                plainTextReplacement: nil,
                source: .realtime
            )
        ])

        viewModel.applySpeakerIdentityResolutionForTesting(SpeakerIdentityResolution(
            localSpeaker: TranscriptSpeaker(identifier: "deepgram-speaker-2"),
            profile: SpeakerProfile(
                displayName: "Allan",
                anonymousName: "Speaker 1",
                confirmationStatus: .confirmed,
                embeddings: []
            ),
            decision: .matched,
            confidence: 0.91,
            secondBestConfidence: nil,
            displayLabel: "Allan"
        ))

        XCTAssertEqual(viewModel.liveCaptionTurns.first?.speaker.identifier, "deepgram-speaker-2")
        XCTAssertEqual(viewModel.liveCaptionTurns.first?.speaker.label, "Allan")
    }

    func testProcessEndedPollingDoesNotStopMicrophoneRecording() async throws {
        let fixture = try ViewModelRecorderFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var targets: [AudioCaptureTarget] = []
        let viewModel = MeetingAgentViewModel(
            store: fixture.store,
            recorder: fixture.recorder,
            processTargetsProvider: { targets }
        )

        try await viewModel.startOfflineMicrophoneRecording(startedAt: Date(timeIntervalSince1970: 100))
        fixture.session.frameBuffer.push(AudioFrame(
            pcm: Data([0, 64]),
            sampleRate: 16_000,
            channelCount: 1,
            timestampNanos: 1
        ))
        targets = []
        viewModel.pollActiveRecordingProcess(endedAt: Date(timeIntervalSince1970: 200))

        XCTAssertTrue(viewModel.isRecording)
        try await waitFor { viewModel.statusText == "Recording Computer Microphone" }
        XCTAssertEqual(viewModel.statusText, "Recording Computer Microphone")
    }

    func testStopRecordingGeneratesSummaryFromLiveMemoryTranscript() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let viewModel = MeetingAgentViewModel(
            store: store,
            speechLocaleIdentifier: "en-US",
            summaryProviderFactory: { _ in CapturingSummaryProvider(providerName: "openrouter:openai/gpt-4.1-mini") }
        )
        let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")

        viewModel.setPendingCandidate(target)
        try viewModel.acceptPendingCandidate(startedAt: Date(timeIntervalSince1970: 100))
        let record = try XCTUnwrap(viewModel.meetings.first)
        let liveTranscript = TranscriptDocument(segments: [
            TranscriptSegment(
                id: "segment-1",
                speaker: TranscriptSpeaker(identifier: "speaker-1", label: "User A"),
                text: "We decided to launch on May 1.",
                language: "en-US",
                isFinal: true
            ),
            TranscriptSegment(
                id: "segment-2",
                speaker: TranscriptSpeaker(identifier: "speaker-2", label: "User B"),
                text: "Alex will follow up with legal.",
                language: "en-US",
                isFinal: true
            )
        ])
        await viewModel.applyTranscriptAccumulationResultsForTesting([
            TranscriptSegmentAccumulationResult(
                document: liveTranscript,
                changedSegmentIDs: liveTranscript.segments.map(\.id),
                plainTextReplacement: nil
            )
        ])

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
        let persistedCaptionDocument = try MeetingTranscriptStore.readDocument(from: XCTUnwrap(record.transcriptJSONURL))
        XCTAssertEqual(persistedCaptionDocument.turns.map(\.text), [
            "We decided to launch on May 1.",
            "Alex will follow up with legal."
        ])
        XCTAssertEqual(viewModel.statusText, "Summary generated")
        XCTAssertFalse(viewModel.isRecording)
    }

    func testIdleDrainDoesNotInvalidateWindowWhenSelectedTranscriptAlreadyLoaded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let stored = try store.createMeeting(name: "Recorded Meeting", startedAt: Date(timeIntervalSince1970: 100)).record
        try FileTranscriptRepository().saveCaptionDocument(summaryCaptionDocument([
            TranscriptSegment(id: "segment-1", text: "This meeting has already stopped.", language: "en-US")
        ]), for: stored)
        let viewModel = MeetingAgentViewModel(store: store, processTargetsProvider: { [] })
        try viewModel.loadMeetings()

        viewModel.drainRecordingFrames()
        XCTAssertFalse(viewModel.liveCaptionTurns.isEmpty)

        var invalidationCount = 0
        let cancellable = viewModel.objectWillChange.sink {
            invalidationCount += 1
        }
        viewModel.drainRecordingFrames()
        cancellable.cancel()

        XCTAssertEqual(invalidationCount, 0)
    }

    func testGenerateSummaryIncludesMatchingMeetingProgressSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        var stored = try store.createMeeting(name: "Google Meet", startedAt: Date(timeIntervalSince1970: 100)).record
        let goal = MeetingGoal(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            title: "Confirm launch plan",
            objectives: [MeetingObjective(id: "owner", title: "Confirm launch owner")],
            requiredQuestions: ["Have we confirmed the deadline?"],
            expectedDecisions: [],
            keyTerms: []
        )
        stored.meetingGoal = goal
        try store.save(stored)
        try FileTranscriptRepository().saveCaptionDocument(summaryCaptionDocument([
            TranscriptSegment(id: "segment-1", text: "Alex is the launch owner.", language: "en-US")
        ]), for: stored)
        let progress = MeetingProgressState(
            meetingID: stored.id,
            goal: goal,
            status: .onTrack,
            objectives: [
                MeetingObjectiveProgress(
                    objectiveID: "owner",
                    title: "Confirm launch owner",
                    status: .confirmed,
                    evidenceSegmentIDs: ["segment-1"]
                )
            ],
            confirmedItems: ["Confirm launch owner"],
            unresolvedItems: [],
            suggestedQuestions: [
                FollowUpQuestionSuggestion(
                    chinese: "请确认：Have we confirmed the deadline?",
                    english: "Have we confirmed the deadline?",
                    sourceObjectiveID: nil
                )
            ],
            health: MeetingProgressHealth(caption: .live, translation: .live, analysis: .live),
            lastAnalyzedSegmentID: "segment-1",
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        try JSONEncoder.meetingAgent.encode(progress).write(to: XCTUnwrap(stored.meetingProgressJSONURL), options: .atomic)
        let provider = CapturingSummaryProvider(providerName: "openrouter:openai/gpt-4.1-mini")
        let viewModel = MeetingAgentViewModel(
            store: store,
            speechLocaleIdentifier: "en-US",
            summaryProviderFactory: { _ in provider },
            processTargetsProvider: { [] }
        )
        try viewModel.loadMeetings()

        try await viewModel.generateSummary(for: stored.id, generatedAt: Date(timeIntervalSince1970: 300))

        let summary = try MeetingSummaryWriter.read(from: XCTUnwrap(stored.summaryJSONURL))
        XCTAssertEqual(summary.provider, "openrouter:openai/gpt-4.1-mini")
        let meetingGoal = try XCTUnwrap(provider.receivedInputs.first?.meetingGoal)
        XCTAssertTrue(meetingGoal.contains("Goal: Confirm launch plan"))
        XCTAssertTrue(meetingGoal.contains("Current status: on track"))
        XCTAssertTrue(meetingGoal.contains("- Confirm launch owner"))
        XCTAssertTrue(meetingGoal.contains("- Have we confirmed the deadline?"))
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

    func testStartRecordingExistingMeetingUsesMeetingLocaleOverride() async throws {
        let fixture = try ViewModelRecorderFixture()
        let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
        var record = try fixture.store.createMeeting(
            name: "Mandarin Standup",
            startedAt: Date(timeIntervalSince1970: 100)
        ).record
        record.speechLocaleIdentifier = "zh-CN"
        try fixture.store.save(record)
        let viewModel = MeetingAgentViewModel(
            store: fixture.store,
            recorder: fixture.recorder,
            speechConfiguration: SpeechTranscriptionConfiguration(
                provider: .whisper,
                localeIdentifier: "en-US",
                whisperBinaryPath: nil,
                whisperModelPath: nil
            ),
            processTargetsProvider: { [target] }
        )
        try viewModel.loadMeetings()

        try await viewModel.startRecording(for: target, meetingID: record.id)

        XCTAssertEqual(fixture.transcriberFactory.requests.first?.localeIdentifier, "zh-CN")
        XCTAssertEqual(viewModel.meetings.first?.speechLocaleIdentifier, "zh-CN")
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

            try await waitFor { viewModel.statusText == expectedText }
            XCTAssertEqual(viewModel.statusText, expectedText)
        }
    }

    func testActiveRecordingEmptyDrainDoesNotReplaySelectedTranscriptFile() async throws {
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
        try await viewModel.startRecording(for: target)
        let record = try XCTUnwrap(viewModel.meetings.first)
        let transcriptWriter = try TranscriptFileWriter(url: XCTUnwrap(record.transcriptURL))
        try transcriptWriter.replace(with: [
            TranscriptSegment(id: "segment-1", text: "Confirm launch owner.", language: "en-US", isFinal: true),
            TranscriptSegment(id: "partial", text: "partial", language: "en-US", isFinal: false)
        ])

        viewModel.drainRecordingFrames()

        XCTAssertTrue(viewModel.liveCaptionTurns.isEmpty)
        let replayEvents = try readPerformanceEvents(from: XCTUnwrap(record.performanceEventsURL))
            .filter { $0.event == "caption_turn_visible" && $0.metadata["path"] == "replay" }
        XCTAssertTrue(replayEvents.isEmpty)
    }

    func testSelectingActiveRecordingMeetingKeepsRealtimeCaptionsAndDoesNotReplayTranscriptFile() async throws {
        let fixture = try ViewModelRecorderFixture()
        let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
        let viewModel = MeetingAgentViewModel(
            store: fixture.store,
            recorder: fixture.recorder,
            processTargetsProvider: { [target] }
        )
        try await viewModel.startRecording(for: target)

        fixture.transcriber.emit(.upsert(TranscriptSegment(
            id: "live-1",
            text: "Realtime caption should stay visible",
            language: "en-US",
            isFinal: false
        )))
        viewModel.drainRecordingFrames()
        try await waitFor {
            viewModel.liveCaptionTurns.map(\.sourceSegmentID) == ["live-1"]
        }

        let record = try XCTUnwrap(viewModel.meetings.first)
        let transcriptWriter = try TranscriptFileWriter(url: XCTUnwrap(record.transcriptURL))
        try transcriptWriter.replace(with: [
            TranscriptSegment(
                id: "file-1",
                text: "File replay should not replace active captions.",
                language: "en-US",
                isFinal: true,
                speechFinal: true
            )
        ])

        viewModel.selectMeeting(record.id)
        await viewModel.waitForLiveCaptionReplayForTesting()

        XCTAssertEqual(viewModel.liveCaptionTurns.map(\.sourceSegmentID), ["live-1"])
        XCTAssertEqual(viewModel.liveCaptionTurns.first?.originalText, "Realtime caption should stay visible")
        let replayEvents = try readPerformanceEvents(from: XCTUnwrap(record.performanceEventsURL))
            .filter { $0.event == "caption_turn_visible" && $0.metadata["path"] == "replay" }
        XCTAssertTrue(replayEvents.isEmpty)
    }

    func testSelectingCompletedMeetingDuringActiveRecordingKeepsActiveRealtimeCaptions() async throws {
        let fixture = try ViewModelRecorderFixture()
        let completed = try fixture.store.createMeeting(name: "Completed Meeting", startedAt: Date(timeIntervalSince1970: 0)).record
        let completedWriter = try TranscriptFileWriter(url: XCTUnwrap(completed.transcriptURL))
        try completedWriter.replace(with: [
            TranscriptSegment(
                id: "completed-1",
                text: "Completed meeting replay should stay inactive.",
                language: "en-US",
                isFinal: true,
                speechFinal: true
            )
        ])
        let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
        let viewModel = MeetingAgentViewModel(
            store: fixture.store,
            recorder: fixture.recorder,
            processTargetsProvider: { [target] }
        )
        try viewModel.loadMeetings()
        try await viewModel.startRecording(for: target)

        fixture.transcriber.emit(.upsert(TranscriptSegment(
            id: "live-1",
            text: "Active recording remains the visible source",
            language: "en-US",
            isFinal: false
        )))
        viewModel.drainRecordingFrames()
        try await waitFor {
            viewModel.liveCaptionTurns.map(\.sourceSegmentID) == ["live-1"]
        }
        let activeRecord = try XCTUnwrap(viewModel.meetings.first)

        viewModel.selectMeeting(completed.id)
        await viewModel.waitForLiveCaptionReplayForTesting()

        XCTAssertEqual(viewModel.selectedMeetingID, activeRecord.id)
        XCTAssertEqual(viewModel.liveCaptionTurns.map(\.sourceSegmentID), ["live-1"])
        XCTAssertEqual(viewModel.liveCaptionTurns.first?.originalText, "Active recording remains the visible source")
        let completedReplayEvents = try readPerformanceEvents(from: XCTUnwrap(completed.performanceEventsURL))
            .filter { $0.event == "caption_turn_visible" && $0.metadata["path"] == "replay" }
        XCTAssertTrue(completedReplayEvents.isEmpty)
    }

    func testDrainRecordingFramesUsesRecorderTranscriptUpdatesForLiveCaptions() async throws {
        let fixture = try ViewModelRecorderFixture()
        let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
        let viewModel = MeetingAgentViewModel(
            store: fixture.store,
            recorder: fixture.recorder,
            processTargetsProvider: { [target] }
        )
        try await viewModel.startRecording(for: target)

        fixture.transcriber.emit(.upsert(TranscriptSegment(
            id: "live-1",
            text: "Live recorder transcript",
            language: "en-US",
            isFinal: true
        )))
        viewModel.drainRecordingFrames()

        try await waitFor {
            viewModel.liveCaptionTurns.map(\.sourceSegmentID) == ["live-1"]
        }
        XCTAssertEqual(viewModel.liveCaptionTurns.map(\.sourceSegmentID), ["live-1"])
        XCTAssertEqual(viewModel.liveCaptionTurns.first?.originalText, "Live recorder transcript")
        XCTAssertEqual(viewModel.liveCaptionTurns.first?.isFinal, true)
        XCTAssertEqual(viewModel.meetingProgressHealth.caption, .live)
    }

    func testSelectingMeetingReplaysCaptionsThroughPipeline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let stored = try store.createMeeting(name: "Replay Meeting", startedAt: Date(timeIntervalSince1970: 0))
        try FileTranscriptRepository().saveCaptionDocument(summaryCaptionDocument([
            TranscriptSegment(
                id: "segment-1",
                speaker: TranscriptSpeaker(identifier: "speaker-1"),
                text: "Pipeline replay works.",
                isFinal: true,
                speechFinal: true
            )
        ]), for: stored.record)

        let viewModel = MeetingAgentViewModel(store: store, processTargetsProvider: { [] })
        try viewModel.loadMeetings()
        viewModel.selectMeeting(stored.record.id)
        await viewModel.waitForLiveCaptionReplayForTesting()

        XCTAssertEqual(viewModel.liveCaptionTurns.map(\.originalText), ["Pipeline replay works."])
        XCTAssertEqual(viewModel.meetingProgressHealth.caption, .live)
    }

    func testSelectingMeetingIgnoresCachedFinalCaptionTranslationThroughPipeline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let stored = try store.createMeeting(name: "Replay Meeting", startedAt: Date(timeIntervalSince1970: 0))
        try FileTranscriptRepository().saveCaptionDocument(summaryCaptionDocument([
            TranscriptSegment(
                id: "segment-1",
                speaker: TranscriptSpeaker(identifier: "speaker-1"),
                text: "Pipeline replay works.",
                language: "en-US",
                isFinal: true,
                speechFinal: true,
                translatedText: "管线回放可用。",
                translationTargetLocale: "zh-CN",
                translationIsFinal: true
            )
        ]), for: stored.record)

        let viewModel = MeetingAgentViewModel(store: store, processTargetsProvider: { [] })
        try viewModel.loadMeetings()
        viewModel.selectMeeting(stored.record.id)
        await viewModel.waitForLiveCaptionReplayForTesting()

        XCTAssertNil(viewModel.liveCaptionTurns.first?.translatedText)
        XCTAssertEqual(viewModel.liveCaptionTurns.first?.translationState, .final)
    }

    func testRealtimeCaptionsDoNotPublishLegacyTranslationEvents() async throws {
        let fixture = try ViewModelRecorderFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
        let viewModel = MeetingAgentViewModel(
            store: fixture.store,
            recorder: fixture.recorder,
            processTargetsProvider: { [target] }
        )
        try await viewModel.startRecording(for: target)
        fixture.transcriber.emit(.upsert(TranscriptSegment(
            id: "segment-1",
            speaker: TranscriptSpeaker(identifier: "speaker-1"),
            text: "Realtime captions stay caption-only.",
            language: "en-US",
            isFinal: true,
            speechFinal: true
        )))

        viewModel.drainRecordingFrames()
        try await waitFor { viewModel.liveCaptionTurns.first?.isFinal == true }

        XCTAssertEqual(viewModel.liveCaptionTurns.map(\.originalText), ["Realtime captions stay caption-only."])
        XCTAssertNil(viewModel.liveCaptionTurns.first?.translatedText)

        let record = try XCTUnwrap(viewModel.meetings.first)
        let events = try readPerformanceEvents(from: XCTUnwrap(record.performanceEventsURL))
        XCTAssertFalse(events.contains { $0.event.hasPrefix("caption_translation_") })
        XCTAssertFalse(events.contains { $0.event.hasPrefix("translation_") })
    }



    func testActiveRecordingCaptionDoesNotRequireTranscriptFileReload() async throws {
        let fixture = try ViewModelRecorderFixture()
        let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
        let viewModel = MeetingAgentViewModel(
            store: fixture.store,
            recorder: fixture.recorder,
            processTargetsProvider: { [target] }
        )
        try await viewModel.startRecording(for: target)

        fixture.transcriber.emit(.upsert(TranscriptSegment(
            id: "stream-1",
            text: "Streamed without polling",
            language: "en-US",
            isFinal: false
        )))
        if let transcriptJSONURL = viewModel.selectedMeeting?.transcriptJSONURL {
            try FileManager.default.removeItem(at: transcriptJSONURL)
        }
        viewModel.drainRecordingFrames()

        try await waitFor {
            viewModel.liveCaptionTurns.map(\.sourceSegmentID) == ["stream-1"]
        }
        XCTAssertEqual(viewModel.liveCaptionTurns.map(\.sourceSegmentID), ["stream-1"])
        XCTAssertEqual(viewModel.liveCaptionTurns.first?.originalText, "Streamed without polling")
        XCTAssertEqual(viewModel.liveCaptionTurns.first?.isFinal, false)

        viewModel.drainRecordingFrames()

        XCTAssertEqual(viewModel.liveCaptionTurns.map(\.sourceSegmentID), ["stream-1"])
        XCTAssertEqual(viewModel.liveCaptionTurns.first?.originalText, "Streamed without polling")
    }

    func testActiveTranscriptUpdatesAreAppliedThroughPipeline() async throws {
        let fixture = try ViewModelRecorderFixture()
        let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
        let viewModel = MeetingAgentViewModel(
            store: fixture.store,
            recorder: fixture.recorder,
            liveCaptionSnapshotDebounceNanoseconds: 0,
            processTargetsProvider: { [target] }
        )
        try await viewModel.startRecording(for: target)
        var accumulator = TranscriptSegmentAccumulator()
        let result = accumulator.apply(.upsert(TranscriptSegment(
            id: "deepgram-draft-1",
            text: "We should localize this rollout",
            language: "en-US",
            isFinal: false
        )))

        await viewModel.applyTranscriptAccumulationResultsForTesting([result])

        XCTAssertEqual(viewModel.liveCaptionTurns.map(\.sourceSegmentID), ["deepgram-draft-1"])
        XCTAssertEqual(viewModel.liveCaptionTurns.first?.originalText, "We should localize this rollout")
        XCTAssertEqual(viewModel.liveCaptionTurns.first?.displayState, .draft)
        XCTAssertEqual(viewModel.meetingProgressHealth.caption, .live)
    }

    func testDefaultLiveCaptionSnapshotPublicationIsImmediate() async throws {
        let fixture = try ViewModelRecorderFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
        let viewModel = MeetingAgentViewModel(
            store: fixture.store,
            recorder: fixture.recorder,
            processTargetsProvider: { [target] }
        )
        try await viewModel.startRecording(for: target)
        var accumulator = TranscriptSegmentAccumulator()
        let result = accumulator.apply(.upsert(TranscriptSegment(
            id: "default-draft",
            text: "default debounce should not hold this",
            language: "en-US",
            isFinal: false
        )))

        await viewModel.applyTranscriptAccumulationResultsForTesting([result])

        XCTAssertEqual(viewModel.liveCaptionTurns.first?.sourceSegmentID, "default-draft")
        XCTAssertEqual(viewModel.liveCaptionTurns.first?.originalText, "default debounce should not hold this")
    }

    func testDraftCaptionInputThrottlePublishesFirstDraftImmediately() async throws {
        let fixture = try ViewModelRecorderFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
        let viewModel = MeetingAgentViewModel(
            store: fixture.store,
            recorder: fixture.recorder,
            draftCaptionInputThrottleNanoseconds: 200_000_000,
            processTargetsProvider: { [target] }
        )
        try await viewModel.startRecording(for: target)

        fixture.transcriber.emit(.upsert(TranscriptSegment(
            id: "source-draft-1",
            text: "first draft appears immediately",
            language: "en-US",
            isFinal: false
        )))
        viewModel.drainRecordingFrames()

        try await waitFor {
            viewModel.liveCaptionTurns.first?.originalText == "first draft appears immediately"
        }
        XCTAssertEqual(viewModel.liveCaptionTurns.first?.sourceSegmentID, "source-draft-1")
    }

    func testDraftCaptionInputThrottleCoalescesRapidDraftUpdatesBeforePipeline() async throws {
        let fixture = try ViewModelRecorderFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
        let viewModel = MeetingAgentViewModel(
            store: fixture.store,
            recorder: fixture.recorder,
            draftCaptionInputThrottleNanoseconds: 200_000_000,
            processTargetsProvider: { [target] }
        )
        try await viewModel.startRecording(for: target)

        fixture.transcriber.emit(.upsert(TranscriptSegment(
            id: "source-draft-1",
            text: "first draft",
            language: "en-US",
            isFinal: false
        )))
        viewModel.drainRecordingFrames()
        try await waitFor { viewModel.liveCaptionTurns.first?.originalText == "first draft" }

        fixture.transcriber.emit(.upsert(TranscriptSegment(
            id: "source-draft-1",
            text: "second draft should be replaced",
            language: "en-US",
            isFinal: false
        )))
        viewModel.drainRecordingFrames()
        fixture.transcriber.emit(.upsert(TranscriptSegment(
            id: "source-draft-1",
            text: "third draft wins",
            language: "en-US",
            isFinal: false
        )))
        viewModel.drainRecordingFrames()

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(viewModel.liveCaptionTurns.first?.originalText, "first draft")

        try await waitFor {
            viewModel.liveCaptionTurns.first?.originalText == "third draft wins"
        }
        XCTAssertEqual(viewModel.liveCaptionTurns.count, 1)
    }

    func testFinalTranscriptUpdateBypassesDraftCaptionInputThrottle() async throws {
        let fixture = try ViewModelRecorderFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
        let viewModel = MeetingAgentViewModel(
            store: fixture.store,
            recorder: fixture.recorder,
            draftCaptionInputThrottleNanoseconds: 1_000_000_000,
            processTargetsProvider: { [target] }
        )
        try await viewModel.startRecording(for: target)

        fixture.transcriber.emit(.upsert(TranscriptSegment(
            id: "final-bypass",
            text: "draft text",
            language: "en-US",
            isFinal: false
        )))
        viewModel.drainRecordingFrames()
        try await waitFor { viewModel.liveCaptionTurns.first?.originalText == "draft text" }

        fixture.transcriber.emit(.upsert(TranscriptSegment(
            id: "final-bypass",
            text: "pending draft text",
            language: "en-US",
            isFinal: false
        )))
        viewModel.drainRecordingFrames()
        XCTAssertEqual(viewModel.liveCaptionTurns.first?.originalText, "draft text")

        fixture.transcriber.emit(.upsert(TranscriptSegment(
            id: "final-bypass",
            text: "final text",
            language: "en-US",
            isFinal: true,
            speechFinal: true
        )))
        viewModel.drainRecordingFrames()

        try await waitFor { viewModel.liveCaptionTurns.first?.originalText == "final text" }
        XCTAssertEqual(viewModel.liveCaptionTurns.first?.isFinal, true)

        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(viewModel.liveCaptionTurns.first?.originalText, "final text")
    }

    func testStopRecordingCancelsPendingDraftCaptionInputThrottle() async throws {
        let fixture = try ViewModelRecorderFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
        let viewModel = MeetingAgentViewModel(
            store: fixture.store,
            recorder: fixture.recorder,
            draftCaptionInputThrottleNanoseconds: 1_000_000_000,
            processTargetsProvider: { [target] }
        )
        try await viewModel.startRecording(for: target)

        fixture.transcriber.emit(.upsert(TranscriptSegment(
            id: "stop-throttle",
            text: "visible draft",
            language: "en-US",
            isFinal: false
        )))
        viewModel.drainRecordingFrames()
        try await waitFor { viewModel.liveCaptionTurns.first?.originalText == "visible draft" }

        fixture.transcriber.emit(.upsert(TranscriptSegment(
            id: "stop-throttle",
            text: "pending draft should not publish after stop",
            language: "en-US",
            isFinal: false
        )))
        viewModel.drainRecordingFrames()
        viewModel.stopRecording(at: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(viewModel.liveCaptionTurns.first?.freezeReason, .manualStop)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNotEqual(viewModel.liveCaptionTurns.first?.originalText, "pending draft should not publish after stop")
    }

    func testEmptyDrainAfterStopDoesNotReplaySelectedMeetingTranscript() async throws {
        let fixture = try ViewModelRecorderFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
        let viewModel = MeetingAgentViewModel(
            store: fixture.store,
            recorder: fixture.recorder,
            processTargetsProvider: { [target] }
        )
        try await viewModel.startRecording(for: target)

        fixture.transcriber.emit(.upsert(TranscriptSegment(
            id: "stop-replay",
            text: "Visible caption should remain after stop.",
            language: "en-US",
            isFinal: true,
            speechFinal: false
        )))
        viewModel.drainRecordingFrames()
        try await waitFor {
            viewModel.liveCaptionTurns.first?.sourceSegmentID == "stop-replay"
        }

        let record = try XCTUnwrap(viewModel.meetings.first)
        viewModel.stopRecording(at: Date(timeIntervalSince1970: 200))
        viewModel.drainRecordingFrames()

        let replayEvents = try readPerformanceEvents(from: XCTUnwrap(record.performanceEventsURL))
            .filter { $0.event == "caption_turn_visible" && $0.metadata["path"] == "replay" }
        XCTAssertTrue(replayEvents.isEmpty)
        XCTAssertEqual(viewModel.liveCaptionTurns.first?.sourceSegmentID, "stop-replay")
    }

    func testStopRecordingPersistsLiveCaptionTiming() async throws {
        let fixture = try ViewModelRecorderFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
        let viewModel = MeetingAgentViewModel(
            store: fixture.store,
            recorder: fixture.recorder,
            processTargetsProvider: { [target] }
        )
        try await viewModel.startRecording(for: target)

        fixture.transcriber.emit(.upsert(TranscriptSegment(
            id: "timed-final",
            speaker: TranscriptSpeaker(identifier: "speaker-1", label: "Alex"),
            startTimeSeconds: 12.5,
            endTimeSeconds: 15.25,
            text: "We decided to launch on Monday.",
            language: "en-US",
            sourceProvider: "deepgram-transcribe",
            isFinal: true,
            speechFinal: true
        )))
        viewModel.drainRecordingFrames()
        try await waitFor {
            viewModel.liveCaptionTurns.first?.sourceSegmentID == "timed-final"
        }

        let record = try XCTUnwrap(viewModel.selectedMeeting)
        viewModel.stopRecording(at: Date(timeIntervalSince1970: 200))

        let document = try MeetingTranscriptStore.readDocument(from: XCTUnwrap(record.transcriptJSONURL))
        let turn = try XCTUnwrap(document.turns.first)
        XCTAssertEqual(turn.startTimeSeconds, 12.5)
        XCTAssertEqual(turn.endTimeSeconds, 15.25)
        XCTAssertEqual(turn.sections.first?.startTimeSeconds, 12.5)
        XCTAssertEqual(turn.sections.first?.endTimeSeconds, 15.25)
        XCTAssertEqual(viewModel.selectedMeetingSessionState?.transcript.captionDocument.turns.first?.startTimeSeconds, 12.5)

        let srtURL = fixture.root.appendingPathComponent("timed-export.srt")
        try viewModel.exportSubtitles(for: record.id, format: .srt, to: srtURL)
        let srt = try String(contentsOf: srtURL, encoding: .utf8)
        XCTAssertTrue(srt.contains("00:00:12,500 --> 00:00:15,250"))
    }

    func testDraftCaptionInputThrottleLogsCoalescingTelemetry() async throws {
        let fixture = try ViewModelRecorderFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
        let viewModel = MeetingAgentViewModel(
            store: fixture.store,
            recorder: fixture.recorder,
            draftCaptionInputThrottleNanoseconds: 200_000_000,
            processTargetsProvider: { [target] }
        )
        try await viewModel.startRecording(for: target)
        let record = try XCTUnwrap(viewModel.selectedMeeting)

        fixture.transcriber.emit(.upsert(TranscriptSegment(
            id: "telemetry-draft",
            text: "first",
            language: "en-US",
            isFinal: false
        )))
        viewModel.drainRecordingFrames()
        try await waitFor { viewModel.liveCaptionTurns.first?.originalText == "first" }

        fixture.transcriber.emit(.upsert(TranscriptSegment(
            id: "telemetry-draft",
            text: "second",
            language: "en-US",
            isFinal: false
        )))
        viewModel.drainRecordingFrames()
        fixture.transcriber.emit(.upsert(TranscriptSegment(
            id: "telemetry-draft",
            text: "third",
            language: "en-US",
            isFinal: false
        )))
        viewModel.drainRecordingFrames()

        try await waitFor {
            ((try? readPerformanceEvents(from: XCTUnwrap(record.performanceEventsURL))) ?? [])
                .contains { $0.event == "caption_input_throttle_fired" }
        }
        let events = try readPerformanceEvents(from: XCTUnwrap(record.performanceEventsURL))
        XCTAssertTrue(events.contains { $0.event == "caption_input_throttle_scheduled" })
        XCTAssertTrue(events.contains { $0.event == "caption_input_throttle_coalesced" })
        let firedEvent = events.first { $0.event == "caption_input_throttle_fired" }
        XCTAssertEqual(firedEvent?.metadata["delayMilliseconds"], "200")
        XCTAssertEqual(firedEvent?.metadata["latestChangedSegmentID"], "telemetry-draft")
    }

    func testDraftThrottleDoesNotCancelPendingFinalCaptionApply() async throws {
        let fixture = try ViewModelRecorderFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
        let viewModel = MeetingAgentViewModel(
            store: fixture.store,
            recorder: fixture.recorder,
            draftCaptionInputThrottleNanoseconds: 1_000_000_000,
            processTargetsProvider: { [target] }
        )
        try await viewModel.startRecording(for: target)

        fixture.transcriber.emit(.upsert(TranscriptSegment(
            id: "segment-1",
            text: "first draft that is already visible",
            language: "en-US",
            isFinal: false
        )))
        viewModel.drainRecordingFrames()
        try await waitFor { viewModel.liveCaptionTurns.first?.originalText == "first draft that is already visible" }

        fixture.transcriber.emit(.upsert(TranscriptSegment(
            id: "segment-1",
            startTimeSeconds: 0,
            endTimeSeconds: 4,
            text: "first segment is now final and should not be lost",
            language: "en-US",
            isFinal: true,
            speechFinal: false
        )))
        viewModel.drainRecordingFrames()
        fixture.transcriber.emit(.upsert(TranscriptSegment(
            id: "segment-2",
            startTimeSeconds: 4.1,
            endTimeSeconds: 5,
            text: "next draft arrives immediately",
            language: "en-US",
            isFinal: false
        )))
        viewModel.drainRecordingFrames()

        try await waitFor {
            viewModel.liveCaptionTurns.contains {
                $0.sourceSegmentIDs.contains("segment-1")
                    && $0.originalText.contains("first segment is now final")
            }
        }
        XCTAssertFalse(viewModel.liveCaptionTurns.contains {
            $0.sourceSegmentID == "segment-1"
                && $0.originalText == "first draft that is already visible"
        })
    }

    func testDraftThrottleDoesNotDelayFinalWhenSameDrainAlsoContainsDraft() async throws {
        let fixture = try ViewModelRecorderFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
        let viewModel = MeetingAgentViewModel(
            store: fixture.store,
            recorder: fixture.recorder,
            draftCaptionInputThrottleNanoseconds: 1_000_000_000,
            processTargetsProvider: { [target] }
        )
        try await viewModel.startRecording(for: target)

        fixture.transcriber.emit(.upsert(TranscriptSegment(
            id: "segment-1",
            text: "first draft that is already visible",
            language: "en-US",
            isFinal: false
        )))
        viewModel.drainRecordingFrames()
        try await waitFor { viewModel.liveCaptionTurns.first?.originalText == "first draft that is already visible" }

        fixture.transcriber.emit(.upsert(TranscriptSegment(
            id: "segment-1",
            startTimeSeconds: 0,
            endTimeSeconds: 4,
            text: "first segment is final in the same drain",
            language: "en-US",
            isFinal: true,
            speechFinal: false
        )))
        fixture.transcriber.emit(.upsert(TranscriptSegment(
            id: "segment-2",
            startTimeSeconds: 4.1,
            endTimeSeconds: 5,
            text: "next draft would normally be throttled",
            language: "en-US",
            isFinal: false
        )))
        viewModel.drainRecordingFrames()

        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(viewModel.liveCaptionTurns.contains {
            $0.sourceSegmentIDs.contains("segment-1")
                && $0.originalText.contains("first segment is final")
        })
    }

    func testSelectingAnotherMeetingCancelsPendingDraftCaptionInputThrottle() async throws {
        let fixture = try ViewModelRecorderFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
        let viewModel = MeetingAgentViewModel(
            store: fixture.store,
            recorder: fixture.recorder,
            draftCaptionInputThrottleNanoseconds: 1_000_000_000,
            processTargetsProvider: { [target] }
        )
        try await viewModel.startRecording(for: target)
        let secondMeeting = try fixture.store.createMeeting(name: "Second", startedAt: Date()).record

        fixture.transcriber.emit(.upsert(TranscriptSegment(
            id: "switch-throttle",
            text: "visible draft",
            language: "en-US",
            isFinal: false
        )))
        viewModel.drainRecordingFrames()
        try await waitFor { viewModel.liveCaptionTurns.first?.originalText == "visible draft" }

        fixture.transcriber.emit(.upsert(TranscriptSegment(
            id: "switch-throttle",
            text: "pending draft after switch",
            language: "en-US",
            isFinal: false
        )))
        viewModel.drainRecordingFrames()
        viewModel.selectMeeting(secondMeeting.id)

        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNotEqual(viewModel.liveCaptionTurns.first?.originalText, "pending draft after switch")
    }

    func testReplayBypassesDraftCaptionInputThrottle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "meeting-vm-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let record = try store.createMeeting(name: "Meet", startedAt: Date()).record
        try FileTranscriptRepository().saveCaptionDocument(summaryCaptionDocument([
            TranscriptSegment(id: "replay-draft", text: "historical draft", language: "en-US", isFinal: false)
        ]), for: record)
        let viewModel = MeetingAgentViewModel(
            store: store,
            draftCaptionInputThrottleNanoseconds: 1_000_000_000,
            processTargetsProvider: { [] }
        )
        try viewModel.loadMeetings()
        viewModel.selectMeeting(record.id)
        await viewModel.waitForLiveCaptionReplayForTesting()

        XCTAssertEqual(viewModel.liveCaptionTurns.first?.originalText, "historical draft")
    }

    func testDraftCaptionInputThrottleCanBeDisabled() async throws {
        let fixture = try ViewModelRecorderFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
        let viewModel = MeetingAgentViewModel(
            store: fixture.store,
            recorder: fixture.recorder,
            draftCaptionInputThrottleNanoseconds: 0,
            processTargetsProvider: { [target] }
        )
        try await viewModel.startRecording(for: target)

        fixture.transcriber.emit(.upsert(TranscriptSegment(
            id: "disabled-throttle",
            text: "first draft",
            language: "en-US",
            isFinal: false
        )))
        viewModel.drainRecordingFrames()
        try await waitFor { viewModel.liveCaptionTurns.first?.originalText == "first draft" }

        fixture.transcriber.emit(.upsert(TranscriptSegment(
            id: "disabled-throttle",
            text: "second draft immediately visible",
            language: "en-US",
            isFinal: false
        )))
        viewModel.drainRecordingFrames()

        try await waitFor {
            viewModel.liveCaptionTurns.first?.originalText == "second draft immediately visible"
        }
    }

    func testDraftCaptionSnapshotsAreDebouncedBeforePublication() async throws {
        let fixture = try ViewModelRecorderFixture()
        let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
        let viewModel = MeetingAgentViewModel(
            store: fixture.store,
            recorder: fixture.recorder,
            liveCaptionSnapshotDebounceNanoseconds: 100_000_000,
            processTargetsProvider: { [target] }
        )
        try await viewModel.startRecording(for: target)
        var accumulator = TranscriptSegmentAccumulator()

        let first = accumulator.apply(.upsert(TranscriptSegment(
            id: "draft-1",
            text: "first draft",
            language: "en-US",
            isFinal: false
        )))
        await viewModel.applyTranscriptAccumulationResultsForTesting([first])
        XCTAssertTrue(viewModel.liveCaptionTurns.isEmpty)

        let second = accumulator.apply(.upsert(TranscriptSegment(
            id: "draft-1",
            text: "second draft",
            language: "en-US",
            isFinal: false
        )))
        await viewModel.applyTranscriptAccumulationResultsForTesting([second])
        XCTAssertTrue(viewModel.liveCaptionTurns.isEmpty)

        try await waitFor {
            viewModel.liveCaptionTurns.first?.originalText == "second draft"
        }
        XCTAssertEqual(viewModel.liveCaptionTurns.count, 1)
    }

    func testFinalCaptionSnapshotPublishesImmediatelyAndCancelsPendingDraft() async throws {
        let fixture = try ViewModelRecorderFixture()
        let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
        let viewModel = MeetingAgentViewModel(
            store: fixture.store,
            recorder: fixture.recorder,
            liveCaptionSnapshotDebounceNanoseconds: 1_000_000_000,
            processTargetsProvider: { [target] }
        )
        try await viewModel.startRecording(for: target)
        var accumulator = TranscriptSegmentAccumulator()

        let draft = accumulator.apply(.upsert(TranscriptSegment(
            id: "caption-1",
            text: "draft text",
            language: "en-US",
            isFinal: false
        )))
        await viewModel.applyTranscriptAccumulationResultsForTesting([draft])
        XCTAssertTrue(viewModel.liveCaptionTurns.isEmpty)

        let final = accumulator.apply(.upsert(TranscriptSegment(
            id: "caption-1",
            text: "final text",
            language: "en-US",
            isFinal: true,
            speechFinal: true
        )))
        await viewModel.applyTranscriptAccumulationResultsForTesting([final])

        XCTAssertEqual(viewModel.liveCaptionTurns.first?.originalText, "final text")
        XCTAssertEqual(viewModel.liveCaptionTurns.first?.isFinal, true)

        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(viewModel.liveCaptionTurns.first?.originalText, "final text")
    }

    func testDraftSnapshotAfterVisibleFinalCaptionIsDebounced() async throws {
        let fixture = try ViewModelRecorderFixture()
        let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
        let viewModel = MeetingAgentViewModel(
            store: fixture.store,
            recorder: fixture.recorder,
            liveCaptionSnapshotDebounceNanoseconds: 100_000_000,
            processTargetsProvider: { [target] }
        )
        try await viewModel.startRecording(for: target)
        var accumulator = TranscriptSegmentAccumulator()

        let final = accumulator.apply(.upsert(TranscriptSegment(
            id: "final-1",
            text: "final text",
            language: "en-US",
            isFinal: true,
            speechFinal: true
        )))
        await viewModel.applyTranscriptAccumulationResultsForTesting([final])
        XCTAssertEqual(viewModel.liveCaptionTurns.map(\.sourceSegmentID), ["final-1"])

        let draft = accumulator.apply(.upsert(TranscriptSegment(
            id: "draft-2",
            text: "draft after final",
            language: "en-US",
            isFinal: false
        )))
        await viewModel.applyTranscriptAccumulationResultsForTesting([draft])
        XCTAssertEqual(viewModel.liveCaptionTurns.map(\.sourceSegmentID), ["final-1"])

        try await waitFor {
            viewModel.liveCaptionTurns.map(\.sourceSegmentID) == ["final-1", "draft-2"]
        }
    }

    func testSelectingAnotherMeetingCancelsPendingDraftCaptionSnapshot() async throws {
        let fixture = try ViewModelRecorderFixture()
        let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
        let viewModel = MeetingAgentViewModel(
            store: fixture.store,
            recorder: fixture.recorder,
            liveCaptionSnapshotDebounceNanoseconds: 1_000_000_000,
            processTargetsProvider: { [target] }
        )
        try await viewModel.startRecording(for: target)
        let firstMeetingID = try XCTUnwrap(viewModel.selectedMeetingID)
        let secondMeeting = try fixture.store.createMeeting(name: "Second", startedAt: Date()).record
        viewModel.selectMeeting(firstMeetingID)
        var accumulator = TranscriptSegmentAccumulator()

        let draft = accumulator.apply(.upsert(TranscriptSegment(
            id: "stale-draft",
            text: "stale draft",
            language: "en-US",
            isFinal: false
        )))
        await viewModel.applyTranscriptAccumulationResultsForTesting([draft])
        XCTAssertTrue(viewModel.liveCaptionTurns.isEmpty)

        viewModel.selectMeeting(secondMeeting.id)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(viewModel.liveCaptionTurns.isEmpty)
    }

    func testCoalescedDraftCaptionSnapshotsLogPerformanceEvent() async throws {
        let fixture = try ViewModelRecorderFixture()
        let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
        let viewModel = MeetingAgentViewModel(
            store: fixture.store,
            recorder: fixture.recorder,
            liveCaptionSnapshotDebounceNanoseconds: 100_000_000,
            processTargetsProvider: { [target] }
        )
        try await viewModel.startRecording(for: target)
        let record = try XCTUnwrap(viewModel.selectedMeeting)
        var accumulator = TranscriptSegmentAccumulator()

        let first = accumulator.apply(.upsert(TranscriptSegment(
            id: "metric-draft",
            text: "first",
            language: "en-US",
            isFinal: false
        )))
        await viewModel.applyTranscriptAccumulationResultsForTesting([first])
        let second = accumulator.apply(.upsert(TranscriptSegment(
            id: "metric-draft",
            text: "second",
            language: "en-US",
            isFinal: false
        )))
        await viewModel.applyTranscriptAccumulationResultsForTesting([second])

        try await waitFor {
            ((try? readPerformanceEvents(from: XCTUnwrap(record.performanceEventsURL))) ?? [])
                .contains(where: { $0.event == "caption_snapshot_publication_coalesced" })
        }
    }

    func testStaleActiveTranscriptApplyDoesNotOverwriteNewerCaption() async throws {
        let fixture = try ViewModelRecorderFixture()
        let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
        let viewModel = MeetingAgentViewModel(
            store: fixture.store,
            recorder: fixture.recorder,
            liveCaptionSnapshotDebounceNanoseconds: 0,
            processTargetsProvider: { [target] }
        )
        try await viewModel.startRecording(for: target)
        var oldAccumulator = TranscriptSegmentAccumulator()
        let oldResult = oldAccumulator.apply(.upsert(TranscriptSegment(
            id: "active-1",
            text: "Older caption",
            language: "en-US",
            isFinal: false
        )))
        var newAccumulator = TranscriptSegmentAccumulator()
        let newResult = newAccumulator.apply(.upsert(TranscriptSegment(
            id: "active-2",
            text: "Newer caption",
            language: "en-US",
            isFinal: false
        )))

        let staleContext = viewModel.beginActiveCaptionApplyForTesting()
        let currentContext = viewModel.beginActiveCaptionApplyForTesting()

        await viewModel.applyTranscriptAccumulationResultsForTesting([newResult], context: currentContext)
        await viewModel.applyTranscriptAccumulationResultsForTesting([oldResult], context: staleContext)

        XCTAssertEqual(viewModel.liveCaptionTurns.map(\.sourceSegmentID), ["active-2"])
        XCTAssertEqual(viewModel.liveCaptionTurns.first?.originalText, "Newer caption")
    }










    func testIdleDrainDoesNotReplayUnchangedSelectedTranscriptRepeatedly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let record = try store.createMeeting(name: "Meet", startedAt: Date()).record
        try FileTranscriptRepository().saveCaptionDocument(summaryCaptionDocument([
            TranscriptSegment(
                id: "segment-1",
                speaker: TranscriptSpeaker(identifier: "speaker-1"),
                text: "The selected meeting has already stopped.",
                language: "en-US",
                isFinal: true,
                speechFinal: true
            )
        ]), for: record)
        let viewModel = MeetingAgentViewModel(store: store)
        try viewModel.loadMeetings()
        viewModel.selectMeeting(record.id)

        viewModel.drainRecordingFrames()
        let firstVisibleEventCount = try readPerformanceEvents(from: XCTUnwrap(record.performanceEventsURL))
            .filter { $0.event == "caption_turn_visible" }
            .count
        viewModel.drainRecordingFrames()

        let visibleEvents = try readPerformanceEvents(from: XCTUnwrap(record.performanceEventsURL))
            .filter { $0.event == "caption_turn_visible" }
        XCTAssertGreaterThan(firstVisibleEventCount, 0)
        XCTAssertEqual(visibleEvents.count, firstVisibleEventCount)
    }



























    func testRefreshMeetingProgressAnalyzesLiveCaptionsAndWritesProgressArtifact() async throws {
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
        try await viewModel.startRecording(for: target)
        let record = try XCTUnwrap(viewModel.meetings.first)
        viewModel.setMeetingGoal(MeetingGoal(
            title: "Confirm launch plan",
            objectives: [MeetingObjective(id: "owner", title: "Confirm launch owner", keywords: ["launch owner"])],
            requiredQuestions: ["Have we confirmed the deadline?"],
            expectedDecisions: [],
            keyTerms: []
        ))
        fixture.transcriber.emit(.upsert(TranscriptSegment(
            id: "segment-1",
            text: "Alex is the launch owner.",
            language: "en-US",
            isFinal: true
        )))
        viewModel.drainRecordingFrames()
        try await waitFor {
            viewModel.liveCaptionTurns.first?.sourceSegmentID == "segment-1"
        }

        await viewModel.refreshMeetingProgress()

        XCTAssertEqual(viewModel.meetingProgressState?.status, .onTrack)
        XCTAssertEqual(viewModel.meetingProgressState?.suggestedQuestions, [])
        let progressURL = try XCTUnwrap(record.meetingProgressJSONURL)
        let saved = try JSONDecoder.meetingAgent.decode(MeetingProgressState.self, from: Data(contentsOf: progressURL))
        XCTAssertEqual(saved.lastAnalyzedSegmentID, "segment-1")
    }

    func testRefreshMeetingProgressPublishesRecommendedQuestions() async throws {
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
        try await viewModel.startRecording(for: target)
        let record = try XCTUnwrap(viewModel.meetings.first)
        try viewModel.saveAgenda(
            for: record.id,
            update: MeetingAgendaUpdate(
                name: record.name,
                attendees: [],
                agendaTopics: [
                    MeetingAgendaTopic(title: "Budget risk"),
                    MeetingAgendaTopic(title: "Launch readiness"),
                    MeetingAgendaTopic(title: "Support handoff")
                ],
                scheduledStartAt: record.scheduledStartAt,
                scheduledEndAt: record.scheduledEndAt,
                meetingGoal: MeetingGoal(
                    title: "Confirm launch plan",
                    objectives: [],
                    requiredQuestions: [],
                    expectedDecisions: [],
                    keyTerms: []
                )
            )
        )
        fixture.transcriber.emit(.upsert(TranscriptSegment(
            id: "segment-1",
            text: "We discussed hiring.",
            language: "en-US",
            isFinal: true
        )))
        viewModel.drainRecordingFrames()
        try await waitFor {
            viewModel.liveCaptionTurns.first?.sourceSegmentID == "segment-1"
        }

        await viewModel.refreshMeetingProgress()

        XCTAssertEqual(viewModel.recommendedQuestions.map(\.english), [
            "Could we clarify Budget risk?",
            "Could we clarify Launch readiness?"
        ])
    }

    func testRecommendedQuestionsLimitsPersistedProgressToFirstTwo() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        var created = try store.createMeeting(name: "Google Meet", startedAt: Date(timeIntervalSince1970: 100))
        let goal = MeetingGoal(
            title: "Confirm launch plan",
            objectives: [],
            requiredQuestions: [],
            expectedDecisions: [],
            keyTerms: []
        )
        created.record.meetingGoal = goal
        try store.save(created.record)
        let progress = MeetingProgressState(
            meetingID: created.record.id,
            goal: goal,
            status: .onTrack,
            objectives: [],
            confirmedItems: [],
            unresolvedItems: [],
            suggestedQuestions: [
                FollowUpQuestionSuggestion(chinese: "一", english: "One", sourceObjectiveID: nil),
                FollowUpQuestionSuggestion(chinese: "二", english: "Two", sourceObjectiveID: nil),
                FollowUpQuestionSuggestion(chinese: "三", english: "Three", sourceObjectiveID: nil)
            ],
            health: MeetingProgressHealth(caption: .live, translation: .live, analysis: .live),
            lastAnalyzedSegmentID: nil,
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        try JSONEncoder.meetingAgent.encode(progress).write(to: XCTUnwrap(created.record.meetingProgressJSONURL), options: .atomic)
        let viewModel = MeetingAgentViewModel(store: store, processTargetsProvider: { [] })

        try viewModel.loadMeetings()

        XCTAssertEqual(viewModel.recommendedQuestions.map(\.english), ["One", "Two"])
    }

    func testPreMeetingGoalAnalyzesAfterRecordingStarts() async throws {
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
        viewModel.setMeetingGoal(MeetingGoal(
            title: "Confirm launch plan",
            objectives: [MeetingObjective(id: "owner", title: "Confirm launch owner", keywords: ["launch owner"])],
            requiredQuestions: [],
            expectedDecisions: [],
            keyTerms: []
        ))
        try await viewModel.startRecording(for: target)
        let record = try XCTUnwrap(viewModel.meetings.first)
        fixture.transcriber.emit(.upsert(TranscriptSegment(
            id: "segment-1",
            text: "Alex is the launch owner.",
            language: "en-US",
            isFinal: true
        )))

        viewModel.drainRecordingFrames()
        try await waitFor {
            viewModel.liveCaptionTurns.first?.sourceSegmentID == "segment-1"
        }
        await viewModel.refreshMeetingProgress()

        XCTAssertEqual(viewModel.meetingProgressState?.status, .onTrack)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(record.meetingProgressJSONURL).path))
        let saved = try JSONDecoder.meetingAgent.decode(MeetingRecord.self, from: Data(contentsOf: fixture.store.metadataURL(for: record.id)))
        XCTAssertEqual(saved.meetingGoal?.title, "Confirm launch plan")
    }

    func testClearingMeetingGoalClearsProgressState() async throws {
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
        try await viewModel.startRecording(for: target)
        let record = try XCTUnwrap(viewModel.meetings.first)
        viewModel.setMeetingGoal(MeetingGoal(
            title: "Confirm launch plan",
            objectives: [MeetingObjective(id: "owner", title: "Confirm launch owner", keywords: ["launch owner"])],
            requiredQuestions: [],
            expectedDecisions: [],
            keyTerms: []
        ))
        fixture.transcriber.emit(.upsert(TranscriptSegment(
            id: "segment-1",
            text: "Alex is the launch owner.",
            language: "en-US",
            isFinal: true
        )))
        viewModel.drainRecordingFrames()
        try await waitFor {
            viewModel.liveCaptionTurns.first?.sourceSegmentID == "segment-1"
        }
        await viewModel.refreshMeetingProgress()
        XCTAssertNotNil(viewModel.meetingProgressState)

        viewModel.setMeetingGoal(nil)

        XCTAssertNil(viewModel.meetingProgressState)
        XCTAssertEqual(viewModel.meetingProgressHealth.analysis, .idle)
        let saved = try JSONDecoder.meetingAgent.decode(MeetingRecord.self, from: Data(contentsOf: fixture.store.metadataURL(for: record.id)))
        XCTAssertNil(saved.meetingGoal)
    }

    func testLoadMeetingsRestoresPersistedMeetingGoalForSelectedMeeting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        var stored = try store.createMeeting(name: "Google Meet", startedAt: Date(timeIntervalSince1970: 100)).record
        let goal = MeetingGoal(
            title: "Confirm launch plan",
            objectives: [MeetingObjective(id: "owner", title: "Confirm launch owner")],
            requiredQuestions: [],
            expectedDecisions: [],
            keyTerms: []
        )
        stored.meetingGoal = goal
        try store.save(stored)
        let viewModel = MeetingAgentViewModel(store: store, processTargetsProvider: { [] })

        try viewModel.loadMeetings()

        XCTAssertEqual(viewModel.meetingGoal?.title, "Confirm launch plan")
    }

    func testLoadMeetingsRestoresMatchingPersistedProgressSnapshot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        var stored = try store.createMeeting(name: "Google Meet", startedAt: Date(timeIntervalSince1970: 100)).record
        let goal = MeetingGoal(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            title: "Confirm launch plan",
            objectives: [MeetingObjective(id: "owner", title: "Confirm launch owner")],
            requiredQuestions: [],
            expectedDecisions: [],
            keyTerms: []
        )
        stored.meetingGoal = goal
        try store.save(stored)
        let snapshot = MeetingProgressState(
            meetingID: stored.id,
            goal: goal,
            status: .onTrack,
            objectives: [
                MeetingObjectiveProgress(
                    objectiveID: "owner",
                    title: "Confirm launch owner",
                    status: .confirmed,
                    evidenceSegmentIDs: ["segment-1"]
                )
            ],
            confirmedItems: ["Confirm launch owner"],
            unresolvedItems: [],
            suggestedQuestions: [],
            health: MeetingProgressHealth(caption: .live, translation: .pending, analysis: .live),
            lastAnalyzedSegmentID: "segment-1",
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        try JSONEncoder.meetingAgent.encode(snapshot).write(to: XCTUnwrap(stored.meetingProgressJSONURL), options: .atomic)
        let viewModel = MeetingAgentViewModel(store: store, processTargetsProvider: { [] })

        try viewModel.loadMeetings()

        XCTAssertEqual(viewModel.meetingProgressState?.status, .onTrack)
        XCTAssertEqual(viewModel.meetingProgressState?.lastAnalyzedSegmentID, "segment-1")
        XCTAssertEqual(viewModel.meetingProgressHealth.analysis, .live)
    }

    func testLoadMeetingsIgnoresProgressSnapshotForDifferentGoal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        var stored = try store.createMeeting(name: "Google Meet", startedAt: Date(timeIntervalSince1970: 100)).record
        let currentGoal = MeetingGoal(
            id: UUID(uuidString: "aaaaaaaa-2222-3333-4444-555555555555")!,
            title: "Current goal",
            objectives: [MeetingObjective(id: "current", title: "Confirm current item")],
            requiredQuestions: [],
            expectedDecisions: [],
            keyTerms: []
        )
        let staleGoal = MeetingGoal(
            id: UUID(uuidString: "bbbbbbbb-2222-3333-4444-555555555555")!,
            title: "Stale goal",
            objectives: [MeetingObjective(id: "stale", title: "Confirm stale item")],
            requiredQuestions: [],
            expectedDecisions: [],
            keyTerms: []
        )
        stored.meetingGoal = currentGoal
        try store.save(stored)
        let snapshot = MeetingProgressState(
            meetingID: stored.id,
            goal: staleGoal,
            status: .onTrack,
            objectives: [],
            confirmedItems: [],
            unresolvedItems: [],
            suggestedQuestions: [],
            health: MeetingProgressHealth(caption: .live, translation: .pending, analysis: .live),
            lastAnalyzedSegmentID: "segment-1",
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        try JSONEncoder.meetingAgent.encode(snapshot).write(to: XCTUnwrap(stored.meetingProgressJSONURL), options: .atomic)
        let viewModel = MeetingAgentViewModel(store: store, processTargetsProvider: { [] })

        try viewModel.loadMeetings()

        XCTAssertNil(viewModel.meetingProgressState)
        XCTAssertEqual(viewModel.meetingProgressHealth.analysis, .idle)
    }

    func testSelectMeetingSwitchesPersistedMeetingGoal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        var first = try store.createMeeting(name: "First", startedAt: Date(timeIntervalSince1970: 1)).record
        first.meetingGoal = MeetingGoal(
            title: "First goal",
            objectives: [MeetingObjective(id: "first", title: "Confirm first item")],
            requiredQuestions: [],
            expectedDecisions: [],
            keyTerms: []
        )
        try store.save(first)
        let second = try store.createMeeting(name: "Second", startedAt: Date(timeIntervalSince1970: 2)).record
        let viewModel = MeetingAgentViewModel(store: store, processTargetsProvider: { [] })
        try viewModel.loadMeetings()

        viewModel.selectMeeting(first.id)
        XCTAssertEqual(viewModel.meetingGoal?.title, "First goal")

        viewModel.selectMeeting(second.id)
        XCTAssertNil(viewModel.meetingGoal)
    }

    func testStopRecordingAndGenerateSummaryReturnsIdleWhenRecorderHasNoStoppedRecord() async throws {
        let viewModel = MeetingAgentViewModel(processTargetsProvider: { [] })

        try await viewModel.stopRecordingAndGenerateSummary()

        XCTAssertEqual(viewModel.statusText, "Idle")
    }

    func testPollActiveRecordingProcessStopsWhenTargetProcessEnds() throws {
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

        viewModel.pollActiveRecordingProcess(endedAt: endedAt)

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
        try FileTranscriptRepository().saveCaptionDocument(summaryCaptionDocument([
            TranscriptSegment(text: "Transcript text", language: "en-US")
        ]), for: stored.record)
        let viewModel = MeetingAgentViewModel(store: store)
        try viewModel.loadMeetings()
        let destination = root.appendingPathComponent("exported-transcript.txt")

        try viewModel.exportTranscript(for: stored.record.id, to: destination)

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "User A:\nTranscript text")
        XCTAssertEqual(viewModel.statusText, "Transcript exported")
    }

    func testUpdateSpeakerLabelRefreshesTranscriptArtifactsAndLiveCaptions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let stored = try store.createMeeting(name: "Google Meet", startedAt: Date(timeIntervalSince1970: 100))
        try FileTranscriptRepository().saveCaptionDocument(summaryCaptionDocument([
            TranscriptSegment(
                id: "segment-1",
                speaker: TranscriptSpeaker(identifier: "speaker-1", label: "User A"),
                text: "Hello",
                language: "en-US"
            )
        ]), for: stored.record)
        let viewModel = MeetingAgentViewModel(store: store, processTargetsProvider: { [] })
        try viewModel.loadMeetings()
        viewModel.selectMeeting(stored.record.id)
        viewModel.drainRecordingFrames()

        try await viewModel.updateSpeakerLabel(
            for: stored.record.id,
            speakerID: "speaker-1",
            label: "Allan"
        )

        let document = try TranscriptFileWriter.readDocument(from: XCTUnwrap(stored.record.transcriptJSONURL))
        XCTAssertEqual(document.segments.first?.speakerLabel, "Allan")
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(stored.record.transcriptURL), encoding: .utf8), "Allan:\nHello\n")
        XCTAssertEqual(viewModel.liveCaptionTurns.first?.speaker.label, "Allan")
        XCTAssertEqual(viewModel.statusText, "Speaker label updated")
    }

    func testUpdateTranscriptSegmentTextRefreshesLiveCaptionsAndInvalidatesDownstreamArtifacts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        var stored = try store.createMeeting(name: "Google Meet", startedAt: Date(timeIntervalSince1970: 100)).record
        let goal = MeetingGoal(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            title: "Confirm launch plan",
            objectives: [MeetingObjective(id: "owner", title: "Confirm launch owner")],
            requiredQuestions: [],
            expectedDecisions: [],
            keyTerms: []
        )
        stored.meetingGoal = goal
        try store.save(stored)
        try FileTranscriptRepository().saveCaptionDocument(summaryCaptionDocument([
            TranscriptSegment(
                id: "segment-1",
                speaker: TranscriptSpeaker(identifier: "speaker-1", label: "User A"),
                text: "Old text",
                language: "en-US"
            )
        ]), for: stored)
        let summary = MeetingSummary(
            overview: "Old summary",
            keyTopics: [],
            decisions: [],
            actionItems: [],
            openQuestions: [],
            risks: [],
            followUps: [],
            language: "en-US",
            sourceSegmentIDs: ["segment-1"],
            generatedAt: Date(timeIntervalSince1970: 200),
            provider: "test",
            status: .succeeded,
            failureReason: nil
        )
        try MeetingSummaryWriter.write(
            summary,
            jsonURL: XCTUnwrap(stored.summaryJSONURL),
            markdownURL: XCTUnwrap(stored.summaryMarkdownURL)
        )
        let progress = MeetingProgressState(
            meetingID: stored.id,
            goal: goal,
            status: .onTrack,
            objectives: [],
            confirmedItems: ["Old text"],
            unresolvedItems: [],
            suggestedQuestions: [],
            health: MeetingProgressHealth(caption: .live, translation: .pending, analysis: .live),
            lastAnalyzedSegmentID: "segment-1",
            updatedAt: Date(timeIntervalSince1970: 300)
        )
        let progressURL = try XCTUnwrap(stored.meetingProgressJSONURL)
        try JSONEncoder.meetingAgent.encode(progress).write(to: progressURL, options: .atomic)
        let viewModel = MeetingAgentViewModel(store: store, processTargetsProvider: { [] })
        try viewModel.loadMeetings()
        viewModel.selectMeeting(stored.id)
        viewModel.drainRecordingFrames()

        try await viewModel.updateTranscriptSegmentText(
            for: stored.id,
            segmentID: "segment-1",
            text: "Corrected text"
        )

        let document = try TranscriptFileWriter.readDocument(from: XCTUnwrap(stored.transcriptJSONURL))
        XCTAssertEqual(document.segments.first?.text, "Corrected text")
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(stored.transcriptURL), encoding: .utf8), "User A:\nCorrected text\n")
        XCTAssertEqual(viewModel.liveCaptionTurns.first?.originalText, "Corrected text")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(stored.summaryJSONURL).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(stored.summaryMarkdownURL).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: progressURL.path))
        XCTAssertNil(viewModel.meetingProgressState)
        XCTAssertEqual(viewModel.meetingProgressHealth.analysis, .idle)
        XCTAssertEqual(viewModel.statusText, "Transcript corrected; summary needs regeneration")
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
        try FileTranscriptRepository().saveCaptionDocument(summaryCaptionDocument([
            TranscriptSegment(startTimeSeconds: 0, endTimeSeconds: 2, text: "Hello", language: "en-US")
        ]), for: stored.record)
        let viewModel = MeetingAgentViewModel(store: store, processTargetsProvider: { [] })
        try viewModel.loadMeetings()

        let summaryDestination = root.appendingPathComponent("summary.md")
        let dataDestination = root.appendingPathComponent("meeting.json")
        let srtDestination = root.appendingPathComponent("captions.srt")
        let vttDestination = root.appendingPathComponent("captions.vtt")
        let readinessDestination = root.appendingPathComponent("readiness.json")
        try viewModel.exportSummary(for: stored.record.id, to: summaryDestination)
        XCTAssertEqual(viewModel.statusText, "Summary exported")
        try viewModel.exportMeetingData(for: stored.record.id, to: dataDestination)
        XCTAssertEqual(viewModel.statusText, "Meeting data exported")
        try viewModel.exportSubtitles(for: stored.record.id, format: .srt, to: srtDestination)
        XCTAssertEqual(viewModel.statusText, "SRT subtitles exported")
        try viewModel.exportSubtitles(for: stored.record.id, format: .vtt, to: vttDestination)
        XCTAssertEqual(viewModel.statusText, "VTT subtitles exported")
        try viewModel.exportReadinessReport(for: stored.record.id, to: readinessDestination)
        XCTAssertEqual(viewModel.statusText, "Readiness report exported")
        let knowledgePackageDestination = root.appendingPathComponent("knowledge-package", isDirectory: true)
        try viewModel.exportKnowledgePackage(for: stored.record.id, to: knowledgePackageDestination)
        XCTAssertEqual(viewModel.statusText, "Knowledge package exported")
        XCTAssertTrue(FileManager.default.fileExists(atPath: summaryDestination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dataDestination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: srtDestination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: vttDestination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: readinessDestination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: knowledgePackageDestination.appendingPathComponent("meeting.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: knowledgePackageDestination.appendingPathComponent("transcript.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: knowledgePackageDestination.appendingPathComponent("knowledge.md").path))
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
        try FileTranscriptRepository().saveCaptionDocument(summaryCaptionDocument([
            TranscriptSegment(id: "segment-1", text: "We decided to launch on May 1.", language: "en-US"),
            TranscriptSegment(id: "segment-2", text: "Alex will follow up with legal.", language: "en-US")
        ]), for: stored.record)
        let viewModel = MeetingAgentViewModel(
            store: store,
            speechLocaleIdentifier: "en-US",
            summaryProviderFactory: { _ in CapturingSummaryProvider(providerName: "openrouter:openai/gpt-4.1-mini") }
        )
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

    func testGenerateSummaryReplacesGenericMeetingNameWithGeneratedTitle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let stored = try store.createMeeting(
            name: "Google Chrome",
            startedAt: Date(timeIntervalSince1970: 1_777_000_000)
        )
        try FileTranscriptRepository().saveCaptionDocument(summaryCaptionDocument([
            TranscriptSegment(id: "segment-1", text: "We agreed to update renewal pricing next week.", language: "en-US")
        ]), for: stored.record)
        let viewModel = MeetingAgentViewModel(
            store: store,
            speechLocaleIdentifier: "en-US",
            summaryProviderFactory: { _ in CapturingSummaryProvider(providerName: "openrouter:openai/gpt-4.1-mini") },
            processTargetsProvider: { [] }
        )
        try viewModel.loadMeetings()

        try await viewModel.generateSummary(
            for: stored.record.id,
            generatedAt: Date(timeIntervalSince1970: 1_777_000_700)
        )

        let renamed = try XCTUnwrap(viewModel.meetings.first)
        let saved = try JSONDecoder.meetingAgent.decode(MeetingRecord.self, from: Data(contentsOf: store.metadataURL(for: stored.record.id)))
        XCTAssertEqual(renamed.name, "Update renewal pricing next week")
        XCTAssertEqual(saved.name, "Update renewal pricing next week")
    }

    func testGenerateSummaryPreservesUserAuthoredMeetingName() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let stored = try store.createMeeting(
            name: "Quarterly Launch Review",
            startedAt: Date(timeIntervalSince1970: 1_777_000_000)
        )
        try FileTranscriptRepository().saveCaptionDocument(summaryCaptionDocument([
            TranscriptSegment(id: "segment-1", text: "We agreed to update renewal pricing next week.", language: "en-US")
        ]), for: stored.record)
        let viewModel = MeetingAgentViewModel(
            store: store,
            speechLocaleIdentifier: "en-US",
            summaryProviderFactory: { _ in CapturingSummaryProvider(providerName: "openrouter:openai/gpt-4.1-mini") },
            processTargetsProvider: { [] }
        )
        try viewModel.loadMeetings()

        try await viewModel.generateSummary(
            for: stored.record.id,
            generatedAt: Date(timeIntervalSince1970: 1_777_000_700)
        )

        let preserved = try XCTUnwrap(viewModel.meetings.first)
        let saved = try JSONDecoder.meetingAgent.decode(MeetingRecord.self, from: Data(contentsOf: store.metadataURL(for: stored.record.id)))
        XCTAssertEqual(preserved.name, "Quarterly Launch Review")
        XCTAssertEqual(saved.name, "Quarterly Launch Review")
    }

    func testGenerateSummaryFiltersInterimSegmentsFromStructuredTranscript() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let provider = CapturingSummaryProvider(providerName: "test-summary")
        let stored = try store.createMeeting(
            name: "Summary interim filtering",
            startedAt: Date(timeIntervalSince1970: 100)
        )
        try FileTranscriptRepository().saveCaptionDocument(CaptionDocument(turns: [
            CaptionTurn(
                id: "draft",
                sections: [CaptionSection(text: "draft should not summarize")],
                state: .draft,
                source: CaptionTurnSource(providerID: "test")
            ),
            CaptionTurn(
                id: "final",
                sections: [CaptionSection(text: "final should summarize", utteranceIDs: ["final"])],
                state: .final,
                source: CaptionTurnSource(providerID: "test", utteranceIDs: ["final"])
            )
        ]), for: stored.record)
        let viewModel = MeetingAgentViewModel(
            store: store,
            speechLocaleIdentifier: "en-US",
            summaryProviderFactory: { _ in provider }
        )
        try viewModel.loadMeetings()

        try await viewModel.generateSummary(for: stored.record.id)

        XCTAssertEqual(provider.receivedInputs.last?.transcript.finalTurns.map(\.turnID), ["final"])
    }

    func testSelectingCompletedMeetingLoadsPersistedSummaryIntoMemoryWithoutProviderCall() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let provider = CapturingSummaryProvider(providerName: "test-summary")
        var stored = try store.createMeeting(
            name: "Completed Review",
            startedAt: Date(timeIntervalSince1970: 100)
        ).record
        stored.endedAt = Date(timeIntervalSince1970: 200)
        try store.save(stored)
        try FileTranscriptRepository().saveCaptionDocument(summaryCaptionDocument([
            TranscriptSegment(id: "segment-1", text: "We decided to launch.", language: "en-US")
        ]), for: stored)
        let summary = MeetingSummary(
            overview: "Persisted summary",
            keyTopics: [],
            decisions: [],
            actionItems: [],
            openQuestions: [],
            risks: [],
            followUps: [],
            language: "en-US",
            sourceSegmentIDs: ["segment-1"],
            generatedAt: Date(timeIntervalSince1970: 300),
            provider: "persisted",
            status: .succeeded,
            failureReason: nil
        )
        try FileSummaryRepository().saveSummary(summary, for: stored)
        let viewModel = MeetingAgentViewModel(
            store: store,
            summaryProviderFactory: { _ in provider },
            processTargetsProvider: { [] }
        )
        try viewModel.loadMeetings()

        viewModel.selectMeeting(stored.id)
        await viewModel.waitForSummaryIdleForTesting()

        XCTAssertEqual(viewModel.selectedMeetingSessionState?.transcript.consumptionView.finalTurns.map(\.turnID), ["segment-1"])
        XCTAssertEqual(viewModel.selectedMeetingSummary, summary)
        XCTAssertEqual(viewModel.selectedMeetingSessionState?.summary.source, .loadedFromPersistence)
        XCTAssertTrue(provider.receivedInputs.isEmpty)
    }

    func testSelectingCompletedMeetingWithoutSummaryGeneratesFromHydratedMemoryTranscript() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let provider = CapturingSummaryProvider(providerName: "test-summary")
        var stored = try store.createMeeting(
            name: "Completed Review",
            startedAt: Date(timeIntervalSince1970: 100)
        ).record
        stored.endedAt = Date(timeIntervalSince1970: 200)
        try store.save(stored)
        try FileTranscriptRepository().saveCaptionDocument(summaryCaptionDocument([
            TranscriptSegment(id: "segment-1", text: "We decided to launch.", language: "en-US")
        ]), for: stored)
        let viewModel = MeetingAgentViewModel(
            store: store,
            summaryProviderFactory: { _ in provider },
            processTargetsProvider: { [] }
        )
        try viewModel.loadMeetings()

        viewModel.selectMeeting(stored.id)
        await viewModel.waitForSummaryIdleForTesting()

        XCTAssertEqual(provider.receivedInputs.first?.transcript.finalTurns.map(\.turnID), ["segment-1"])
        XCTAssertEqual(viewModel.selectedMeetingSessionState?.summary.source, .generatedInSession)
        XCTAssertEqual(viewModel.selectedMeetingSummary?.overview, "We decided to launch.")
        XCTAssertEqual(try FileSummaryRepository().loadSummary(for: stored)?.overview, "We decided to launch.")
    }

    func testArtifactSnapshotUsesHydratedMemoryAfterTranscriptAndSummaryFilesAreRemoved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let provider = CapturingSummaryProvider(providerName: "test-summary")
        var stored = try store.createMeeting(
            name: "Completed Review",
            startedAt: Date(timeIntervalSince1970: 100)
        ).record
        stored.endedAt = Date(timeIntervalSince1970: 200)
        try store.save(stored)
        try FileTranscriptRepository().saveCaptionDocument(summaryCaptionDocument([
            TranscriptSegment(id: "segment-1", text: "We decided to launch.", language: "en-US")
        ]), for: stored)
        try FileSummaryRepository().saveSummary(MeetingSummary(
            overview: "Persisted summary",
            keyTopics: [],
            decisions: [],
            actionItems: [],
            openQuestions: [],
            risks: [],
            followUps: [],
            language: "en-US",
            sourceSegmentIDs: ["segment-1"],
            generatedAt: Date(timeIntervalSince1970: 300),
            provider: "persisted",
            status: .succeeded,
            failureReason: nil
        ), for: stored)
        let viewModel = MeetingAgentViewModel(
            store: store,
            summaryProviderFactory: { _ in provider },
            processTargetsProvider: { [] }
        )
        try viewModel.loadMeetings()
        viewModel.selectMeeting(stored.id)
        await viewModel.waitForSummaryIdleForTesting()
        try FileManager.default.removeItem(at: XCTUnwrap(stored.transcriptJSONURL))
        try FileManager.default.removeItem(at: XCTUnwrap(stored.summaryJSONURL))

        try await viewModel.generateSummary(for: stored.id, generatedAt: Date(timeIntervalSince1970: 400))

        XCTAssertEqual(viewModel.selectedMeetingArtifactSnapshot?.transcriptSegments.map(\.text), ["We decided to launch."])
        XCTAssertEqual(viewModel.selectedMeetingArtifactSnapshot?.summary?.overview, "We decided to launch.")
        XCTAssertEqual(provider.receivedInputs.first?.transcript.finalTurns.map(\.turnID), ["segment-1"])
    }

    func testExportsUseHydratedMemoryAfterTranscriptAndSummaryFilesAreRemoved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        var stored = try store.createMeeting(
            name: "Completed Review",
            startedAt: Date(timeIntervalSince1970: 100)
        ).record
        stored.endedAt = Date(timeIntervalSince1970: 200)
        try store.save(stored)
        try FileTranscriptRepository().saveCaptionDocument(summaryCaptionDocument([
            TranscriptSegment(
                id: "segment-1",
                startTimeSeconds: 1,
                endTimeSeconds: 3,
                text: "We decided to launch.",
                language: "en-US"
            )
        ]), for: stored)
        try FileSummaryRepository().saveSummary(MeetingSummary(
            overview: "Persisted summary",
            keyTopics: [],
            decisions: [],
            actionItems: [],
            openQuestions: [],
            risks: [],
            followUps: [],
            language: "en-US",
            sourceSegmentIDs: ["segment-1"],
            generatedAt: Date(timeIntervalSince1970: 300),
            provider: "persisted",
            status: .succeeded,
            failureReason: nil
        ), for: stored)
        let viewModel = MeetingAgentViewModel(store: store, processTargetsProvider: { [] })
        try viewModel.loadMeetings()
        viewModel.selectMeeting(stored.id)
        await viewModel.waitForSummaryIdleForTesting()
        try FileManager.default.removeItem(at: XCTUnwrap(stored.transcriptJSONURL))
        try FileManager.default.removeItem(at: XCTUnwrap(stored.summaryJSONURL))
        try FileManager.default.removeItem(at: XCTUnwrap(stored.summaryMarkdownURL))

        let transcriptDestination = root.appendingPathComponent("export-transcript.txt")
        let summaryDestination = root.appendingPathComponent("export-summary.md")
        let srtDestination = root.appendingPathComponent("export.srt")
        let knowledgeDestination = root.appendingPathComponent("knowledge", isDirectory: true)
        try viewModel.exportTranscript(for: stored.id, to: transcriptDestination)
        try viewModel.exportSummary(for: stored.id, to: summaryDestination)
        try viewModel.exportSubtitles(for: stored.id, format: .srt, to: srtDestination)
        try viewModel.exportKnowledgePackage(for: stored.id, to: knowledgeDestination)

        XCTAssertTrue(try String(contentsOf: transcriptDestination, encoding: .utf8).contains("We decided to launch."))
        XCTAssertTrue(try String(contentsOf: summaryDestination, encoding: .utf8).contains("Persisted summary"))
        XCTAssertTrue(try String(contentsOf: srtDestination, encoding: .utf8).contains("We decided to launch."))
        XCTAssertTrue(try String(contentsOf: knowledgeDestination.appendingPathComponent("transcript.md"), encoding: .utf8).contains("We decided to launch."))
    }

    func testGenerateSummaryUsesConfiguredSummaryModelIndependentlyFromTranslationModel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let stored = try store.createMeeting(
            name: "Launch Review",
            startedAt: Date(timeIntervalSince1970: 1_777_000_000)
        )
        try FileTranscriptRepository().saveCaptionDocument(summaryCaptionDocument([
            TranscriptSegment(id: "segment-1", text: "We decided to launch on May 1.", language: "en-US")
        ]), for: stored.record)
        let configuration = SpeechTranscriptionConfiguration(
            provider: .whisper,
            localeIdentifier: "en-US",
            whisperBinaryPath: nil,
            whisperModelPath: nil,
            translationExecutionMode: .hosted,
            hostedTranslationProviderID: "openrouter-translation",
            hostedTranslationModelID: "google/gemini-2.5-flash",
            hostedSummaryModelID: "openai/gpt-4.1-mini",
            openRouterAPIKey: "test-key"
        )
        let viewModel = MeetingAgentViewModel(
            store: store,
            speechConfiguration: configuration,
            summaryProviderFactory: { configuration in
                CapturingSummaryProvider(providerName: "openrouter:\(configuration.hostedSummaryModelID)")
            },
            processTargetsProvider: { [] }
        )
        try viewModel.loadMeetings()

        try await viewModel.generateSummary(
            for: stored.record.id,
            generatedAt: Date(timeIntervalSince1970: 1_777_000_700)
        )

        let summary = try MeetingSummaryWriter.read(from: stored.record.summaryJSONURL!)
        XCTAssertEqual(summary.status, .succeeded)
        XCTAssertEqual(summary.provider, "openrouter:openai/gpt-4.1-mini")
    }

    func testGenerateSummaryUsesConfiguredTargetLanguage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let stored = try store.createMeeting(
            name: "Launch Review",
            startedAt: Date(timeIntervalSince1970: 1_777_000_000)
        )
        try FileTranscriptRepository().saveCaptionDocument(summaryCaptionDocument([
            TranscriptSegment(id: "segment-1", text: "We decided to launch on May 1.", language: "en-US")
        ]), for: stored.record)
        let provider = CapturingSummaryProvider(providerName: "openrouter:openai/gpt-4.1-mini")
        let configuration = SpeechTranscriptionConfiguration(
            provider: .whisper,
            localeIdentifier: "en-US",
            whisperBinaryPath: nil,
            whisperModelPath: nil,
            hostedSummaryModelID: "openai/gpt-4.1-mini",
            openRouterAPIKey: "test-key"
        )
        let viewModel = MeetingAgentViewModel(
            store: store,
            speechConfiguration: configuration,
            summaryProviderFactory: { _ in provider },
            processTargetsProvider: { [] }
        )
        try viewModel.loadMeetings()

        try await viewModel.generateSummary(for: stored.record.id)

        XCTAssertEqual(provider.receivedInputs.first?.language, "en-US")
        XCTAssertEqual(provider.receivedInputs.first?.targetLanguage, "en-US")
    }

    func testDefaultSummaryProviderUsesSettingsBackedOpenRouterModel() {
        let configuration = SpeechTranscriptionConfiguration(
            provider: .whisper,
            localeIdentifier: "en-US",
            whisperBinaryPath: nil,
            whisperModelPath: nil,
            hostedSummaryModelID: "openai/gpt-4.1-mini",
            openRouterAPIKey: "test-key"
        )

        let provider = MeetingAgentViewModel.summaryProvider(for: configuration, environment: [:])

        XCTAssertEqual(provider.providerName, "openrouter:openai/gpt-4.1-mini")
    }

    func testDefaultSummaryProviderIgnoresLegacyExtractiveEnvironmentSelection() {
        let configuration = SpeechTranscriptionConfiguration(
            provider: .whisper,
            localeIdentifier: "en-US",
            whisperBinaryPath: nil,
            whisperModelPath: nil,
            hostedSummaryModelID: "google/gemini-2.5-flash",
            openRouterAPIKey: "test-key"
        )

        let provider = MeetingAgentViewModel.summaryProvider(
            for: configuration,
            environment: ["MEETING_AGENT_SUMMARY_PROVIDER": "extractive-local"]
        )

        XCTAssertEqual(provider.providerName, "openrouter:google/gemini-2.5-flash")
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
        try FileTranscriptRepository().saveCaptionDocument(summaryCaptionDocument([
            TranscriptSegment(id: "blank", text: "   ")
        ]), for: stored.record)
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
        try FileTranscriptRepository().saveCaptionDocument(summaryCaptionDocument([
            TranscriptSegment(id: "segment-1", text: "We decided to launch.", language: "en-US")
        ]), for: stored)
        let viewModel = MeetingAgentViewModel(
            store: store,
            summaryProviderFactory: { _ in CapturingSummaryProvider(providerName: "openrouter:openai/gpt-4.1-mini") },
            processTargetsProvider: { [] }
        )
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
        XCTAssertEqual(try configurationStore.load(), expectedConfiguration)
        XCTAssertEqual(viewModel.statusText, "Settings saved")
    }

    func testViewModelLoadsPersistedCredentialsFromUserDefaultsAndReportsPrimaryChainPreflight() throws {
        let suiteName = "meeting-vm-settings-credentials-\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let configurationStore = SpeechTranscriptionConfigurationStore(userDefaults: userDefaults)
        var persistedConfiguration = SpeechTranscriptionConfiguration.default
        persistedConfiguration.deepgramAPIKey = "deepgram-key"
        persistedConfiguration.openRouterAPIKey = "openrouter-key"
        try configurationStore.save(persistedConfiguration)

        let viewModel = MeetingAgentViewModel(
            speechConfigurationStore: configurationStore,
            processTargetsProvider: { [] }
        )

        XCTAssertEqual(viewModel.speechConfiguration.deepgramAPIKey, "deepgram-key")
        XCTAssertEqual(viewModel.speechConfiguration.openRouterAPIKey, "openrouter-key")
        XCTAssertEqual(viewModel.primaryChainPreflightResult.status, .available)
        XCTAssertEqual(viewModel.primaryChainPreflightSummary, "Primary chain ready")
    }

    func testOpenRouterCaptionTranslationProviderIsDisabled() {
        var configuration = SpeechTranscriptionConfiguration.default
        configuration.translationExecutionMode = .hosted
        configuration.hostedTranslationProviderID = SpeechTranscriptionConfiguration.defaultHostedTranslationProviderID
        configuration.hostedTranslationModelID = "openai/gpt-4.1-mini"
        configuration.openRouterAPIKey = "openrouter-key"

        XCTAssertNil(MeetingAgentViewModel.openRouterCaptionTranslationProvider(for: configuration))
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
            "zh-Hans",
            "zh-TW",
            "ja-JP",
            "ko-KR",
            "fr-FR",
            "de-DE",
            "es-ES"
        ])
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

    func testInvalidateDownstreamArtifactsAfterTranscriptChangeRemovesProgressSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let stored = try store.createMeeting(name: "Google Meet", startedAt: Date(timeIntervalSince1970: 100)).record
        let progressURL = try XCTUnwrap(stored.meetingProgressJSONURL)
        try Data("{}".utf8).write(to: progressURL)
        let viewModel = MeetingAgentViewModel(store: store, processTargetsProvider: { [] })
        try viewModel.loadMeetings()

        await viewModel.invalidateDownstreamArtifactsAfterTranscriptChange(for: stored.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: progressURL.path))
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

    func testSaveAgendaNormalizesAndPersistsEditableMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let stored = try store.createMeeting(name: "Draft", startedAt: Date(timeIntervalSince1970: 100)).record
        let viewModel = MeetingAgentViewModel(store: store, processTargetsProvider: { [] })
        try viewModel.loadMeetings()

        try viewModel.saveAgenda(
            for: stored.id,
            update: MeetingAgendaUpdate(
                name: "  APAC\nlaunch sync  ",
                attendees: [
                    MeetingAttendee(name: "  Li\nWei  ", role: "  Shanghai GM  "),
                    MeetingAttendee(name: "   ", role: "Ignored")
                ],
                agendaTopics: [
                    MeetingAgendaTopic(title: "  Launch\nrisks "),
                    MeetingAgendaTopic(title: "")
                ],
                scheduledStartAt: Date(timeIntervalSince1970: 500),
                scheduledEndAt: Date(timeIntervalSince1970: 800),
                meetingGoal: MeetingGoal(
                    title: " Align on rollout ",
                    objectives: [],
                    requiredQuestions: [],
                    expectedDecisions: [],
                    keyTerms: []
                ),
                meetingGoals: [
                    MeetingGoal(
                        title: " Align on rollout ",
                        objectives: [],
                        requiredQuestions: [],
                        expectedDecisions: [],
                        keyTerms: []
                    ),
                    MeetingGoal(
                        title: " Confirm launch owner ",
                        objectives: [],
                        requiredQuestions: [],
                        expectedDecisions: [],
                        keyTerms: []
                    ),
                    MeetingGoal(
                        title: "   ",
                        objectives: [],
                        requiredQuestions: [],
                        expectedDecisions: [],
                        keyTerms: []
                    )
                ]
            )
        )

        let saved = try XCTUnwrap(viewModel.selectedMeeting)
        let loaded = try XCTUnwrap(try store.loadMeetings().first)
        XCTAssertEqual(saved.name, "APAC launch sync")
        XCTAssertEqual(saved.attendees.map(\.name), ["Li Wei"])
        XCTAssertEqual(saved.attendees.map(\.role), ["Shanghai GM"])
        XCTAssertEqual(saved.agendaTopics.map(\.title), ["Launch risks"])
        XCTAssertEqual(saved.scheduledStartAt, Date(timeIntervalSince1970: 500))
        XCTAssertEqual(saved.scheduledEndAt, Date(timeIntervalSince1970: 800))
        XCTAssertEqual(saved.meetingGoal?.title, "Align on rollout")
        XCTAssertEqual(saved.meetingGoals.map(\.title), ["Align on rollout", "Confirm launch owner"])
        XCTAssertEqual(loaded.meetingGoals.map(\.title), ["Align on rollout", "Confirm launch owner"])
        XCTAssertEqual(loaded.meetingGoal?.title, "Align on rollout")
        XCTAssertEqual(loaded, saved)
    }

    func testCreateAgendaMeetingPersistsLocalEditableAgendaItem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let viewModel = MeetingAgentViewModel(store: store, processTargetsProvider: { [] })
        let scheduledStartAt = Date(timeIntervalSince1970: 1_777_000_000)

        let created = try viewModel.createAgendaMeeting(
            name: "  APAC\nlaunch sync  ",
            scheduledStartAt: scheduledStartAt
        )

        XCTAssertEqual(created.name, "APAC launch sync")
        XCTAssertEqual(created.scheduledStartAt, scheduledStartAt)
        XCTAssertEqual(viewModel.meetings.map(\.id), [created.id])
        XCTAssertEqual(viewModel.selectedMeetingID, created.id)
        XCTAssertEqual(try store.loadMeetings().first?.id, created.id)
    }

    func testStartRecordingForExistingAgendaRecordKeepsMeetingIdentity() async throws {
        let fixture = try ViewModelRecorderFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var stored = try fixture.store.createMeeting(
            id: UUID(uuidString: "34343434-3434-3434-3434-343434343434")!,
            name: "APAC launch sync",
            startedAt: Date(timeIntervalSince1970: 100)
        ).record
        stored.attendees = [MeetingAttendee(name: "Li Wei")]
        try fixture.store.save(stored)
        let target = AudioCaptureTarget(processID: 42, displayName: "Google Meet", bundleIdentifier: "com.google.Chrome")
        let viewModel = MeetingAgentViewModel(
            store: fixture.store,
            recorder: fixture.recorder,
            processTargetsProvider: { [target] }
        )
        try viewModel.loadMeetings()

        try await viewModel.startRecording(for: target, meetingID: stored.id)

        XCTAssertEqual(viewModel.meetings.count, 1)
        XCTAssertEqual(viewModel.selectedMeeting?.id, stored.id)
        XCTAssertEqual(viewModel.activeMeetingID, stored.id)
        XCTAssertEqual(viewModel.selectedMeeting?.attendees.first?.name, "Li Wei")
        XCTAssertEqual(fixture.session.startedTargets, [target])
        XCTAssertEqual(try fixture.store.loadMeetings().count, 1)
    }

    private func waitFor(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: () -> Bool
    ) async throws {
        let interval: UInt64 = 10_000_000
        let attempts = max(1, Int(timeoutNanoseconds / interval))
        for _ in 0..<attempts {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: interval)
        }
        XCTAssertTrue(condition(), "Timed out waiting for condition", file: file, line: line)
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
    var startedSources: [AudioCaptureSource] = []
    var startedTargets: [AudioCaptureTarget] = []
    var stopCallCount = 0

    init(sampleRate: Double, channelCount: Int) {
        outputSampleRate = sampleRate
        outputChannelCount = channelCount
    }

    func start(source: AudioCaptureSource) throws {
        if let startError {
            throw startError
        }
        startedSources.append(source)
        if let target = source.processTarget {
            startedTargets.append(target)
        }
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

private func summaryCaptionDocument(_ segments: [TranscriptSegment]) -> CaptionDocument {
    CaptionDocument(
        turns: segments.map { segment in
            CaptionTurn(
                id: segment.id,
                speakerID: segment.speakerID,
                speakerLabel: segment.speakerLabel,
                startTimeSeconds: segment.startTimeSeconds,
                endTimeSeconds: segment.endTimeSeconds,
                sections: [
                    CaptionSection(
                        id: "\(segment.id)-section",
                        text: segment.text,
                        utteranceIDs: [segment.id],
                        startTimeSeconds: segment.startTimeSeconds,
                        endTimeSeconds: segment.endTimeSeconds
                    )
                ],
                state: segment.isFinal ? .final : .draft,
                source: CaptionTurnSource(
                    providerID: segment.sourceProvider,
                    utteranceIDs: [segment.id]
                ),
                createdAt: segment.createdAt,
                updatedAt: segment.createdAt
            )
        },
        provider: segments.compactMap(\.language).first.map {
            CaptionProviderInfo(id: "test", locale: $0)
        }
    )
}

private final class ViewModelFakeAudioFrameWriter: AudioFrameWriting {
    func append(_ frame: AudioFrame) throws {}
    func close() throws {}
}

private final class ViewModelFakeAudioFrameTranscriber: AudioFrameTranscriber {
    var transcriptUpdateSink: TranscriptUpdateSink?

    func append(_ frame: AudioFrame) throws {}
    func finish() {}

    func emit(_ update: TranscriptSegmentUpdate) {
        transcriptUpdateSink?.receive(update)
    }
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
        channelCount: Int,
        performanceEventLogger: PerformanceEventLogger?,
        transcriptUpdateSink: TranscriptUpdateSink?
    ) async throws -> AudioFrameTranscriber {
        requests.append(Request(localeIdentifier: configuration.localeIdentifier))
        transcriber.transcriptUpdateSink = transcriptUpdateSink
        return transcriber
    }
}

private final class ViewModelFakeTextTranslationProvider: TextTranslationProvider {
    struct Request: Equatable {
        let sourceLocale: String
        let targetLocale: String
        let segmentIDs: [String]
    }

    var requests: [Request] = []
    var requestedSegmentTexts: [[String]] = []
    var translations: [String: String]
    private let delayNanoseconds: UInt64

    init(translations: [String: String], delayNanoseconds: UInt64 = 0) {
        self.translations = translations
        self.delayNanoseconds = delayNanoseconds
    }

    let descriptor = ProviderDescriptor(
        id: "fake-view-model-translation",
        displayName: "Fake View Model Translation",
        capability: .textTranslation,
        executionMode: .hosted,
        supportedSourceLocales: ["*"],
        supportedTargetLocales: ["*"],
        requiresNetwork: false,
        requiresAPIKey: false
    )

    func translate(transcript: TranscriptDocument, options: TranslationOptions) async throws -> TranslatedTranscript {
        requests.append(Request(
            sourceLocale: options.sourceLocale,
            targetLocale: options.targetLocale,
            segmentIDs: transcript.segments.map(\.id)
        ))
        requestedSegmentTexts.append(transcript.segments.map(\.text))
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return TranslatedTranscript(
            sourceLocale: options.sourceLocale,
            targetLocale: options.targetLocale,
            segments: transcript.segments.map { segment in
                BilingualSubtitleSegment(
                    id: segment.id,
                    speaker: segment.speaker,
                    sourceText: segment.text,
                    targetText: translations[segment.id] ?? "",
                    status: .complete,
                    providerChain: [descriptor.id]
                )
            },
            provenance: PipelineProvenance(profileID: "fake-view-model-translation")
        )
    }
}

private final class FailingViewModelTextTranslationProvider: TextTranslationProvider {
    let error: Error

    init(error: Error) {
        self.error = error
    }

    let descriptor = ProviderDescriptor(
        id: "failing-view-model-translation",
        displayName: "Failing View Model Translation",
        capability: .textTranslation,
        executionMode: .hosted,
        supportedSourceLocales: ["*"],
        supportedTargetLocales: ["*"],
        requiresNetwork: false,
        requiresAPIKey: false
    )

    func translate(transcript: TranscriptDocument, options: TranslationOptions) async throws -> TranslatedTranscript {
        throw error
    }
}

private final class DelayedViewModelFakeTextTranslationProvider: TextTranslationProvider {
    struct PendingRequest {
        let transcript: TranscriptDocument
        let continuation: CheckedContinuation<TranslatedTranscript, Error>
    }

    let descriptor = ProviderDescriptor(
        id: "delayed-view-model-translation",
        displayName: "Delayed Translation",
        capability: .textTranslation,
        executionMode: .hosted,
        supportedSourceLocales: ["*"],
        supportedTargetLocales: ["*"],
        requiresNetwork: false,
        requiresAPIKey: false
    )

    private(set) var pendingRequests: [PendingRequest] = []

    var pendingRequestCount: Int {
        pendingRequests.count
    }

    var pendingRequestTexts: [[String]] {
        pendingRequests.map { $0.transcript.segments.map(\.text) }
    }

    func translate(transcript: TranscriptDocument, options: TranslationOptions) async throws -> TranslatedTranscript {
        try await withCheckedThrowingContinuation { continuation in
            pendingRequests.append(PendingRequest(transcript: transcript, continuation: continuation))
        }
    }

    func completeRequest(at index: Int, targetText: String) {
        let request = pendingRequests[index]
        let source = request.transcript.segments[0]
        request.continuation.resume(returning: TranslatedTranscript(
            sourceLocale: source.language ?? "en-US",
            targetLocale: "zh-CN",
            segments: [
                BilingualSubtitleSegment(
                    id: source.id,
                    startTimeSeconds: source.startTimeSeconds,
                    endTimeSeconds: source.endTimeSeconds,
                    speaker: source.speaker,
                    sourceText: source.text,
                    targetText: targetText,
                    confidence: source.confidence,
                    providerChain: ["delayed-view-model-translation"]
                )
            ],
            provenance: PipelineProvenance(profileID: "delayed-view-model-translation")
        ))
    }
}

private final class CapturingSummaryProvider: MeetingSummaryProvider {
    let providerName: String
    private(set) var receivedInputs: [MeetingSummaryInput] = []

    init(providerName: String) {
        self.providerName = providerName
    }

    func generateSummary(input: MeetingSummaryInput) async throws -> MeetingSummary {
        receivedInputs.append(input)
        let usableTurns = input.transcript.finalTurns.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let decisions = usableTurns
            .filter { $0.text.lowercased().contains("decided") || $0.text.lowercased().contains("agreed") }
            .map {
                MeetingDecision(
                    description: $0.text,
                    participants: [],
                    sourceSegmentIDs: $0.sourceIDs.isEmpty ? [$0.turnID] : $0.sourceIDs,
                    confidence: 0.8
                )
            }
        let actionItems = usableTurns
            .filter { $0.text.lowercased().contains("follow up") || $0.text.lowercased().contains("will") }
            .map {
                MeetingActionItem(
                    description: $0.text,
                    owner: nil,
                    dueDate: nil,
                    sourceSegmentIDs: $0.sourceIDs.isEmpty ? [$0.turnID] : $0.sourceIDs,
                    confidence: 0.8
                )
            }
        let overview = usableTurns.map(\.text).joined(separator: " ")
        return MeetingSummary(
            autoGeneratedTitle: MeetingSummaryTitleGenerator.title(
                meetingName: input.meetingName,
                keyTopics: [],
                overview: overview,
                transcriptTurns: input.transcript.finalTurns
            ),
            overview: overview,
            keyTopics: [],
            decisions: decisions,
            actionItems: actionItems,
            openQuestions: [],
            risks: [],
            followUps: actionItems.map(\.description),
            language: input.language,
            sourceSegmentIDs: usableTurns.flatMap { $0.sourceIDs.isEmpty ? [$0.turnID] : $0.sourceIDs },
            generatedAt: input.generatedAt,
            provider: providerName,
            status: .succeeded,
            failureReason: nil
        )
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

private func readPerformanceEvents(from url: URL) throws -> [PerformanceEvent] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    return try String(contentsOf: url, encoding: .utf8)
        .split(separator: "\n")
        .map { line in
            try JSONDecoder.meetingAgent.decode(PerformanceEvent.self, from: Data(line.utf8))
        }
}

final class AppRuntimeCapabilitiesTests: XCTestCase {
    func testUserNotificationsRequireAppBundleRuntime() {
        XCTAssertTrue(AppRuntimeCapabilities.supportsUserNotifications(bundleURL: URL(fileURLWithPath: "/Applications/MeetingAgent.app")))
        XCTAssertFalse(AppRuntimeCapabilities.supportsUserNotifications(bundleURL: URL(fileURLWithPath: "/tmp/meeting-agent/.build/debug")))
    }
}
