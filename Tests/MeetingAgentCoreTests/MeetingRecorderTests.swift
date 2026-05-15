import XCTest
@testable import MeetingAgentCore

final class MeetingRecorderTests: XCTestCase {
    func testRecorderStartsAndStopsMeeting() throws {
        let storeRoot = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-recorder-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storeRoot) }
        let store = MeetingStore(baseDirectory: storeRoot)
        let recorder = MeetingRecorder(store: store)
        let target = AudioCaptureTarget(processID: 1, displayName: "Google Chrome", bundleIdentifier: "com.google.Chrome")

        let record = try recorder.prepareRecord(for: target, startedAt: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(record.name, "Google Chrome")
        XCTAssertEqual(recorder.state, .prepared(record.id))

        let stopped = try recorder.markStopped(at: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(stopped?.endedAt, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(recorder.state, .idle)
    }

    func testRecorderRejectsSecondPreparedMeeting() throws {
        let storeRoot = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-recorder-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storeRoot) }
        let store = MeetingStore(baseDirectory: storeRoot)
        let recorder = MeetingRecorder(store: store)
        let target = AudioCaptureTarget(processID: 1, displayName: "Google Chrome", bundleIdentifier: "com.google.Chrome")

        _ = try recorder.prepareRecord(for: target, startedAt: Date(timeIntervalSince1970: 100))

        XCTAssertThrowsError(try recorder.prepareRecord(for: target, startedAt: Date(timeIntervalSince1970: 101)))
    }

    func testRecorderPersistsTargetProcessEndedReason() throws {
        let storeRoot = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-recorder-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storeRoot) }
        let store = MeetingStore(baseDirectory: storeRoot)
        let recorder = MeetingRecorder(store: store)
        let target = AudioCaptureTarget(processID: 1, displayName: "Google Chrome", bundleIdentifier: "com.google.Chrome")

        let record = try recorder.prepareRecord(for: target, startedAt: Date(timeIntervalSince1970: 100))
        _ = try recorder.markStopped(at: Date(timeIntervalSince1970: 200), endedReason: .targetProcessEnded)

        let data = try Data(contentsOf: XCTUnwrap(record.diagnosticsURL))
        let diagnostics = try JSONDecoder.meetingAgent.decode(CaptureDiagnostics.self, from: data)
        XCTAssertEqual(diagnostics.endedReason, .targetProcessEnded)
        XCTAssertEqual(diagnostics.status, .targetProcessEnded)
    }

    func testStartDrainAndStopRecordingWithInjectedCapturePipeline() async throws {
        let fixture = try RecorderFixture()
        let frame = AudioFrame(pcm: Data([64, 0, 65, 0]), sampleRate: 16_000, channelCount: 1, timestampNanos: 9)
        fixture.session.frameBuffer.push(frame)
        let record = try fixture.recorder.prepareRecord(for: fixture.target, startedAt: Date(timeIntervalSince1970: 100))

        try await fixture.recorder.startRecording(
            target: fixture.target,
            record: record,
            speechProvider: .local,
            localeIdentifier: "zh-CN"
        )
        try fixture.recorder.drainFrames()
        let stopped = try fixture.recorder.stopRecording(at: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(fixture.session.startedTargets, [fixture.target])
        XCTAssertEqual(fixture.writerFactory.requests.first?.sampleRate, 16_000)
        XCTAssertEqual(fixture.writerFactory.requests.first?.channelCount, 1)
        XCTAssertEqual(fixture.transcriberFactory.requests.first?.localeIdentifier, "zh-CN")
        XCTAssertEqual(fixture.transcriberFactory.requests.first?.sampleRate, 16_000)
        XCTAssertEqual(fixture.writer.writtenFrames, [frame])
        XCTAssertEqual(fixture.transcriber.appendedFrames, [frame])
        XCTAssertEqual(fixture.writer.closeCallCount, 1)
        XCTAssertEqual(fixture.transcriber.finishCallCount, 1)
        XCTAssertEqual(fixture.session.stopCallCount, 1)
        XCTAssertEqual(stopped?.endedAt, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(stopped?.transcriptionStatus, .transcribed)
        XCTAssertEqual(fixture.recorder.state, .idle)
        let performanceEvents = try performanceEventNames(at: XCTUnwrap(record.performanceEventsURL))
        XCTAssertTrue(performanceEvents.contains("recording_started"))
        XCTAssertTrue(performanceEvents.contains("audio_frames_drained"))
        XCTAssertTrue(performanceEvents.contains("recording_stopped"))
    }

    func testStartRecordingProcessesPushedFramesWithoutExternalDrain() async throws {
        let fixture = try RecorderFixture()
        let frame = AudioFrame(pcm: Data([64, 0, 65, 0]), sampleRate: 16_000, channelCount: 1, timestampNanos: 9)
        let record = try fixture.recorder.prepareRecord(for: fixture.target, startedAt: Date(timeIntervalSince1970: 100))

        try await fixture.recorder.startRecording(
            target: fixture.target,
            record: record,
            speechProvider: .local,
            localeIdentifier: "zh-CN"
        )
        fixture.session.frameBuffer.push(frame)

        try await waitFor {
            fixture.writer.writtenFrames == [frame]
                && fixture.transcriber.appendedFrames == [frame]
        }
    }

    func testRecorderAggregatesAudioFrameDrainTelemetry() async throws {
        let fixture = try RecorderFixture()
        let record = try fixture.recorder.prepareRecord(for: fixture.target, startedAt: Date(timeIntervalSince1970: 100))

        let frames = (0..<120).map { index in
            AudioFrame(
                pcm: Data(repeating: UInt8(index % 128), count: 320),
                sampleRate: 16_000,
                channelCount: 1,
                timestampNanos: UInt64(index) * 10_000_000
            )
        }
        for frame in frames {
            fixture.session.frameBuffer.push(frame)
        }
        try await fixture.recorder.startRecording(
            target: fixture.target,
            record: record,
            speechProvider: .local,
            localeIdentifier: "zh-CN"
        )
        try await waitFor {
            fixture.writer.writtenFrames.count == frames.count
        }

        _ = try fixture.recorder.stopRecording(at: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(fixture.writer.writtenFrames.count, frames.count)
        let events = try performanceEvents(at: XCTUnwrap(record.performanceEventsURL))
            .filter { $0.event == "audio_frames_drained" }
        XCTAssertLessThan(events.count, frames.count)
        XCTAssertEqual(events.compactMap { Int($0.metadata["frameCount"] ?? "") }.reduce(0, +), frames.count)
        XCTAssertEqual(events.last?.metadata["lastFrameTimestampNanos"], String(frames.last?.timestampNanos ?? 0))
        XCTAssertNotNil(events.last?.metadata["audioDurationSeconds"])
    }

    func testRecorderEmitsTranscriptUpdateEvents() async throws {
        let fixture = try RecorderFixture()
        let record = try fixture.recorder.prepareRecord(for: fixture.target, startedAt: Date(timeIntervalSince1970: 100))
        let eventTask = Task {
            await firstRecorderEvent(from: fixture.recorder.events) { event in
                if case .transcriptUpdates = event {
                    return true
                }
                return false
            }
        }

        try await fixture.recorder.startRecording(target: fixture.target, record: record)
        fixture.transcriber.emit(.upsert(TranscriptSegment(
            id: "segment-1",
            text: "hello live",
            language: "en-US",
            sourceProvider: "fake",
            isFinal: true
        )))

        let event = try await waitForValue(from: eventTask)
        guard case .transcriptUpdates(let updates)? = event else {
            return XCTFail("Expected transcript update event")
        }
        XCTAssertEqual(updates.flatMap { $0.document.segments.map(\.text) }, ["hello live"])
    }

    func testStopRecordingEmitsStoppedEventOnce() async throws {
        let fixture = try RecorderFixture()
        let record = try fixture.recorder.prepareRecord(for: fixture.target, startedAt: Date(timeIntervalSince1970: 100))
        let eventTask = Task {
            await firstRecorderEvent(from: fixture.recorder.events) { event in
                if case .stopped = event {
                    return true
                }
                return false
            }
        }

        try await fixture.recorder.startRecording(target: fixture.target, record: record)
        _ = try fixture.recorder.stopRecording(at: Date(timeIntervalSince1970: 200))

        let event = try await waitForValue(from: eventTask)
        guard case .stopped(let stopped)? = event else {
            return XCTFail("Expected stopped event")
        }
        XCTAssertEqual(stopped?.id, record.id)
        XCTAssertEqual(stopped?.endedAt, Date(timeIntervalSince1970: 200))
    }

    func testStartMicrophoneRecordingUsesMicrophoneCaptureSource() async throws {
        let fixture = try RecorderFixture()
        let source = AudioCaptureSource.microphone(displayName: "Computer Microphone")
        let record = try fixture.recorder.prepareRecord(
            named: "Offline Discussion",
            source: source,
            startedAt: Date(timeIntervalSince1970: 100)
        )

        try await fixture.recorder.startRecording(
            source: source,
            record: record
        )

        XCTAssertEqual(record.name, "Offline Discussion")
        XCTAssertEqual(fixture.microphoneSession.startedSources, [source])
        XCTAssertEqual(fixture.recorder.state, .recording(record.id))
    }

    func testExistingTargetStartStillUsesProcessSource() async throws {
        let fixture = try RecorderFixture()
        let record = try fixture.recorder.prepareRecord(for: fixture.target, startedAt: Date(timeIntervalSince1970: 100))

        try await fixture.recorder.startRecording(target: fixture.target, record: record)

        XCTAssertEqual(fixture.session.startedSources, [.process(fixture.target)])
        XCTAssertEqual(fixture.session.startedTargets, [fixture.target])
    }

    func testProcessWithMicrophoneStartsTwoCaptureSessionsAndTranscribers() async throws {
        let fixture = try RecorderFixture()
        var record = try fixture.recorder.prepareRecord(
            named: "Zoom",
            source: .processWithMicrophone(fixture.target),
            startedAt: Date(timeIntervalSince1970: 100)
        )
        record.captureMode = .processWithMicrophone

        try await fixture.recorder.startRecording(
            source: .processWithMicrophone(fixture.target),
            record: record,
            speechConfiguration: .default
        )

        XCTAssertEqual(fixture.processSession.startedSources, [.processWithMicrophone(fixture.target)])
        XCTAssertEqual(fixture.microphoneSession.startedSources, [.microphone(displayName: "Computer Microphone")])
        XCTAssertEqual(fixture.transcriberFactory.requests.count, 2)
        XCTAssertEqual(fixture.writerFactory.requests.map { $0.url.lastPathComponent }, ["audio.wav", "audio-microphone.wav"])
    }

    func testMicrophoneSpeechEventsAreAttributedAsMe() async throws {
        let fixture = try RecorderFixture()
        var record = try fixture.recorder.prepareRecord(
            named: "Zoom",
            source: .processWithMicrophone(fixture.target),
            startedAt: Date(timeIntervalSince1970: 100)
        )
        record.captureMode = .processWithMicrophone

        try await fixture.recorder.startRecording(
            source: .processWithMicrophone(fixture.target),
            record: record,
            speechConfiguration: .default
        )
        fixture.microphoneTranscriber.emitSpeechEvent(.final(testSpeechPayload(
            speakerID: "provider-speaker-1",
            text: "I agree with the launch owner."
        )))

        let results = fixture.recorder.drainTranscriptUpdates()

        XCTAssertEqual(results.first?.document.segments.first?.speakerID, "local-user")
        XCTAssertEqual(results.first?.document.segments.first?.speakerLabel, "Me")
    }

    func testMicrophoneTranscriptUpdatesAreAttributedAsMe() async throws {
        let fixture = try RecorderFixture()
        var record = try fixture.recorder.prepareRecord(
            named: "Zoom",
            source: .processWithMicrophone(fixture.target),
            startedAt: Date(timeIntervalSince1970: 100)
        )
        record.captureMode = .processWithMicrophone

        try await fixture.recorder.startRecording(
            source: .processWithMicrophone(fixture.target),
            record: record,
            speechConfiguration: .default
        )
        fixture.microphoneTranscriber.emit(.upsert(TranscriptSegment(
            id: "mic-segment-1",
            speaker: TranscriptSpeaker(identifier: "provider-speaker-1", label: "Speaker 1"),
            text: "I agree with the launch owner.",
            language: "en-US",
            sourceProvider: "whisper",
            isFinal: true
        )))

        let results = fixture.recorder.drainTranscriptUpdates()

        XCTAssertEqual(results.first?.document.segments.first?.speakerID, "local-user")
        XCTAssertEqual(results.first?.document.segments.first?.speakerLabel, "Me")
    }

    func testProcessSpeechEventsAreNotAttributedAsMe() async throws {
        let fixture = try RecorderFixture()
        var record = try fixture.recorder.prepareRecord(
            named: "Zoom",
            source: .processWithMicrophone(fixture.target),
            startedAt: Date(timeIntervalSince1970: 100)
        )
        record.captureMode = .processWithMicrophone

        try await fixture.recorder.startRecording(
            source: .processWithMicrophone(fixture.target),
            record: record,
            speechConfiguration: .default
        )
        fixture.processTranscriber.emitSpeechEvent(.final(testSpeechPayload(
            speakerID: "deepgram-speaker-1",
            text: "Remote participant speaking."
        )))

        let results = fixture.recorder.drainTranscriptUpdates()

        XCTAssertEqual(results.first?.document.segments.first?.speakerID, "deepgram-speaker-1")
        XCTAssertNotEqual(results.first?.document.segments.first?.speakerLabel, "Me")
    }

    func testDrainFramesSkipsSilentAudioOnlyForTranscription() async throws {
        let fixture = try RecorderFixture()
        let silentFrame = AudioFrame(pcm: Data([0, 0, 2, 0]), sampleRate: 16_000, channelCount: 1, timestampNanos: 1)
        let voicedFrame = AudioFrame(pcm: Data([64, 0, 0, 0]), sampleRate: 16_000, channelCount: 1, timestampNanos: 2)
        fixture.session.frameBuffer.push(silentFrame)
        fixture.session.frameBuffer.push(voicedFrame)
        let record = try fixture.recorder.prepareRecord(for: fixture.target)

        try await fixture.recorder.startRecording(target: fixture.target, record: record)
        try fixture.recorder.drainFrames()

        XCTAssertEqual(fixture.writer.writtenFrames, [silentFrame, voicedFrame])
        XCTAssertEqual(fixture.transcriber.appendedFrames, [voicedFrame])
    }

    func testPrepareRecordCanReuseExistingAgendaRecord() throws {
        let fixture = try RecorderFixture()
        var record = try fixture.store.createMeeting(
            id: UUID(uuidString: "12121212-1212-1212-1212-121212121212")!,
            name: "APAC launch sync",
            startedAt: Date(timeIntervalSince1970: 100)
        ).record
        record.scheduledStartAt = Date(timeIntervalSince1970: 500)
        record.attendees = [MeetingAttendee(name: "Li Wei", role: "Shanghai GM")]
        try fixture.store.save(record)

        let prepared = try fixture.recorder.prepareRecord(record, for: fixture.target)

        XCTAssertEqual(prepared.id, record.id)
        XCTAssertEqual(prepared.name, "APAC launch sync")
        XCTAssertEqual(prepared.scheduledStartAt, Date(timeIntervalSince1970: 500))
        XCTAssertEqual(prepared.attendees.first?.name, "Li Wei")
        XCTAssertEqual(fixture.recorder.state, .prepared(record.id))
        XCTAssertEqual(try fixture.store.loadMeetings().count, 1)
    }

    func testStartRecordingPersistsHostedTranscriptionProviderID() async throws {
        let fixture = try RecorderFixture()
        let record = try fixture.recorder.prepareRecord(for: fixture.target, startedAt: Date(timeIntervalSince1970: 100))
        let configuration = SpeechTranscriptionConfiguration(
            provider: .whisper,
            localeIdentifier: "en-US",
            whisperBinaryPath: nil,
            whisperModelPath: nil,
            transcriptionExecutionMode: .hosted,
            hostedTranscriptionProviderID: "deepgram-transcribe",
            deepgramAPIKey: "key",
            deepgramModelID: "nova-3"
        )

        try await fixture.recorder.startRecording(
            target: fixture.target,
            record: record,
            speechConfiguration: configuration
        )

        let metadataURL = fixture.storeRoot
            .appendingPathComponent("Meetings", isDirectory: true)
            .appendingPathComponent(record.id.uuidString, isDirectory: true)
            .appendingPathComponent("metadata.json")
        let metadata = try Data(contentsOf: metadataURL)
        let saved = try JSONDecoder.meetingAgent.decode(MeetingRecord.self, from: metadata)
        XCTAssertEqual(saved.speechProvider, .whisper)
        XCTAssertEqual(saved.transcriptionProviderID, "deepgram-transcribe")
    }

    func testStartRecordingMarksTranscriptionFailedWhenStreamingTranscriberCannotStart() async throws {
        let fixture = try RecorderFixture()
        fixture.transcriberFactory.error = ProbeError.speechRecognition("not available")
        let record = try fixture.recorder.prepareRecord(for: fixture.target)

        try await fixture.recorder.startRecording(target: fixture.target, record: record)
        let stopped = try XCTUnwrap(try fixture.recorder.markStopped())

        XCTAssertEqual(stopped.transcriptionStatus, .failed)
        XCTAssertTrue(stopped.transcriptionFailureReason?.contains("Speech recognition unavailable") == true)
        XCTAssertEqual(fixture.writerFactory.requests.count, 1)
    }

    func testDrainFramesPersistsTranscriptionFailureAndContinuesWritingAudio() async throws {
        let fixture = try RecorderFixture()
        let frame = AudioFrame(pcm: Data([64, 0]), sampleRate: 16_000, channelCount: 1, timestampNanos: 1)
        fixture.session.frameBuffer.push(frame)
        fixture.transcriber.appendError = ProbeError.speechRecognition("append failed")
        let record = try fixture.recorder.prepareRecord(for: fixture.target)
        try await fixture.recorder.startRecording(target: fixture.target, record: record)

        try fixture.recorder.drainFrames()
        let stopped = try XCTUnwrap(try fixture.recorder.markStopped())

        XCTAssertEqual(fixture.writer.writtenFrames, [frame])
        XCTAssertEqual(fixture.transcriber.finishCallCount, 1)
        XCTAssertEqual(stopped.transcriptionStatus, .failed)
        XCTAssertTrue(stopped.transcriptionFailureReason?.contains("Speech recognition failed") == true)
    }

    func testDrainFramesBeforeTranscriberReadyFlushesStartupFramesWhenReady() async throws {
        let fixture = try RecorderFixture()
        fixture.transcriberFactory.shouldSuspend = true
        let frame = AudioFrame(pcm: Data([64, 0]), sampleRate: 16_000, channelCount: 1, timestampNanos: 1)
        let record = try fixture.recorder.prepareRecord(for: fixture.target)

        let startTask = Task {
            try await fixture.recorder.startRecording(target: fixture.target, record: record)
        }
        try await waitFor { fixture.transcriberFactory.requests.count == 1 }
        fixture.session.frameBuffer.push(frame)

        try fixture.recorder.drainFrames()
        try await waitFor { fixture.writer.writtenFrames == [frame] }
        XCTAssertEqual(fixture.writer.writtenFrames, [frame])
        XCTAssertEqual(fixture.transcriber.appendedFrames, [])

        fixture.transcriberFactory.resume()
        try await startTask.value

        XCTAssertEqual(fixture.transcriber.appendedFrames, [frame])
    }

    func testDrainDuringWriterSetupDoesNotDropStartupAudio() async throws {
        let fixture = try RecorderFixture()
        let frame = AudioFrame(pcm: Data([64, 0]), sampleRate: 16_000, channelCount: 1, timestampNanos: 1)
        fixture.writerFactory.onMakeWriter = {
            fixture.session.frameBuffer.push(frame)
            try? fixture.recorder.drainFrames()
        }
        let record = try fixture.recorder.prepareRecord(for: fixture.target)

        try await fixture.recorder.startRecording(target: fixture.target, record: record)
        try fixture.recorder.drainFrames()

        XCTAssertEqual(fixture.writer.writtenFrames, [frame])
        XCTAssertEqual(fixture.transcriber.appendedFrames, [frame])
    }

    func testStartupTranscriptionReplayOverflowIsRecordedInDiagnostics() async throws {
        let fixture = try RecorderFixture()
        fixture.transcriberFactory.shouldSuspend = true
        let record = try fixture.recorder.prepareRecord(for: fixture.target)
        let frames = (0..<3_008).map { index in
            AudioFrame(
                pcm: Data([UInt8(64 + (index % 128)), 0]),
                sampleRate: 16_000,
                channelCount: 1,
                timestampNanos: UInt64(index + 1)
            )
        }

        let startTask = Task {
            try await fixture.recorder.startRecording(target: fixture.target, record: record)
        }
        try await waitFor { fixture.transcriberFactory.requests.count == 1 }
        for frame in frames {
            fixture.session.frameBuffer.push(frame)
            try fixture.recorder.drainFrames()
        }
        try await waitFor { fixture.writer.writtenFrames.count == 3_008 }

        fixture.transcriberFactory.resume()
        try await startTask.value
        _ = try fixture.recorder.stopRecording()

        let diagnostics = try JSONDecoder.meetingAgent.decode(
            CaptureDiagnostics.self,
            from: Data(contentsOf: XCTUnwrap(record.diagnosticsURL))
        )
        XCTAssertEqual(fixture.writer.writtenFrames.count, 3_008)
        XCTAssertEqual(fixture.transcriber.appendedFrames.count, 3_000)
        XCTAssertEqual(diagnostics.startupReplayFrameCount, 3_000)
        XCTAssertEqual(diagnostics.startupReplayDroppedFrameCount, 8)
    }

    func testStartRecordingWritesDiagnosticsWhenCaptureStartFails() async throws {
        let fixture = try RecorderFixture()
        fixture.session.startError = ProbeError.coreAudio("start failed")
        let record = try fixture.recorder.prepareRecord(for: fixture.target)

        await XCTAssertThrowsErrorAsync(
            try await fixture.recorder.startRecording(target: fixture.target, record: record)
        ) { error in
            XCTAssertEqual(String(describing: error), "Core Audio error: start failed")
        }

        XCTAssertEqual(fixture.recorder.state, .prepared(record.id))
        let diagnostics = try JSONDecoder.meetingAgent.decode(
            CaptureDiagnostics.self,
            from: Data(contentsOf: XCTUnwrap(record.diagnosticsURL))
        )
        XCTAssertEqual(diagnostics.endedReason, .captureFailed)
        XCTAssertEqual(diagnostics.status, .captureFailed)
    }

    func testRecorderDrainsTranscriptUpdatesWithoutReadingTranscriptFile() async throws {
        let fixture = try RecorderFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storeRoot) }
        let record = try fixture.recorder.prepareRecord(for: fixture.target, startedAt: Date(timeIntervalSince1970: 100))
        try await fixture.recorder.startRecording(target: fixture.target, record: record)

        fixture.transcriber.emit(.upsert(TranscriptSegment(
            id: "segment-1",
            text: "hello live",
            language: "en-US",
            sourceProvider: "fake",
            isFinal: true
        )))

        let updates = fixture.recorder.drainTranscriptUpdates()

        XCTAssertEqual(updates.flatMap { $0.document.segments.map(\.text) }, ["hello live"])
    }

    func testRecorderDrainsRealtimeTranscriptUpdatesWithoutPersistingTranscript() async throws {
        let fixture = try RecorderFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storeRoot) }
        let record = try fixture.recorder.prepareRecord(for: fixture.target, startedAt: Date(timeIntervalSince1970: 100))
        try await fixture.recorder.startRecording(target: fixture.target, record: record)

        fixture.transcriber.emitRealtime(.upsert(TranscriptSegment(
            id: "deepgram-transcribe-stream-0.0",
            text: "live draft",
            language: "en-US",
            sourceProvider: "deepgram-transcribe",
            isFinal: false
        )))

        let updates = fixture.recorder.drainTranscriptUpdates()
        let persisted = try MeetingTranscriptStore.readDocument(from: XCTUnwrap(record.transcriptJSONURL))
            .transcriptDocument

        XCTAssertEqual(updates.last?.source, .realtime)
        XCTAssertEqual(updates.last?.document.segments.map(\.text), ["live draft"])
        XCTAssertEqual(persisted.segments, [])
    }

    func testRecorderBuffersTranscriptArtifactsUntilStop() async throws {
        let fixture = try RecorderFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storeRoot) }
        let record = try fixture.recorder.prepareRecord(for: fixture.target, startedAt: Date(timeIntervalSince1970: 100))
        try await fixture.recorder.startRecording(target: fixture.target, record: record)

        fixture.transcriber.emit(.upsert(TranscriptSegment(
            id: "segment-1",
            text: "persist me",
            language: "en-US",
            sourceProvider: "fake",
            isFinal: true
        )))

        _ = fixture.recorder.drainTranscriptUpdates()

        XCTAssertNil(record.transcriptURL)
        XCTAssertTrue(try MeetingTranscriptStore.readDocument(from: XCTUnwrap(record.transcriptJSONURL)).turns.isEmpty)

        _ = try fixture.recorder.stopRecording(at: Date(timeIntervalSince1970: 200))

        let document = try MeetingTranscriptStore.readDocument(from: XCTUnwrap(record.transcriptJSONURL))
        XCTAssertEqual(document.turns.map(\.text), ["persist me"])
        let transcriptTextURL = try XCTUnwrap(record.transcriptJSONURL)
            .deletingLastPathComponent()
            .appendingPathComponent("transcript.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: transcriptTextURL.path))
        XCTAssertEqual(try transcriptEventLogLineCount(for: record), 1)
    }

    func testRecorderStopPreservesSpeechEventCaptionDocument() async throws {
        let fixture = try RecorderFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storeRoot) }
        let record = try fixture.recorder.prepareRecord(for: fixture.target, startedAt: Date(timeIntervalSince1970: 100))
        try await fixture.recorder.startRecording(target: fixture.target, record: record)

        fixture.transcriber.emitSpeechEvent(.final(SpeechUtterancePayload(
            providerID: "deepgram-transcribe",
            providerResultID: "result-1",
            providerUtteranceID: "utt-1",
            speaker: TranscriptSpeaker(identifier: "speaker-0"),
            startTimeSeconds: 1,
            endTimeSeconds: 2,
            text: "我们确认负责人。",
            language: "zh-CN",
            confidence: 0.9,
            boundary: SpeechBoundary(speechFinal: true)
        )))
        _ = fixture.recorder.drainTranscriptUpdates()

        _ = try fixture.recorder.stopRecording(at: Date(timeIntervalSince1970: 200))

        let data = try Data(contentsOf: XCTUnwrap(record.transcriptJSONURL))
        let captionDocument = try JSONDecoder.meetingAgent.decode(CaptionDocument.self, from: data)
        XCTAssertEqual(captionDocument.version, 2)
        XCTAssertEqual(captionDocument.turns.map(\.text), ["我们确认负责人。"])
    }

    func testRecorderStopPersistsMergedProcessAndMicrophoneSpeechEvents() async throws {
        let fixture = try RecorderFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storeRoot) }
        let record = try fixture.recorder.prepareRecord(
            named: "Zoom",
            source: .processWithMicrophone(fixture.target),
            startedAt: Date(timeIntervalSince1970: 100)
        )
        try await fixture.recorder.startRecording(
            source: .processWithMicrophone(fixture.target),
            record: record,
            speechConfiguration: .default
        )

        fixture.processTranscriber.emitSpeechEvent(.final(testSpeechPayload(
            speakerID: "deepgram-speaker-1",
            text: "Remote participant speaking."
        )))
        fixture.microphoneTranscriber.emitSpeechEvent(.final(testSpeechPayload(
            speakerID: "provider-speaker-1",
            text: "I agree with the launch owner."
        )))
        _ = fixture.recorder.drainTranscriptUpdates()

        _ = try fixture.recorder.stopRecording(at: Date(timeIntervalSince1970: 200))

        let captionDocument = try MeetingTranscriptStore.readDocument(from: XCTUnwrap(record.transcriptJSONURL))
        XCTAssertTrue(captionDocument.turns.contains {
            $0.speakerID == "deepgram-speaker-1" && $0.speakerLabel != "Me"
        })
        XCTAssertTrue(captionDocument.turns.contains {
            $0.speakerID == "local-user" && $0.speakerLabel == "Me"
        })
    }

    func testTranscriptUpdatePipelineLogsEmittedAndPersistedEvents() async throws {
        let fixture = try RecorderFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storeRoot) }
        let record = try fixture.recorder.prepareRecord(for: fixture.target, startedAt: Date(timeIntervalSince1970: 100))
        try await fixture.recorder.startRecording(target: fixture.target, record: record)

        fixture.transcriber.emit(.upsert(TranscriptSegment(
            id: "segment-1",
            text: "hello",
            sourceProvider: "fake",
            isFinal: true
        )))
        _ = fixture.recorder.drainTranscriptUpdates()

        let events = try performanceEventNames(at: XCTUnwrap(record.performanceEventsURL))
        XCTAssertTrue(events.contains("transcript_segment_emitted"))
        XCTAssertTrue(events.contains("transcript_segment_persisted"))
    }
}

