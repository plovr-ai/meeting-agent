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

    func testStoppingRecordingFreezesOpenDraftCaptionForFinalTranslation() async throws {
        let fixture = try ViewModelRecorderFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let target = AudioCaptureTarget(processID: 42, displayName: "Meet", bundleIdentifier: nil)
        let provider = ViewModelFakeTextTranslationProvider(translations: ["segment-1": "最终翻译"])
        let viewModel = MeetingAgentViewModel(
            store: fixture.store,
            recorder: fixture.recorder,
            captionTranslationProviderFactory: { _ in provider },
            processTargetsProvider: { [target] }
        )

        try await viewModel.startRecording(for: target)
        let record = try XCTUnwrap(viewModel.selectedMeeting)
        let writer = try TranscriptFileWriter(url: XCTUnwrap(record.transcriptURL), structuredURL: XCTUnwrap(record.transcriptJSONURL))
        try writer.replace(with: [
            TranscriptSegment(id: "segment-1", speaker: TranscriptSpeaker(identifier: "speaker-1"), text: "unfinished thought", language: "en-US")
        ])

        viewModel.drainRecordingFrames()
        XCTAssertEqual(viewModel.liveCaptionTurns.first?.chunkState, .draft)

        viewModel.stopRecording()

        XCTAssertEqual(viewModel.liveCaptionTurns.first?.chunkState, .frozen)
        XCTAssertEqual(viewModel.liveCaptionTurns.first?.freezeReason, .manualStop)
        try await waitFor {
            viewModel.liveCaptionTurns.first?.translatedText == "最终翻译"
                && viewModel.liveCaptionTurns.first?.translationHealth == .live
        }
        XCTAssertGreaterThanOrEqual(provider.requests.count, 1)
        XCTAssertEqual(provider.requestedSegmentTexts.last, ["unfinished thought"])
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

    func testStopRecordingAndGenerateSummaryWritesArtifacts() async throws {
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

    func testGenerateSummaryUsesMatchingMeetingProgressSnapshot() async throws {
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
        let transcriptWriter = try TranscriptFileWriter(url: XCTUnwrap(stored.transcriptURL))
        try transcriptWriter.replace(with: [
            TranscriptSegment(id: "segment-1", text: "Alex is the launch owner.", language: "en-US")
        ])
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
        let viewModel = MeetingAgentViewModel(store: store, speechLocaleIdentifier: "en-US", processTargetsProvider: { [] })
        try viewModel.loadMeetings()

        try await viewModel.generateSummary(for: stored.id, generatedAt: Date(timeIntervalSince1970: 300))

        let summary = try MeetingSummaryWriter.read(from: XCTUnwrap(stored.summaryJSONURL))
        XCTAssertEqual(summary.provider, "goal-oriented-deterministic")
        XCTAssertEqual(summary.overview, "Goal: Confirm launch plan. Current status: on track.")
        XCTAssertEqual(summary.decisions.first?.description, "Confirm launch owner")
        XCTAssertEqual(summary.followUps, ["Have we confirmed the deadline?"])
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

    func testDrainRecordingFramesRefreshesLiveCaptionTurnsFromStructuredTranscript() async throws {
        let fixture = try ViewModelRecorderFixture()
        let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
        var translationFactoryCallCount = 0
        let viewModel = MeetingAgentViewModel(
            store: fixture.store,
            recorder: fixture.recorder,
            speechConfiguration: SpeechTranscriptionConfiguration(
                provider: .local,
                localeIdentifier: "en-US",
                targetLocaleIdentifier: "zh-CN",
                whisperBinaryPath: nil,
                whisperModelPath: nil
            ),
            captionTranslationProviderFactory: { _ in
                translationFactoryCallCount += 1
                return nil
            },
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

        XCTAssertEqual(viewModel.liveCaptionTurns.map(\.sourceSegmentID), ["segment-1", "partial"])
        XCTAssertEqual(viewModel.liveCaptionTurns.first?.originalText, "Confirm launch owner.")
        XCTAssertEqual(viewModel.liveCaptionTurns.last?.originalText, "partial")
        XCTAssertEqual(viewModel.liveCaptionTurns.last?.isFinal, false)
        XCTAssertEqual(viewModel.liveCaptionTurns.last?.translationHealth, .pending)
        XCTAssertEqual(viewModel.liveCaptionTurns.first?.targetLocale, "zh-CN")
        XCTAssertEqual(translationFactoryCallCount, 1)
    }

    func testDrainRecordingFramesTranslatesFinalCaptionsWithConfiguredOpenRouterModel() async throws {
        let fixture = try ViewModelRecorderFixture()
        let provider = ViewModelFakeTextTranslationProvider(translations: ["segment-1": "Alex 是上线负责人。"])
        let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
        var requestedModels: [String] = []
        let viewModel = MeetingAgentViewModel(
            store: fixture.store,
            recorder: fixture.recorder,
            speechConfiguration: SpeechTranscriptionConfiguration(
                provider: .whisper,
                localeIdentifier: "en-US",
                targetLocaleIdentifier: "zh-CN",
                whisperBinaryPath: nil,
                whisperModelPath: nil,
                transcriptionExecutionMode: .hosted,
                translationExecutionMode: .hosted,
                hostedTranscriptionProviderID: "deepgram-transcribe",
                hostedTranslationProviderID: "openrouter-translation",
                hostedTranslationModelID: "google/gemini-2.5-flash",
                openRouterAPIKey: "settings-openrouter-key",
                deepgramAPIKey: "settings-deepgram-key"
            ),
            captionTranslationProviderFactory: { configuration in
                requestedModels.append(configuration.hostedTranslationModelID)
                return provider
            },
            processTargetsProvider: { [target] }
        )
        try await viewModel.startRecording(for: target)
        let record = try XCTUnwrap(viewModel.meetings.first)
        let transcriptWriter = try TranscriptFileWriter(url: XCTUnwrap(record.transcriptURL))
        try transcriptWriter.replace(with: [
            TranscriptSegment(
                id: "segment-1",
                speaker: TranscriptSpeaker(identifier: "speaker-1", label: "Alex"),
                text: "Alex is the launch owner.",
                language: "en-US",
                isFinal: true
            )
        ])

        viewModel.drainRecordingFrames()
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(requestedModels, ["google/gemini-2.5-flash"])
        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertEqual(provider.requests.first?.sourceLocale, "en-US")
        XCTAssertEqual(provider.requests.first?.targetLocale, "zh-CN")
        XCTAssertEqual(provider.requests.first?.segmentIDs, ["segment-1"])
        XCTAssertEqual(viewModel.liveCaptionTurns.first?.translatedText, "Alex 是上线负责人。")
        XCTAssertEqual(viewModel.liveCaptionTurns.first?.translationHealth, .live)
        XCTAssertEqual(viewModel.meetingProgressHealth.translation, .live)

        viewModel.drainRecordingFrames()
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(requestedModels, ["google/gemini-2.5-flash"])
        XCTAssertEqual(provider.requests.count, 1)
    }

    func testDrainRecordingFramesSkipsCaptionTranslationWhenSourceAndTargetLanguagesMatch() async throws {
        let fixture = try ViewModelRecorderFixture()
        var providerFactoryCallCount = 0
        let provider = ViewModelFakeTextTranslationProvider(translations: ["segment-1": "translated"])
        let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
        let viewModel = MeetingAgentViewModel(
            store: fixture.store,
            recorder: fixture.recorder,
            speechConfiguration: SpeechTranscriptionConfiguration(
                provider: .whisper,
                localeIdentifier: "en-US",
                targetLocaleIdentifier: "en-GB",
                whisperBinaryPath: nil,
                whisperModelPath: nil,
                transcriptionExecutionMode: .hosted,
                translationExecutionMode: .hosted,
                hostedTranscriptionProviderID: "deepgram-transcribe",
                hostedTranslationProviderID: "openrouter-translation",
                openRouterAPIKey: "settings-openrouter-key",
                deepgramAPIKey: "settings-deepgram-key"
            ),
            captionTranslationProviderFactory: { _ in
                providerFactoryCallCount += 1
                return provider
            },
            processTargetsProvider: { [target] }
        )
        try await viewModel.startRecording(for: target)
        let record = try XCTUnwrap(viewModel.meetings.first)
        let transcriptWriter = try TranscriptFileWriter(url: XCTUnwrap(record.transcriptURL))
        try transcriptWriter.replace(with: [
            TranscriptSegment(id: "segment-1", text: "Alex is the launch owner.", language: "en-US", isFinal: true)
        ])

        viewModel.drainRecordingFrames()
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(providerFactoryCallCount, 0)
        XCTAssertEqual(provider.requests.count, 0)
        XCTAssertNil(viewModel.liveCaptionTurns.first?.translatedText)
        XCTAssertEqual(viewModel.liveCaptionTurns.first?.translationHealth, .live)
        XCTAssertEqual(viewModel.meetingProgressHealth.translation, .live)
    }

    func testDrainRecordingFramesSkipsCaptionTranslationWhenDetectedLanguageMatchesMainLanguage() async throws {
        let fixture = try ViewModelRecorderFixture()
        var providerFactoryCallCount = 0
        let provider = ViewModelFakeTextTranslationProvider(translations: ["segment-1": "translated"])
        let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
        let viewModel = MeetingAgentViewModel(
            store: fixture.store,
            recorder: fixture.recorder,
            speechConfiguration: SpeechTranscriptionConfiguration(
                provider: .whisper,
                localeIdentifier: "en-US",
                targetLocaleIdentifier: "ja-JP",
                whisperBinaryPath: nil,
                whisperModelPath: nil,
                transcriptionExecutionMode: .hosted,
                translationExecutionMode: .hosted,
                hostedTranscriptionProviderID: "deepgram-transcribe",
                hostedTranslationProviderID: "openrouter-translation",
                openRouterAPIKey: "settings-openrouter-key",
                deepgramAPIKey: "settings-deepgram-key"
            ),
            captionTranslationProviderFactory: { _ in
                providerFactoryCallCount += 1
                return provider
            },
            processTargetsProvider: { [target] }
        )
        try await viewModel.startRecording(for: target)
        let record = try XCTUnwrap(viewModel.meetings.first)
        let transcriptWriter = try TranscriptFileWriter(url: XCTUnwrap(record.transcriptURL))
        try transcriptWriter.replace(with: [
            TranscriptSegment(id: "segment-1", text: "開始しましょう。", language: "ja", isFinal: true)
        ])

        viewModel.drainRecordingFrames()
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(providerFactoryCallCount, 0)
        XCTAssertEqual(provider.requests.count, 0)
        XCTAssertEqual(viewModel.liveCaptionTurns.first?.sourceLocale, "ja")
        XCTAssertEqual(viewModel.liveCaptionTurns.first?.targetLocale, "ja-JP")
        XCTAssertNil(viewModel.liveCaptionTurns.first?.translatedText)
        XCTAssertEqual(viewModel.liveCaptionTurns.first?.translationHealth, .live)
        XCTAssertEqual(viewModel.meetingProgressHealth.translation, .live)
    }

    func testExpandingTranslatedCaptionKeepsVisibleTranslationUntilFullTurnTranslationCompletes() async throws {
        let fixture = try ViewModelRecorderFixture()
        let speaker = TranscriptSpeaker(identifier: "speaker-1", label: "Alex")
        let provider = ViewModelFakeTextTranslationProvider(
            translations: [
                "segment-1": "第一句",
                "segment-2": "第一句 第二句"
            ],
            delayNanoseconds: 50_000_000
        )
        let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
        let viewModel = MeetingAgentViewModel(
            store: fixture.store,
            recorder: fixture.recorder,
            speechConfiguration: SpeechTranscriptionConfiguration(
                provider: .whisper,
                localeIdentifier: "en-US",
                targetLocaleIdentifier: "zh-CN",
                whisperBinaryPath: nil,
                whisperModelPath: nil,
                transcriptionExecutionMode: .hosted,
                translationExecutionMode: .hosted,
                hostedTranscriptionProviderID: "deepgram-transcribe",
                hostedTranslationProviderID: "openrouter-translation",
                openRouterAPIKey: "settings-openrouter-key",
                deepgramAPIKey: "settings-deepgram-key"
            ),
            captionTranslationProviderFactory: { _ in provider },
            processTargetsProvider: { [target] }
        )
        try await viewModel.startRecording(for: target)
        let record = try XCTUnwrap(viewModel.meetings.first)
        let transcriptWriter = try TranscriptFileWriter(url: XCTUnwrap(record.transcriptURL))
        try transcriptWriter.replace(with: [
            TranscriptSegment(
                id: "segment-1",
                speaker: speaker,
                text: "first",
                language: "en-US",
                isFinal: true
            )
        ])

        viewModel.drainRecordingFrames()
        try await waitFor {
            viewModel.liveCaptionTurns.first?.translatedText == "第一句"
                && viewModel.liveCaptionTurns.first?.translationHealth == .live
        }

        XCTAssertEqual(viewModel.liveCaptionTurns.first?.translatedText, "第一句")
        XCTAssertEqual(viewModel.liveCaptionTurns.first?.translationHealth, .live)

        try transcriptWriter.replace(with: [
            TranscriptSegment(
                id: "segment-1",
                speaker: speaker,
                text: "first",
                language: "en-US",
                isFinal: true
            ),
            TranscriptSegment(
                id: "segment-2",
                speaker: speaker,
                text: "second",
                language: "en-US",
                isFinal: true,
                speechFinal: true
            )
        ])

        viewModel.drainRecordingFrames()

        XCTAssertEqual(viewModel.liveCaptionTurns.first?.originalText, "first second")
        XCTAssertEqual(viewModel.liveCaptionTurns.first?.translatedText, "第一句")
        XCTAssertEqual(viewModel.liveCaptionTurns.first?.translationHealth, .pending)

        try await waitFor {
            viewModel.liveCaptionTurns.first?.translatedText == "第一句 第二句"
                && viewModel.liveCaptionTurns.first?.translationHealth == .live
        }

        XCTAssertEqual(provider.requests.map(\.segmentIDs), [["segment-1"], ["segment-2"]])
        XCTAssertEqual(viewModel.liveCaptionTurns.first?.translatedText, "第一句 第二句")
        XCTAssertEqual(viewModel.liveCaptionTurns.first?.translationHealth, .live)
    }

    func testDraftCaptionTranslationUpdatesSameTurnAsTextGrows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let record = try store.createMeeting(name: "Meet", startedAt: Date()).record
        let writer = try TranscriptFileWriter(url: XCTUnwrap(record.transcriptURL), structuredURL: XCTUnwrap(record.transcriptJSONURL))
        try writer.replace(with: [
            TranscriptSegment(id: "segment-1", speaker: TranscriptSpeaker(identifier: "speaker-1"), text: "This is the first part", language: "en-US")
        ])
        let provider = ViewModelFakeTextTranslationProvider(translations: ["segment-1": "第一部分"])
        let viewModel = MeetingAgentViewModel(
            store: store,
            captionTranslationProviderFactory: { _ in provider },
            processTargetsProvider: { [] }
        )
        try viewModel.loadMeetings()
        viewModel.selectMeeting(record.id)

        viewModel.drainRecordingFrames()
        try await waitFor { viewModel.liveCaptionTurns.first?.translatedText == "第一部分" }

        let longSecondPart = "and the second part adds enough detail about owners timelines risks and next steps to refresh the draft translation"
        try writer.replace(with: [
            TranscriptSegment(id: "segment-1", speaker: TranscriptSpeaker(identifier: "speaker-1"), text: "This is the first part", language: "en-US"),
            TranscriptSegment(id: "segment-2", speaker: TranscriptSpeaker(identifier: "speaker-1"), text: longSecondPart, language: "en-US")
        ])
        provider.translations = ["segment-2": "第一部分和第二部分"]

        viewModel.drainRecordingFrames()
        try await waitFor { viewModel.liveCaptionTurns.first?.translatedText == "第一部分和第二部分" }

        XCTAssertEqual(viewModel.liveCaptionTurns.count, 1)
        XCTAssertEqual(provider.requestedSegmentTexts.last, ["This is the first part \(longSecondPart)"])
    }

    func testProvisionalDeepgramSegmentUpdatesSameDraftTurnBeforeSpeechFinal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let record = try store.createMeeting(name: "Meet", startedAt: Date()).record
        let writer = try TranscriptFileWriter(url: XCTUnwrap(record.transcriptURL), structuredURL: XCTUnwrap(record.transcriptJSONURL))
        let provider = ViewModelFakeTextTranslationProvider(translations: ["dg-utterance": "第一版"])
        let viewModel = MeetingAgentViewModel(
            store: store,
            captionTranslationProviderFactory: { _ in provider },
            processTargetsProvider: { [] }
        )
        try viewModel.loadMeetings()
        viewModel.selectMeeting(record.id)

        try writer.replace(with: [
            TranscriptSegment(
                id: "dg-utterance",
                text: "Now what we can do is select",
                language: "en-US",
                sourceProvider: "deepgram-transcribe",
                isFinal: true,
                speechFinal: false
            )
        ])
        viewModel.drainRecordingFrames()
        try await waitFor { viewModel.liveCaptionTurns.first?.translatedText == "第一版" }

        let longerText = "Now what we can do is select German and hear what it sounds like in another automated voice while the interpreter keeps the meeting moving"
        provider.translations = ["dg-utterance": "第二版"]
        try writer.replace(with: [
            TranscriptSegment(
                id: "dg-utterance",
                text: longerText,
                language: "en-US",
                sourceProvider: "deepgram-transcribe",
                isFinal: true,
                speechFinal: false
            )
        ])
        viewModel.drainRecordingFrames()
        try await waitFor { viewModel.liveCaptionTurns.first?.translatedText == "第二版" }

        XCTAssertEqual(viewModel.liveCaptionTurns.count, 1)
        XCTAssertEqual(viewModel.liveCaptionTurns.first?.chunkState, .draft)
        XCTAssertEqual(viewModel.liveCaptionTurns.first?.originalText, longerText)
        XCTAssertEqual(provider.requestedSegmentTexts.last, [longerText])

        provider.translations = ["dg-utterance": "最终版"]
        try writer.replace(with: [
            TranscriptSegment(
                id: "dg-utterance",
                text: longerText,
                language: "en-US",
                sourceProvider: "deepgram-transcribe",
                isFinal: true,
                speechFinal: true
            )
        ])
        viewModel.drainRecordingFrames()
        try await waitFor {
            viewModel.liveCaptionTurns.first?.chunkState == .frozen
                && viewModel.liveCaptionTurns.first?.translatedText == "最终版"
        }

        XCTAssertEqual(viewModel.liveCaptionTurns.first?.freezeReason, .speechFinal)
    }

    func testSupersededDraftCaptionTranslationIsCancelledBeforeCompletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let record = try store.createMeeting(name: "Meet", startedAt: Date()).record
        let writer = try TranscriptFileWriter(url: XCTUnwrap(record.transcriptURL), structuredURL: XCTUnwrap(record.transcriptJSONURL))
        let provider = DelayedViewModelFakeTextTranslationProvider()
        let viewModel = MeetingAgentViewModel(
            store: store,
            captionTranslationProviderFactory: { _ in provider },
            processTargetsProvider: { [] }
        )
        try viewModel.loadMeetings()
        viewModel.selectMeeting(record.id)

        try writer.replace(with: [
            TranscriptSegment(
                id: "dg-utterance",
                text: "Now we can select",
                language: "en-US",
                sourceProvider: "deepgram-transcribe",
                isFinal: true,
                speechFinal: false
            )
        ])
        viewModel.drainRecordingFrames()

        let latestText = "Now we can select German and hear what it sounds like in another automated voice while the interpreter keeps the meeting moving"
        try writer.replace(with: [
            TranscriptSegment(
                id: "dg-utterance",
                text: latestText,
                language: "en-US",
                sourceProvider: "deepgram-transcribe",
                isFinal: true,
                speechFinal: false
            )
        ])
        viewModel.drainRecordingFrames()

        try await waitFor { provider.pendingRequestCount >= 1 }

        XCTAssertEqual(provider.pendingRequestCount, 1)
        XCTAssertEqual(provider.pendingRequestTexts, [[latestText]])
        XCTAssertEqual(viewModel.liveCaptionTurns.first?.originalText, latestText)
    }

    func testInterimDeepgramSegmentDisplaysWithDraftTranslationBeforeFinalArrives() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let record = try store.createMeeting(name: "Meet", startedAt: Date()).record
        let writer = try TranscriptFileWriter(url: XCTUnwrap(record.transcriptURL), structuredURL: XCTUnwrap(record.transcriptJSONURL))
        let provider = ViewModelFakeTextTranslationProvider(translations: ["dg-active": "临时翻译"])
        let viewModel = MeetingAgentViewModel(
            store: store,
            captionTranslationProviderFactory: { _ in provider },
            processTargetsProvider: { [] }
        )
        try viewModel.loadMeetings()
        viewModel.selectMeeting(record.id)

        try writer.replace(with: [
            TranscriptSegment(
                id: "dg-active",
                text: "hello inter",
                language: "en-US",
                sourceProvider: "deepgram-transcribe",
                isFinal: false
            )
        ])
        viewModel.drainRecordingFrames()
        try await waitFor { viewModel.liveCaptionTurns.first?.translatedText == "临时翻译" }

        XCTAssertEqual(viewModel.liveCaptionTurns.count, 1)
        XCTAssertEqual(viewModel.liveCaptionTurns.first?.originalText, "hello inter")
        XCTAssertEqual(viewModel.liveCaptionTurns.first?.isFinal, false)
        XCTAssertEqual(viewModel.liveCaptionTurns.first?.chunkState, .draft)
        XCTAssertEqual(viewModel.liveCaptionTurns.first?.translationHealth, .live)
        XCTAssertEqual(provider.requestedSegmentTexts, [["hello inter"]])

        provider.translations = ["dg-active": "最终翻译"]
        try writer.replace(with: [
            TranscriptSegment(
                id: "dg-active",
                text: "hello interim final",
                language: "en-US",
                sourceProvider: "deepgram-transcribe",
                isFinal: true,
                speechFinal: true
            )
        ])
        viewModel.drainRecordingFrames()

        try await waitFor { viewModel.liveCaptionTurns.first?.translatedText == "最终翻译" }
        XCTAssertEqual(viewModel.liveCaptionTurns.count, 1)
        XCTAssertEqual(viewModel.liveCaptionTurns.first?.originalText, "hello interim final")
        XCTAssertEqual(viewModel.liveCaptionTurns.first?.isFinal, true)
        XCTAssertEqual(provider.requestedSegmentTexts, [["hello inter"], ["hello interim final"]])
    }

    func testSoftCaptionBoundaryRequestsDraftTranslationButDoesNotFinalizeTranslation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let record = try store.createMeeting(name: "Meet", startedAt: Date()).record
        let writer = try TranscriptFileWriter(url: XCTUnwrap(record.transcriptURL), structuredURL: XCTUnwrap(record.transcriptJSONURL))
        let provider = ViewModelFakeTextTranslationProvider(translations: ["deepgram-transcribe-stream-0.00": "草稿翻译"])
        let viewModel = MeetingAgentViewModel(
            store: store,
            captionTranslationProviderFactory: { _ in provider },
            processTargetsProvider: { [] }
        )
        try viewModel.loadMeetings()
        viewModel.selectMeeting(record.id)

        try writer.replace(with: [
            TranscriptSegment(
                id: "deepgram-transcribe-stream-0.00",
                speaker: TranscriptSpeaker(identifier: "speaker-1", label: "User A"),
                startTimeSeconds: 0,
                endTimeSeconds: 9.49,
                text: "My name is Sherwin Chaffee, and I work at Microsoft as a copilot principal technical specialist. Now on this channel, we often build our own autonomous agents",
                language: "en-US",
                sourceProvider: "deepgram-transcribe",
                isFinal: true,
                speechFinal: false,
                timingSource: .precise
            )
        ])

        viewModel.drainRecordingFrames()
        try await waitFor { viewModel.liveCaptionTurns.first?.translatedText == "草稿翻译" }

        XCTAssertEqual(viewModel.liveCaptionTurns.first?.displayState, .sealed)
        XCTAssertEqual(viewModel.liveCaptionTurns.first?.translationState, .draft)
        XCTAssertEqual(viewModel.liveCaptionTurns.first?.boundaryStrength, .soft)
    }

    func testSpeechFinalCaptionBoundaryRequestsFinalTranslation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let record = try store.createMeeting(name: "Meet", startedAt: Date()).record
        let writer = try TranscriptFileWriter(url: XCTUnwrap(record.transcriptURL), structuredURL: XCTUnwrap(record.transcriptJSONURL))
        let provider = ViewModelFakeTextTranslationProvider(translations: ["segment-1": "最终翻译"])
        let viewModel = MeetingAgentViewModel(
            store: store,
            captionTranslationProviderFactory: { _ in provider },
            processTargetsProvider: { [] }
        )
        try viewModel.loadMeetings()
        viewModel.selectMeeting(record.id)

        try writer.replace(with: [
            TranscriptSegment(
                id: "segment-1",
                speaker: TranscriptSpeaker(identifier: "speaker-1", label: "User A"),
                text: "Done.",
                language: "en-US",
                sourceProvider: "deepgram-transcribe",
                isFinal: true,
                speechFinal: true
            )
        ])

        viewModel.drainRecordingFrames()
        try await waitFor { viewModel.liveCaptionTurns.first?.translatedText == "最终翻译" }

        XCTAssertEqual(viewModel.liveCaptionTurns.first?.translationState, .final)
        XCTAssertEqual(viewModel.liveCaptionTurns.first?.boundaryStrength, .hard)
    }

    func testHardBoundaryFinalTranslationUsesSameSpeakerSoftBlockContext() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let record = try store.createMeeting(name: "Meet", startedAt: Date()).record
        let writer = try TranscriptFileWriter(url: XCTUnwrap(record.transcriptURL), structuredURL: XCTUnwrap(record.transcriptJSONURL))
        let firstText = "That is the interpreter agent. The agent keeps context for the live meeting and explains what is happening before the final sentence arrives"
        let secondText = "So I just turned it on."
        let provider = ViewModelFakeTextTranslationProvider(translations: [
            "segment-1": "草稿上下文",
            "segment-2": "完整上下文翻译"
        ])
        let viewModel = MeetingAgentViewModel(
            store: store,
            captionTranslationProviderFactory: { _ in provider },
            processTargetsProvider: { [] }
        )
        try viewModel.loadMeetings()
        viewModel.selectMeeting(record.id)

        try writer.replace(with: [
            TranscriptSegment(
                id: "segment-1",
                speaker: TranscriptSpeaker(identifier: "speaker-1", label: "User A"),
                text: firstText,
                language: "en-US",
                sourceProvider: "deepgram-transcribe",
                isFinal: true,
                speechFinal: false
            ),
            TranscriptSegment(
                id: "segment-2",
                speaker: TranscriptSpeaker(identifier: "speaker-1", label: "User A"),
                text: secondText,
                language: "en-US",
                sourceProvider: "deepgram-transcribe",
                isFinal: true,
                speechFinal: true
            )
        ])

        viewModel.drainRecordingFrames()
        try await waitFor { viewModel.liveCaptionTurns.last?.translatedText == "完整上下文翻译" }

        XCTAssertEqual(provider.requestedSegmentTexts.last, ["\(firstText) \(secondText)"])
    }

    func testFinalDeepgramSegmentRemovesCoveredInterimTurnsFromLiveCaptions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let record = try store.createMeeting(name: "Meet", startedAt: Date()).record
        let writer = try TranscriptFileWriter(url: XCTUnwrap(record.transcriptURL), structuredURL: XCTUnwrap(record.transcriptJSONURL))
        let speaker = TranscriptSpeaker(identifier: "deepgram-speaker-0")
        let provider = ViewModelFakeTextTranslationProvider(translations: ["deepgram-transcribe-stream-0.0": "最终翻译"])
        let viewModel = MeetingAgentViewModel(
            store: store,
            captionTranslationProviderFactory: { _ in provider },
            processTargetsProvider: { [] }
        )
        try viewModel.loadMeetings()
        viewModel.selectMeeting(record.id)

        try writer.replace(with: [
            TranscriptSegment(
                id: "deepgram-transcribe-stream-4.97",
                speaker: speaker,
                startTimeSeconds: 4.97,
                endTimeSeconds: 7.85,
                text: "You I think you selected a female. What was",
                language: "en-US",
                sourceProvider: "deepgram-transcribe",
                isFinal: false,
                timingSource: .precise
            )
        ])
        viewModel.drainRecordingFrames()
        XCTAssertEqual(viewModel.liveCaptionTurns.map(\.id), ["deepgram-transcribe-stream-4.97"])

        try writer.replace(with: [
            TranscriptSegment(
                id: "deepgram-transcribe-stream-0.0",
                speaker: speaker,
                startTimeSeconds: 0,
                endTimeSeconds: 27.52,
                text: "Like, you're really speaking in Spanish. You I think you selected a female voice. Maybe yeah.",
                language: "en-US",
                sourceProvider: "deepgram-transcribe",
                isFinal: true,
                speechFinal: true,
                timingSource: .precise
            )
        ])
        viewModel.drainRecordingFrames()

        try await waitFor { viewModel.liveCaptionTurns.first?.translatedText == "最终翻译" }
        XCTAssertEqual(viewModel.liveCaptionTurns.map(\.id), ["deepgram-transcribe-stream-0.0"])
        XCTAssertEqual(viewModel.liveCaptionTurns.map(\.isFinal), [true])
    }

    func testCaptionTranslationRetriesWhenProviderBecomesAvailableAfterInitialDrain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let record = try store.createMeeting(name: "Meet", startedAt: Date()).record
        let writer = try TranscriptFileWriter(url: XCTUnwrap(record.transcriptURL), structuredURL: XCTUnwrap(record.transcriptJSONURL))
        try writer.replace(with: [
            TranscriptSegment(
                id: "segment-1",
                speaker: TranscriptSpeaker(identifier: "speaker-1"),
                text: "We should confirm the owner.",
                language: "en-US",
                speechFinal: true
            )
        ])
        let provider = ViewModelFakeTextTranslationProvider(translations: ["segment-1": "我们应该确认负责人。"])
        var providerIsAvailable = false
        let viewModel = MeetingAgentViewModel(
            store: store,
            captionTranslationProviderFactory: { _ in providerIsAvailable ? provider : nil },
            processTargetsProvider: { [] }
        )
        try viewModel.loadMeetings()
        viewModel.selectMeeting(record.id)

        viewModel.drainRecordingFrames()
        XCTAssertTrue(provider.requests.isEmpty)
        XCTAssertNil(viewModel.liveCaptionTurns.first?.translatedText)

        providerIsAvailable = true
        viewModel.drainRecordingFrames()

        try await waitFor {
            viewModel.liveCaptionTurns.first?.translatedText == "我们应该确认负责人。"
        }
        XCTAssertEqual(provider.requests.count, 1)
    }

    func testOlderDraftTranslationDoesNotOverwriteNewerDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let record = try store.createMeeting(name: "Meet", startedAt: Date()).record
        let writer = try TranscriptFileWriter(url: XCTUnwrap(record.transcriptURL), structuredURL: XCTUnwrap(record.transcriptJSONURL))
        let provider = DelayedViewModelFakeTextTranslationProvider()
        let viewModel = MeetingAgentViewModel(
            store: store,
            captionTranslationProviderFactory: { _ in provider },
            processTargetsProvider: { [] }
        )
        try viewModel.loadMeetings()
        viewModel.selectMeeting(record.id)

        try writer.replace(with: [
            TranscriptSegment(id: "segment-1", speaker: TranscriptSpeaker(identifier: "speaker-1"), text: "first draft", language: "en-US")
        ])
        viewModel.drainRecordingFrames()
        try await waitFor { provider.pendingRequestCount == 1 }

        try writer.replace(with: [
            TranscriptSegment(id: "segment-1", speaker: TranscriptSpeaker(identifier: "speaker-1"), text: "first draft", language: "en-US"),
            TranscriptSegment(id: "segment-2", speaker: TranscriptSpeaker(identifier: "speaker-1"), text: "second draft adds enough detail about owners timelines risks and next steps to refresh the draft translation", language: "en-US")
        ])
        viewModel.drainRecordingFrames()
        try await waitFor { provider.pendingRequestCount == 2 }

        provider.completeRequest(at: 1, targetText: "newer translation")
        try await waitFor { viewModel.liveCaptionTurns.first?.translatedText == "newer translation" }
        provider.completeRequest(at: 0, targetText: "older translation")
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(viewModel.liveCaptionTurns.first?.translatedText, "newer translation")
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
                targetLocaleIdentifier: "zh-CN",
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
        let transcriptWriter = try TranscriptFileWriter(url: XCTUnwrap(record.transcriptURL))
        try transcriptWriter.replace(with: [
            TranscriptSegment(id: "segment-1", text: "Alex is the launch owner.", language: "en-US", isFinal: true)
        ])
        viewModel.drainRecordingFrames()

        await viewModel.refreshMeetingProgress()

        XCTAssertEqual(viewModel.meetingProgressState?.status, .onTrack)
        XCTAssertEqual(viewModel.meetingProgressState?.suggestedQuestions.first?.english, "Have we confirmed the deadline?")
        let progressURL = try XCTUnwrap(record.meetingProgressJSONURL)
        let saved = try JSONDecoder.meetingAgent.decode(MeetingProgressState.self, from: Data(contentsOf: progressURL))
        XCTAssertEqual(saved.lastAnalyzedSegmentID, "segment-1")
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
                targetLocaleIdentifier: "zh-CN",
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
        let transcriptWriter = try TranscriptFileWriter(url: XCTUnwrap(record.transcriptURL))
        try transcriptWriter.replace(with: [
            TranscriptSegment(id: "segment-1", text: "Alex is the launch owner.", language: "en-US", isFinal: true)
        ])

        viewModel.drainRecordingFrames()
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
                targetLocaleIdentifier: "zh-CN",
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
        let transcriptWriter = try TranscriptFileWriter(url: XCTUnwrap(record.transcriptURL))
        try transcriptWriter.replace(with: [
            TranscriptSegment(id: "segment-1", text: "Alex is the launch owner.", language: "en-US", isFinal: true)
        ])
        viewModel.drainRecordingFrames()
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

    func testUpdateSpeakerLabelRefreshesTranscriptArtifactsAndLiveCaptions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let stored = try store.createMeeting(name: "Google Meet", startedAt: Date(timeIntervalSince1970: 100))
        let writer = try TranscriptFileWriter(url: XCTUnwrap(stored.record.transcriptURL))
        try writer.replace(with: [
            TranscriptSegment(
                id: "segment-1",
                speaker: TranscriptSpeaker(identifier: "speaker-1", label: "User A"),
                text: "Hello",
                language: "en-US"
            )
        ])
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
        let writer = try TranscriptFileWriter(url: XCTUnwrap(stored.transcriptURL))
        try writer.replace(with: [
            TranscriptSegment(
                id: "segment-1",
                speaker: TranscriptSpeaker(identifier: "speaker-1", label: "User A"),
                text: "Old text",
                language: "en-US"
            )
        ])
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
        let viewModel = MeetingAgentViewModel(store: store, processTargetsProvider: { [] })
        try viewModel.loadMeetings()

        let summaryDestination = root.appendingPathComponent("summary.md")
        let dataDestination = root.appendingPathComponent("meeting.json")
        let srtDestination = root.appendingPathComponent("captions.srt")
        let vttDestination = root.appendingPathComponent("captions.vtt")
        let readinessDestination = root.appendingPathComponent("readiness.json")
        let transcriptWriter = try TranscriptFileWriter(url: XCTUnwrap(stored.record.transcriptURL))
        try transcriptWriter.replace(with: [
            TranscriptSegment(startTimeSeconds: 0, endTimeSeconds: 2, text: "Hello", language: "en-US")
        ])
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
        XCTAssertTrue(FileManager.default.fileExists(atPath: summaryDestination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dataDestination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: srtDestination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: vttDestination.path))
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
        let transcriptWriter = try TranscriptFileWriter(url: stored.record.transcriptURL!)
        try transcriptWriter.replace(with: [
            TranscriptSegment(id: "segment-1", text: "We agreed to update renewal pricing next week.", language: "en-US")
        ])
        try transcriptWriter.close()
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
        let transcriptWriter = try TranscriptFileWriter(url: stored.record.transcriptURL!)
        try transcriptWriter.replace(with: [
            TranscriptSegment(id: "segment-1", text: "We agreed to update renewal pricing next week.", language: "en-US")
        ])
        try transcriptWriter.close()
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

    func testGenerateSummaryUsesConfiguredSummaryModelIndependentlyFromTranslationModel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let stored = try store.createMeeting(
            name: "Launch Review",
            startedAt: Date(timeIntervalSince1970: 1_777_000_000)
        )
        let transcriptWriter = try TranscriptFileWriter(url: stored.record.transcriptURL!)
        try transcriptWriter.replace(with: [
            TranscriptSegment(id: "segment-1", text: "We decided to launch on May 1.", language: "en-US")
        ])
        try transcriptWriter.close()
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

    func testOpenRouterCaptionTranslationProviderUsesPersistedHostedTranslationCredentials() {
        var configuration = SpeechTranscriptionConfiguration.default
        configuration.translationExecutionMode = .hosted
        configuration.hostedTranslationProviderID = SpeechTranscriptionConfiguration.defaultHostedTranslationProviderID
        configuration.hostedTranslationModelID = "openai/gpt-4.1-mini"
        configuration.openRouterAPIKey = "openrouter-key"

        XCTAssertNotNil(MeetingAgentViewModel.openRouterCaptionTranslationProvider(for: configuration))
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

    func testRealtimeTranslationFinalTextAttachesToPendingLiveCaptionTurn() async throws {
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
                targetLocaleIdentifier: "zh-CN",
                whisperBinaryPath: nil,
                whisperModelPath: nil
            ),
            realtimeTranslationController: controller,
            processTargetsProvider: { [target] }
        )
        try await viewModel.startRecording(for: target)
        let record = try XCTUnwrap(viewModel.meetings.first)
        let transcriptWriter = try TranscriptFileWriter(url: XCTUnwrap(record.transcriptURL))
        try transcriptWriter.replace(with: [
            TranscriptSegment(id: "segment-1", text: "Alex is the launch owner.", language: "en-US", isFinal: true)
        ])
        viewModel.drainRecordingFrames()
        await viewModel.startRealtimeTranslation(targetLocale: "zh-CN")

        provider.lastSession?.emit(.targetTextFinal("Alex 是上线负责人。"))
        try await Task.sleep(nanoseconds: 20_000_000)
        viewModel.syncRealtimeTranslationState()

        XCTAssertEqual(viewModel.liveCaptionTurns.first?.translatedText, "Alex 是上线负责人。")
        XCTAssertEqual(viewModel.liveCaptionTurns.first?.translationHealth, .live)
        XCTAssertEqual(viewModel.meetingProgressHealth.translation, .live)
    }

    func testRealtimeTranslationFinalTextsAttachByCaptionOrderOnce() async throws {
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
                targetLocaleIdentifier: "zh-CN",
                whisperBinaryPath: nil,
                whisperModelPath: nil
            ),
            realtimeTranslationController: controller,
            processTargetsProvider: { [target] }
        )
        try await viewModel.startRecording(for: target)
        let record = try XCTUnwrap(viewModel.meetings.first)
        let transcriptWriter = try TranscriptFileWriter(url: XCTUnwrap(record.transcriptURL))
        try transcriptWriter.replace(with: [
            TranscriptSegment(id: "segment-1", text: "First decision.", language: "en-US", isFinal: true),
            TranscriptSegment(id: "segment-2", text: "Second decision.", language: "en-US", isFinal: true)
        ])
        viewModel.drainRecordingFrames()
        await viewModel.startRealtimeTranslation(targetLocale: "zh-CN")

        provider.lastSession?.emit(.targetTextFinal("第一个决定。"))
        provider.lastSession?.emit(.targetTextFinal("第二个决定。"))
        try await Task.sleep(nanoseconds: 20_000_000)
        viewModel.syncRealtimeTranslationState()
        viewModel.syncRealtimeTranslationState()

        XCTAssertEqual(viewModel.liveCaptionTurns.map(\.translatedText), ["第一个决定。 第二个决定。"])
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
                )
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
        channelCount: Int,
        performanceEventLogger: PerformanceEventLogger?
    ) async throws -> AudioFrameTranscriber {
        requests.append(Request(localeIdentifier: configuration.localeIdentifier))
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

private struct CapturingSummaryProvider: MeetingSummaryProvider {
    let providerName: String

    func generateSummary(input: MeetingSummaryInput) async throws -> MeetingSummary {
        let usableSegments = input.segments.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let decisions = usableSegments
            .filter { $0.text.lowercased().contains("decided") || $0.text.lowercased().contains("agreed") }
            .map {
                MeetingDecision(
                    description: $0.text,
                    participants: [],
                    sourceSegmentIDs: [$0.id],
                    confidence: 0.8
                )
            }
        let actionItems = usableSegments
            .filter { $0.text.lowercased().contains("follow up") || $0.text.lowercased().contains("will") }
            .map {
                MeetingActionItem(
                    description: $0.text,
                    owner: nil,
                    dueDate: nil,
                    sourceSegmentIDs: [$0.id],
                    confidence: 0.8
                )
            }
        let overview = usableSegments.map(\.text).joined(separator: " ")
        return MeetingSummary(
            autoGeneratedTitle: MeetingSummaryTitleGenerator.title(
                meetingName: input.meetingName,
                keyTopics: [],
                overview: overview,
                segments: input.segments
            ),
            overview: overview,
            keyTopics: [],
            decisions: decisions,
            actionItems: actionItems,
            openQuestions: [],
            risks: [],
            followUps: actionItems.map(\.description),
            language: input.language,
            sourceSegmentIDs: usableSegments.map(\.id),
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

private final class ViewModelFakeRealtimeProvider: RealtimeSpeechTranslationProvider {
    private(set) var startedConfigurations: [RealtimeTranslationConfiguration] = []
    private(set) var lastSession: ViewModelFakeRealtimeSession?

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
        let session = ViewModelFakeRealtimeSession()
        lastSession = session
        return session
    }
}

private final class ViewModelFakeRealtimeSession: RealtimeTranslationSession {
    private let continuation: AsyncStream<RealtimeTranslationEvent>.Continuation

    let events: AsyncStream<RealtimeTranslationEvent>

    init() {
        var streamContinuation: AsyncStream<RealtimeTranslationEvent>.Continuation!
        events = AsyncStream { continuation in
            streamContinuation = continuation
        }
        continuation = streamContinuation
    }

    func append(_ frames: [AudioFrame]) async throws {}

    func stop() async {}

    func emit(_ event: RealtimeTranslationEvent) {
        continuation.yield(event)
    }
}

final class AppRuntimeCapabilitiesTests: XCTestCase {
    func testUserNotificationsRequireAppBundleRuntime() {
        XCTAssertTrue(AppRuntimeCapabilities.supportsUserNotifications(bundleURL: URL(fileURLWithPath: "/Applications/MeetingAgent.app")))
        XCTAssertFalse(AppRuntimeCapabilities.supportsUserNotifications(bundleURL: URL(fileURLWithPath: "/tmp/meeting-agent/.build/debug")))
    }
}
