import AVFoundation
import Speech
import XCTest
@testable import MeetingAgentCore

final class SystemSpeechTranscriberTests: XCTestCase {
    func testSpeechAudioBufferFactoryRejectsMisalignedPCM() {
        XCTAssertThrowsError(try SpeechAudioBufferFactory.buffer(from: AudioFrame(
            pcm: Data([1, 2, 3]),
            sampleRate: 16_000,
            channelCount: 2,
            timestampNanos: 0
        ))) { error in
            XCTAssertEqual(String(describing: error), "Speech recognition error: Audio frame is not aligned to 16-bit PCM samples")
        }
    }

    func testLiveSpeechRequestConfiguresDictationRequestAndRejectsWrongRecognizerRequestType() {
        let request = LiveSystemSpeechRequest()
        request.configureForDictation()

        XCTAssertTrue(request.request.shouldReportPartialResults)
        XCTAssertEqual(request.request.taskHint, .dictation)
        XCTAssertNil(LiveSystemSpeechRecognizer(locale: Locale(identifier: "en-US")).recognitionTask(
            request: FakeSystemSpeechRequest(),
            onUpdate: { _ in }
        ))
        request.endAudio()
    }

    func testLiveSpeechEnvironmentFactoriesCreateAdaptersWithoutRequestingPermission() throws {
        let environment = SystemSpeechEnvironment.live
        let request = environment.requestFactory()
        request.configureForDictation()
        request.endAudio()

        let recognizer = try XCTUnwrap(environment.recognizerFactory(Locale(identifier: "en-US")))
        XCTAssertNil(recognizer.recognitionTask(request: FakeSystemSpeechRequest(), onUpdate: { _ in }))

        let transcriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("live-writer-\(UUID().uuidString).txt")
        let transcriptJSONURL = transcriptURL.deletingPathExtension().appendingPathExtension("json")
        defer {
            try? FileManager.default.removeItem(at: transcriptURL)
            try? FileManager.default.removeItem(at: transcriptJSONURL)
        }
        let writer = try environment.writerFactory(transcriptURL)
        try writer.replace(with: [TranscriptSegment(id: "segment-1", text: "hello")])
        try writer.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: transcriptURL.path))
        let document = try MeetingTranscriptStore.readDocument(from: transcriptJSONURL)
        XCTAssertEqual(document.turns.map(\.text), ["hello"])
    }

    func testStartRejectsDeniedAuthorizationBeforeCreatingRecognizer() async {
        let fixture = SystemSpeechFixture(status: .denied)

        await XCTAssertThrowsErrorAsync(
            try await SystemSpeechTranscriber.start(
                transcriptURL: URL(fileURLWithPath: "/tmp/transcript.txt"),
                localeIdentifier: "en-US",
                environment: fixture.environment()
            )
        ) { error in
            XCTAssertEqual(
                String(describing: error),
                "Speech recognition error: Speech recognition permission is SFSpeechRecognizerAuthorizationStatus(rawValue: 1)"
            )
        }
        XCTAssertTrue(fixture.createdLocales.isEmpty)
    }

    func testStartRejectsUnavailableRecognizer() async {
        let fixture = SystemSpeechFixture(status: .authorized)
        fixture.recognizer.isAvailable = false

        await XCTAssertThrowsErrorAsync(
            try await SystemSpeechTranscriber.start(
                transcriptURL: URL(fileURLWithPath: "/tmp/transcript.txt"),
                localeIdentifier: "zh-CN",
                environment: fixture.environment()
            )
        ) { error in
            XCTAssertEqual(String(describing: error), "Speech recognition error: System speech recognizer is unavailable for locale zh-CN")
        }
        XCTAssertEqual(fixture.createdLocales.map(\.identifier), ["zh-CN"])
    }

    func testStartConfiguresRequestAndWritesRecognitionUpdates() async throws {
        let fixture = SystemSpeechFixture(status: .authorized)
        let transcriber = try await SystemSpeechTranscriber.start(
            transcriptURL: URL(fileURLWithPath: "/tmp/transcript.txt"),
            localeIdentifier: "en-US",
            environment: fixture.environment()
        )

        fixture.recognizer.send(.result(text: "Hello", isFinal: false))
        fixture.recognizer.send(.result(text: "Hello world", isFinal: true))

        XCTAssertEqual(fixture.request.configureCallCount, 1)
        XCTAssertEqual(fixture.recognizer.taskCallCount, 1)
        XCTAssertEqual(fixture.writer.replacedSegments.map { $0.map(\.text) }, [["Hello"], ["Hello world"]])
        XCTAssertEqual(fixture.writer.replacedSegments.last?.first?.language, "en-US")
        XCTAssertEqual(fixture.writer.replacedSegments.last?.first?.sourceProvider, "local")
        XCTAssertEqual(fixture.writer.replacedSegments.last?.first?.isFinal, true)

        transcriber.finish()
        XCTAssertEqual(fixture.request.endAudioCallCount, 1)
        XCTAssertEqual(fixture.task.finishCallCount, 1)
    }

    func testStartWithTranscriptUpdateSinkPublishesUpdatesWithoutCreatingWriter() async throws {
        let fixture = SystemSpeechFixture(status: .authorized)
        let updateSink = RecordingSystemSpeechUpdateSink()
        let transcriber = try await SystemSpeechTranscriber.start(
            transcriptURL: URL(fileURLWithPath: "/tmp/transcript.txt"),
            localeIdentifier: "en-US",
            environment: fixture.environment(),
            transcriptUpdateSink: updateSink
        )

        fixture.recognizer.send(.result(text: "Hello caption", isFinal: true))

        XCTAssertTrue(fixture.writer.replacedSegments.isEmpty)
        XCTAssertEqual(updateSink.updates.count, 1)
        guard case .upsert(let segment) = updateSink.updates.first else {
            return XCTFail("Expected upsert update")
        }
        XCTAssertEqual(segment.text, "Hello caption")
        XCTAssertEqual(segment.sourceProvider, "local")
        XCTAssertTrue(segment.isFinal)

        transcriber.finish()
    }

    func testAppendConvertsAudioFrameAndForwardsBuffer() async throws {
        let fixture = SystemSpeechFixture(status: .authorized)
        let transcriber = try await SystemSpeechTranscriber.start(
            transcriptURL: URL(fileURLWithPath: "/tmp/transcript.txt"),
            localeIdentifier: "en-US",
            environment: fixture.environment()
        )

        try transcriber.append(AudioFrame(pcm: Data([0, 0, 0, 64]), sampleRate: 8_000, channelCount: 2, timestampNanos: 1))

        XCTAssertEqual(fixture.request.appendedBuffers.count, 1)
        XCTAssertEqual(fixture.request.appendedBuffers.first?.format.sampleRate, 8_000)
        XCTAssertEqual(fixture.request.appendedBuffers.first?.frameLength, 1)
    }

    func testRecognitionErrorClosesWriterAndDeinitCancelsTask() async throws {
        let fixture = SystemSpeechFixture(status: .authorized)
        var transcriber: SystemSpeechTranscriber? = try await SystemSpeechTranscriber.start(
            transcriptURL: URL(fileURLWithPath: "/tmp/transcript.txt"),
            localeIdentifier: "en-US",
            environment: fixture.environment()
        )
        XCTAssertNotNil(transcriber)

        fixture.recognizer.send(.failure(ProbeError.speechRecognition("failed")))
        transcriber = nil

        XCTAssertEqual(fixture.writer.closeCallCount, 2)
        XCTAssertEqual(fixture.task.cancelCallCount, 1)
    }
}