private struct RecorderFixture {
    let storeRoot: URL
    let store: MeetingStore
    let processSession: FakeRecorderCaptureSession
    let microphoneSession: FakeRecorderCaptureSession
    let session: FakeRecorderCaptureSession
    let processWriter: FakeAudioFrameWriter
    let microphoneWriter: FakeAudioFrameWriter
    let writer: FakeAudioFrameWriter
    let writerFactory: FakeAudioFrameWriterFactory
    let processTranscriber: FakeAudioFrameTranscriber
    let microphoneTranscriber: FakeAudioFrameTranscriber
    let transcriber: FakeAudioFrameTranscriber
    let transcriberFactory: FakeRecorderTranscriberFactory
    let recorder: MeetingRecorder
    let target = AudioCaptureTarget(processID: 1, displayName: "Google Chrome", bundleIdentifier: "com.google.Chrome")

    init() throws {
        let storeRoot = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-recorder-\(UUID().uuidString)", isDirectory: true)
        let processSession = FakeRecorderCaptureSession(sampleRate: 16_000, channelCount: 1, frameBufferCapacity: 256)
        let microphoneSession = FakeRecorderCaptureSession(sampleRate: 16_000, channelCount: 1, frameBufferCapacity: 256)
        let processWriter = FakeAudioFrameWriter()
        let microphoneWriter = FakeAudioFrameWriter()
        let writerFactory = FakeAudioFrameWriterFactory(
            processWriter: processWriter,
            microphoneWriter: microphoneWriter
        )
        let processTranscriber = FakeAudioFrameTranscriber()
        let microphoneTranscriber = FakeAudioFrameTranscriber()
        let transcriberFactory = FakeRecorderTranscriberFactory(
            processTranscriber: processTranscriber,
            microphoneTranscriber: microphoneTranscriber
        )
        self.storeRoot = storeRoot
        let store = MeetingStore(baseDirectory: storeRoot)
        self.store = store
        self.processSession = processSession
        self.microphoneSession = microphoneSession
        self.session = processSession
        self.processWriter = processWriter
        self.microphoneWriter = microphoneWriter
        self.writer = processWriter
        self.writerFactory = writerFactory
        self.processTranscriber = processTranscriber
        self.microphoneTranscriber = microphoneTranscriber
        self.transcriber = processTranscriber
        self.transcriberFactory = transcriberFactory
        recorder = MeetingRecorder(
            store: store,
            processCaptureSessionFactory: { processSession },
            microphoneCaptureSessionFactory: { microphoneSession },
            wavWriterFactory: writerFactory.makeWriter,
            transcriberFactory: transcriberFactory.startTranscriber
        )
    }
}

