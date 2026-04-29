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

    func testRecorderPersistsCanonicalTranscriptFromUpdates() async throws {
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

        let document = try TranscriptFileWriter.readDocument(from: XCTUnwrap(record.transcriptJSONURL))
        XCTAssertEqual(document.segments.map(\.text), ["persist me"])
    }
}

private struct RecorderFixture {
    let storeRoot: URL
    let store: MeetingStore
    let session: FakeRecorderCaptureSession
    let writer: FakeAudioFrameWriter
    let writerFactory: FakeAudioFrameWriterFactory
    let transcriber: FakeAudioFrameTranscriber
    let transcriberFactory: FakeRecorderTranscriberFactory
    let recorder: MeetingRecorder
    let target = AudioCaptureTarget(processID: 1, displayName: "Google Chrome", bundleIdentifier: "com.google.Chrome")

    init() throws {
        let storeRoot = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-recorder-\(UUID().uuidString)", isDirectory: true)
        let session = FakeRecorderCaptureSession(sampleRate: 16_000, channelCount: 1)
        let writer = FakeAudioFrameWriter()
        let writerFactory = FakeAudioFrameWriterFactory(writer: writer)
        let transcriber = FakeAudioFrameTranscriber()
        let transcriberFactory = FakeRecorderTranscriberFactory(transcriber: transcriber)
        self.storeRoot = storeRoot
        let store = MeetingStore(baseDirectory: storeRoot)
        self.store = store
        self.session = session
        self.writer = writer
        self.writerFactory = writerFactory
        self.transcriber = transcriber
        self.transcriberFactory = transcriberFactory
        recorder = MeetingRecorder(
            store: store,
            captureSessionFactory: { session },
            wavWriterFactory: writerFactory.makeWriter,
            transcriberFactory: transcriberFactory.startTranscriber
        )
    }
}

private final class FakeRecorderCaptureSession: AudioCaptureSessionManaging {
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
    private let writer: FakeAudioFrameWriter

    init(writer: FakeAudioFrameWriter) {
        self.writer = writer
    }

    func makeWriter(url: URL, sampleRate: UInt32, channelCount: UInt16) throws -> AudioFrameWriting {
        requests.append(Request(url: url, sampleRate: sampleRate, channelCount: channelCount))
        onMakeWriter?()
        return writer
    }
}

private final class FakeAudioFrameTranscriber: AudioFrameTranscriber {
    var failureReason: String?
    var appendError: Error?
    var appendedFrames: [AudioFrame] = []
    var finishCallCount = 0
    var transcriptUpdateSink: TranscriptUpdateSink?

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
    private let transcriber: FakeAudioFrameTranscriber
    private var continuation: CheckedContinuation<Void, Never>?

    init(transcriber: FakeAudioFrameTranscriber) {
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
        transcriber.transcriptUpdateSink = transcriptUpdateSink
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

private func performanceEventNames(at url: URL) throws -> [String] {
    try String(contentsOf: url, encoding: .utf8)
        .split(separator: "\n")
        .map { try JSONDecoder.meetingAgent.decode(PerformanceEvent.self, from: Data($0.utf8)).event }
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