private final class SystemSpeechFixture {
    let authorizer: FakeSystemSpeechAuthorizer
    let recognizer = FakeSystemSpeechRecognizer()
    let request = FakeSystemSpeechRequest()
    let writer = FakeSystemSpeechWriter()
    let task = FakeSystemSpeechTask()
    var createdLocales: [Locale] = []

    init(status: SFSpeechRecognizerAuthorizationStatus) {
        authorizer = FakeSystemSpeechAuthorizer(status: status)
        recognizer.task = task
    }

    func environment() -> SystemSpeechEnvironment {
        SystemSpeechEnvironment(
            authorizer: authorizer,
            recognizerFactory: { locale in
                self.createdLocales.append(locale)
                return self.recognizer
            },
            requestFactory: { self.request },
            writerFactory: { _ in self.writer }
        )
    }
}

private final class FakeSystemSpeechAuthorizer: SystemSpeechAuthorizing {
    let status: SFSpeechRecognizerAuthorizationStatus

    init(status: SFSpeechRecognizerAuthorizationStatus) {
        self.status = status
    }

    func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        status
    }
}

private final class FakeSystemSpeechRecognizer: SystemSpeechRecognizing {
    var isAvailable = true
    var task = FakeSystemSpeechTask()
    var taskCallCount = 0
    private var onUpdate: ((SystemSpeechRecognitionUpdate) -> Void)?

    func recognitionTask(
        request: SystemSpeechRequesting,
        onUpdate: @escaping (SystemSpeechRecognitionUpdate) -> Void
    ) -> SystemSpeechTasking? {
        taskCallCount += 1
        self.onUpdate = onUpdate
        return task
    }

    func send(_ update: SystemSpeechRecognitionUpdate) {
        onUpdate?(update)
    }
}

private final class FakeSystemSpeechRequest: SystemSpeechRequesting {
    var configureCallCount = 0
    var appendedBuffers: [AVAudioPCMBuffer] = []
    var endAudioCallCount = 0

    func configureForDictation() {
        configureCallCount += 1
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        appendedBuffers.append(buffer)
    }

    func endAudio() {
        endAudioCallCount += 1
    }
}

private final class FakeSystemSpeechTask: SystemSpeechTasking {
    var finishCallCount = 0
    var cancelCallCount = 0

    func finish() {
        finishCallCount += 1
    }

    func cancel() {
        cancelCallCount += 1
    }
}

private final class FakeSystemSpeechWriter: SystemSpeechWriting {
    var replacedSegments: [[TranscriptSegment]] = []
    var closeCallCount = 0

    func replace(with segments: [TranscriptSegment]) throws {
        replacedSegments.append(segments)
    }

    func close() throws {
        closeCallCount += 1
    }
}

private final class RecordingSystemSpeechUpdateSink: TranscriptUpdateSink {
    var updates: [TranscriptSegmentUpdate] = []

    func receive(_ update: TranscriptSegmentUpdate) {
        updates.append(update)
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