private final class FakeRecorderCaptureSession: AudioCaptureSessionManaging {
    let frameBuffer: AudioFrameRingBuffer
    let outputSampleRate: Double
    let outputChannelCount: Int
    var startError: Error?
    var startedSources: [AudioCaptureSource] = []
    var startedTargets: [AudioCaptureTarget] = []
    var stopCallCount = 0

    init(sampleRate: Double, channelCount: Int, frameBufferCapacity: Int = 8) {
        frameBuffer = AudioFrameRingBuffer(capacity: frameBufferCapacity)
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

private final class FakeAudioFrameWriter: AudioFrameWriting {
    var writtenFrames: [AudioFrame] = []
    var closeCallCount = 0

    func append(_ frame: AudioFrame) throws {
        writtenFrames.append(frame)
    }

    func close() throws {
        closeCallCount += 1
    }
}

private final class FakeAudioFrameWriterFactory {
    struct Request {
        let url: URL
        let sampleRate: UInt32
        let channelCount: UInt16
    }

    var requests: [Request] = []
    var onMakeWriter: (() -> Void)?
    private let processWriter: FakeAudioFrameWriter
    private let microphoneWriter: FakeAudioFrameWriter

    init(processWriter: FakeAudioFrameWriter, microphoneWriter: FakeAudioFrameWriter) {
        self.processWriter = processWriter
        self.microphoneWriter = microphoneWriter
    }

    func makeWriter(url: URL, sampleRate: UInt32, channelCount: UInt16) throws -> AudioFrameWriting {
        requests.append(Request(url: url, sampleRate: sampleRate, channelCount: channelCount))
        onMakeWriter?()
        if url.lastPathComponent == "audio-microphone.wav" {
            return microphoneWriter
        }
        return processWriter
    }
}

private final class FakeAudioFrameTranscriber: AudioFrameTranscriber {
    var failureReason: String?
    var appendError: Error?
    var appendedFrames: [AudioFrame] = []
    var finishCallCount = 0
    var transcriptUpdateSink: TranscriptUpdateSink?
    var speechEventSink: SpeechRecognitionEventSink?

    func append(_ frame: AudioFrame) throws {
        if let appendError {
            throw appendError
        }
        appendedFrames.append(frame)
    }

    func finish() {
        finishCallCount += 1
    }

    func emit(_ update: TranscriptSegmentUpdate) {
        transcriptUpdateSink?.receive(update)
    }

    func emitRealtime(_ update: TranscriptSegmentUpdate) {
        transcriptUpdateSink?.receiveRealtime(update)
    }

    func emitSpeechEvent(_ event: SpeechRecognitionEvent) {
        (speechEventSink ?? transcriptUpdateSink as? SpeechRecognitionEventSink)?.receive(event)
    }
}

private final class FakeRecorderTranscriberFactory {
    struct Request {
        let localeIdentifier: String
        let sampleRate: Double
        let channelCount: Int
    }

    var requests: [Request] = []
    var error: Error?
    var shouldSuspend = false
    private let processTranscriber: FakeAudioFrameTranscriber
    private let microphoneTranscriber: FakeAudioFrameTranscriber
    private var continuation: CheckedContinuation<Void, Never>?

    init(processTranscriber: FakeAudioFrameTranscriber, microphoneTranscriber: FakeAudioFrameTranscriber) {
        self.processTranscriber = processTranscriber
        self.microphoneTranscriber = microphoneTranscriber
    }

    func startTranscriber(
        configuration: SpeechTranscriptionConfiguration,
        transcriptURL: URL,
        sampleRate: Double,
        channelCount: Int,
        performanceEventLogger: PerformanceEventLogger?,
        transcriptUpdateSink: TranscriptUpdateSink?,
        speechEventSink: SpeechRecognitionEventSink?
    ) async throws -> AudioFrameTranscriber {
        requests.append(Request(
            localeIdentifier: configuration.localeIdentifier,
            sampleRate: sampleRate,
            channelCount: channelCount
        ))
        if shouldSuspend {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        if let error {
            throw error
        }
        let transcriber = requests.count == 1 ? processTranscriber : microphoneTranscriber
        transcriber.transcriptUpdateSink = transcriptUpdateSink
        transcriber.speechEventSink = speechEventSink
        return transcriber
    }

    func resume() {
        shouldSuspend = false
        continuation?.resume()
        continuation = nil
    }
}

private func waitFor(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
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
    XCTAssertTrue(condition(), "Timed out waiting for condition")
}

private func firstRecorderEvent(
    from events: AsyncStream<MeetingRecorderEvent>,
    matching predicate: (MeetingRecorderEvent) -> Bool
) async -> MeetingRecorderEvent? {
    for await event in events where predicate(event) {
        return event
    }
    return nil
}

private func waitForValue<T>(
    from task: Task<T, Never>,
    timeoutNanoseconds: UInt64 = 1_000_000_000
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            await task.value
        }
        group.addTask {
            try await Task.sleep(nanoseconds: timeoutNanoseconds)
            task.cancel()
            throw RecorderTestTimeout()
        }
        guard let value = try await group.next() else {
            throw RecorderTestTimeout()
        }
        group.cancelAll()
        return value
    }
}

private struct RecorderTestTimeout: Error {}

private func performanceEventNames(at url: URL) throws -> [String] {
    try performanceEvents(at: url).map(\.event)
}

private func performanceEvents(at url: URL) throws -> [PerformanceEvent] {
    try String(contentsOf: url, encoding: .utf8)
        .split(separator: "\n")
        .map { try JSONDecoder.meetingAgent.decode(PerformanceEvent.self, from: Data($0.utf8)) }
}

private func transcriptEventLogLineCount(for record: MeetingRecord) throws -> Int {
    let eventLogURL = try XCTUnwrap(record.transcriptJSONURL)
        .deletingLastPathComponent()
        .appendingPathComponent("transcript-events.jsonl")
    return try String(contentsOf: eventLogURL, encoding: .utf8)
        .split(whereSeparator: \.isNewline)
        .count
}

private func testSpeechPayload(speakerID: String, text: String) -> SpeechUtterancePayload {
    SpeechUtterancePayload(
        providerID: "deepgram-transcribe",
        providerResultID: "result-\(speakerID)",
        providerUtteranceID: "utt-\(speakerID)",
        speaker: TranscriptSpeaker(identifier: speakerID),
        startTimeSeconds: 1,
        endTimeSeconds: 2,
        text: text,
        language: "en-US",
        confidence: 0.9,
        boundary: SpeechBoundary(speechFinal: true)
    )
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
