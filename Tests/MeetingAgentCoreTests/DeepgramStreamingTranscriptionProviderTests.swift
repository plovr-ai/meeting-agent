import XCTest
@testable import MeetingAgentCore

final class DeepgramStreamingTranscriptionProviderTests: XCTestCase {
    func testURLSessionStreamingClientBuildsRequestAndStartsSession() async throws {
        let task = FakeDeepgramWebSocketTask()
        var capturedRequest: URLRequest?
        let client = URLSessionDeepgramStreamingTranscriptionClient { request in
            capturedRequest = request
            return task
        }

        let session = try await client.connect(
            configuration: DeepgramTranscriptionConfiguration(apiKey: "key", model: "nova-3"),
            sampleRate: 16_000.4,
            channelCount: 0
        )

        XCTAssertTrue(session is URLSessionDeepgramStreamingSession)
        XCTAssertEqual(task.resumeCallCount, 1)
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Authorization"), "Token key")
        let components = try XCTUnwrap(URLComponents(url: XCTUnwrap(capturedRequest?.url), resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["model"], "nova-3")
        XCTAssertNil(query["language"])
        XCTAssertEqual(query["sample_rate"], "16000")
        XCTAssertEqual(query["channels"], "1")
        XCTAssertEqual(query["interim_results"], "true")
        XCTAssertEqual(query["endpointing"], "500")
    }

    func testURLSessionStreamingClientRejectsUnavailableConfiguration() async {
        let client = URLSessionDeepgramStreamingTranscriptionClient { _ in FakeDeepgramWebSocketTask() }

        do {
            _ = try await client.connect(
                configuration: DeepgramTranscriptionConfiguration(apiKey: nil, model: "nova-3"),
                sampleRate: 16_000,
                channelCount: 1
            )
            XCTFail("Expected unavailable configuration")
        } catch {
            XCTAssertEqual(String(describing: error), "Deepgram configuration is unavailable")
        }
    }

    func testURLSessionStreamingSessionSendsReceivesAndClosesSocket() async throws {
        let task = FakeDeepgramWebSocketTask()
        let session = URLSessionDeepgramStreamingSession(task: task)
        let received = TranscriptSegmentCollector()
        let receiveTask = Task {
            for await segment in session.segments {
                await received.append(segment)
            }
        }
        try await Task.sleep(nanoseconds: 10_000_000)

        task.completeReceive(.success(.string("""
        {
          "is_final": true,
          "channel": {
            "alternatives": [
              { "transcript": "hello", "confidence": 0.7, "words": [] }
            ]
          }
        }
        """)))
        task.completeReceive(.success(.data(Data(#"{"is_final":false}"#.utf8))))
        task.completeReceive(.failure(ProbeError.speechRecognition("closed")))
        try await session.send(AudioFrame(pcm: Data([1, 2, 3]), sampleRate: 16_000, channelCount: 1, timestampNanos: 1))
        try await Task.sleep(nanoseconds: 10_000_000)
        await session.close()
        await receiveTask.value

        let receivedTexts = await received.texts
        XCTAssertEqual(receivedTexts, ["hello"])
        XCTAssertEqual(task.sentMessages.count, 2)
        if case .data(let data) = task.sentMessages.first {
            XCTAssertEqual(data, Data([1, 2, 3]))
        } else {
            XCTFail("Expected data message")
        }
        if case .string(let text) = task.sentMessages.last {
            XCTAssertEqual(text, #"{"type":"Finalize"}"#)
        } else {
            XCTFail("Expected finalize message")
        }
        XCTAssertEqual(task.cancelCloseCode, .normalClosure)
    }

    func testStreamingProviderSendsAudioFramesAndWritesIncomingTranscriptSegments() async throws {
        let transcriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("deepgram-stream-\(UUID().uuidString)")
            .appendingPathExtension("txt")
        defer {
            try? FileManager.default.removeItem(at: transcriptURL)
            try? FileManager.default.removeItem(at: transcriptURL.deletingPathExtension().appendingPathExtension("json"))
        }
        let session = FakeDeepgramStreamingSession()
        let client = FakeDeepgramStreamingClient(session: session)
        let provider = DeepgramStreamingSpeechTranscriptionProvider(
            configuration: DeepgramTranscriptionConfiguration(apiKey: "key", model: "nova-3"),
            client: client
        )

        let transcriber = try await provider.start(context: SpeechTranscriptionStreamContext(
            transcriptURL: transcriptURL,
            localeIdentifier: "en-US",
            sampleRate: 48_000,
            channelCount: 1
        ))
        let frame = AudioFrame(pcm: Data([1, 2, 3, 4]), sampleRate: 48_000, channelCount: 1, timestampNanos: 10)

        try transcriber.append(frame)
        session.yield(TranscriptSegment(
            id: "dg-1",
            startTimeSeconds: 0.1,
            endTimeSeconds: 0.5,
            text: "hello live",
            language: "en-US",
            sourceProvider: "deepgram-transcribe",
            confidence: 0.92,
            timingSource: .precise
        ))
        try await Task.sleep(nanoseconds: 30_000_000)
        transcriber.finish()

        XCTAssertEqual(client.requests.first?.apiKey, "key")
        XCTAssertEqual(client.requests.first?.model, "nova-3")
        XCTAssertEqual(client.requests.first?.sampleRate, 48_000)
        XCTAssertEqual(client.requests.first?.channelCount, 1)
        XCTAssertEqual(session.sentFrames, [frame])
        let document = try TranscriptFileWriter.readDocument(
            from: transcriptURL.deletingPathExtension().appendingPathExtension("json")
        )
        XCTAssertEqual(document.segments.first?.text, "hello live")
        XCTAssertEqual(document.segments.first?.sourceProvider, "deepgram-transcribe")
    }

    func testStreamingResponseMapsInterimTranscriptToNonFinalSegment() throws {
        let data = Data("""
        {
          "is_final": false,
          "channel": {
            "alternatives": [
              { "transcript": "hello interim", "confidence": 0.6, "words": [] }
            ]
          }
        }
        """.utf8)

        let segments = DeepgramStreamingResponseMapper.segments(
            from: data,
            localeIdentifier: "en-US",
            providerID: "deepgram-transcribe"
        )

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.id, "deepgram-transcribe-stream-active")
        XCTAssertEqual(segments.first?.text, "hello interim")
        XCTAssertEqual(segments.first?.isFinal, false)
    }

    func testStreamingProviderReplacesInterimSegmentWithFinalSegment() async throws {
        let transcriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("deepgram-stream-interim-\(UUID().uuidString)")
            .appendingPathExtension("txt")
        defer {
            try? FileManager.default.removeItem(at: transcriptURL)
            try? FileManager.default.removeItem(at: transcriptURL.deletingPathExtension().appendingPathExtension("json"))
        }
        let session = FakeDeepgramStreamingSession()
        let client = FakeDeepgramStreamingClient(session: session)
        let provider = DeepgramStreamingSpeechTranscriptionProvider(
            configuration: DeepgramTranscriptionConfiguration(apiKey: "key", model: "nova-3"),
            client: client
        )
        let transcriber = try await provider.start(context: SpeechTranscriptionStreamContext(
            transcriptURL: transcriptURL,
            localeIdentifier: "en-US",
            sampleRate: 48_000,
            channelCount: 1
        ))

        session.yieldJSON("""
        {
          "is_final": false,
          "channel": {
            "alternatives": [
              { "transcript": "hello", "confidence": 0.6, "words": [] }
            ]
          }
        }
        """)
        session.yieldJSON("""
        {
          "is_final": true,
          "channel": {
            "alternatives": [
              { "transcript": "hello world", "confidence": 0.9, "words": [] }
            ]
          }
        }
        """)
        try await Task.sleep(nanoseconds: 30_000_000)
        transcriber.finish()

        let document = try TranscriptFileWriter.readDocument(
            from: transcriptURL.deletingPathExtension().appendingPathExtension("json")
        )
        XCTAssertEqual(document.segments.map(\.id), ["deepgram-transcribe-stream-active-0"])
        XCTAssertEqual(document.segments.map(\.text), ["hello world"])
        XCTAssertEqual(document.segments.map(\.isFinal), [true])
    }

    func testStreamingProviderAppendsSeparateFinalSegmentsWithoutWordTimings() async throws {
        let transcriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("deepgram-stream-no-words-\(UUID().uuidString)")
            .appendingPathExtension("txt")
        defer {
            try? FileManager.default.removeItem(at: transcriptURL)
            try? FileManager.default.removeItem(at: transcriptURL.deletingPathExtension().appendingPathExtension("json"))
        }
        let session = FakeDeepgramStreamingSession()
        let client = FakeDeepgramStreamingClient(session: session)
        let provider = DeepgramStreamingSpeechTranscriptionProvider(
            configuration: DeepgramTranscriptionConfiguration(apiKey: "key", model: "nova-3"),
            client: client
        )
        let transcriber = try await provider.start(context: SpeechTranscriptionStreamContext(
            transcriptURL: transcriptURL,
            localeIdentifier: "en-US",
            sampleRate: 48_000,
            channelCount: 1
        ))

        session.yieldJSON("""
        {
          "is_final": true,
          "channel": {
            "alternatives": [
              { "transcript": "first final", "confidence": 0.9, "words": [] }
            ]
          }
        }
        """)
        session.yieldJSON("""
        {
          "is_final": true,
          "channel": {
            "alternatives": [
              { "transcript": "second final", "confidence": 0.9, "words": [] }
            ]
          }
        }
        """)
        try await Task.sleep(nanoseconds: 30_000_000)
        transcriber.finish()

        let document = try TranscriptFileWriter.readDocument(
            from: transcriptURL.deletingPathExtension().appendingPathExtension("json")
        )
        XCTAssertEqual(document.segments.map(\.text), ["first final", "second final"])
        XCTAssertEqual(document.segments.map(\.isFinal), [true, true])
    }

    func testStreamingResponseKeepsStableIDWhenInterimWordEndTimeChanges() throws {
        let first = DeepgramStreamingResponseMapper.segments(
            from: Data("""
            {
              "is_final": false,
              "channel": {
                "alternatives": [
                  {
                    "transcript": "hello",
                    "confidence": 0.6,
                    "words": [
                      { "word": "hello", "punctuated_word": "hello", "start": 0.0, "end": 0.4, "speaker": 0 }
                    ]
                  }
                ]
              }
            }
            """.utf8),
            localeIdentifier: "en-US",
            providerID: "deepgram-transcribe"
        )
        let updated = DeepgramStreamingResponseMapper.segments(
            from: Data("""
            {
              "is_final": false,
              "channel": {
                "alternatives": [
                  {
                    "transcript": "hello world",
                    "confidence": 0.7,
                    "words": [
                      { "word": "hello", "punctuated_word": "hello", "start": 0.0, "end": 0.4, "speaker": 0 },
                      { "word": "world", "punctuated_word": "world", "start": 0.4, "end": 0.8, "speaker": 0 }
                    ]
                  }
                ]
              }
            }
            """.utf8),
            localeIdentifier: "en-US",
            providerID: "deepgram-transcribe"
        )

        XCTAssertEqual(first.first?.id, updated.first?.id)
    }

    func testStreamingResponseSplitsFinalTranscriptByConsecutiveDeepgramSpeakers() async throws {
        let transcriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("deepgram-stream-speakers-\(UUID().uuidString)")
            .appendingPathExtension("txt")
        defer {
            try? FileManager.default.removeItem(at: transcriptURL)
            try? FileManager.default.removeItem(at: transcriptURL.deletingPathExtension().appendingPathExtension("json"))
        }
        let session = FakeDeepgramStreamingSession()
        let client = FakeDeepgramStreamingClient(session: session)
        let provider = DeepgramStreamingSpeechTranscriptionProvider(
            configuration: DeepgramTranscriptionConfiguration(apiKey: "key", model: "nova-3"),
            client: client
        )
        let transcriber = try await provider.start(context: SpeechTranscriptionStreamContext(
            transcriptURL: transcriptURL,
            localeIdentifier: "en-US",
            sampleRate: 48_000,
            channelCount: 1
        ))

        session.yieldJSON("""
        {
          "is_final": true,
          "channel": {
            "alternatives": [
              {
                "transcript": "hello team yes",
                "confidence": 0.92,
                "words": [
                  { "word": "hello", "punctuated_word": "Hello", "start": 0.0, "end": 0.4, "speaker": 0 },
                  { "word": "team", "punctuated_word": "team.", "start": 0.4, "end": 0.8, "speaker": 0 },
                  { "word": "yes", "punctuated_word": "Yes.", "start": 0.9, "end": 1.1, "speaker": 1 }
                ]
              }
            ]
          }
        }
        """)
        try await Task.sleep(nanoseconds: 30_000_000)
        transcriber.finish()

        let document = try TranscriptFileWriter.readDocument(
            from: transcriptURL.deletingPathExtension().appendingPathExtension("json")
        )
        XCTAssertEqual(document.segments.map(\.speakerID), ["deepgram-speaker-0", "deepgram-speaker-1"])
        XCTAssertEqual(document.segments.map(\.speakerLabel), ["User A", "User B"])
        XCTAssertEqual(document.segments.map(\.text), ["Hello team.", "Yes."])
        XCTAssertEqual(document.segments.map(\.startTimeSeconds), [0.0, 0.9])
        XCTAssertEqual(document.segments.map(\.endTimeSeconds), [0.8, 1.1])
    }

    func testStreamingResponseMarksOnlyLastSpeakerRunAsSpeechFinal() throws {
        let segments = DeepgramStreamingResponseMapper.segments(
            from: Data("""
            {
              "is_final": true,
              "speech_final": true,
              "channel": {
                "alternatives": [
                  {
                    "transcript": "hello yes",
                    "confidence": 0.91,
                    "words": [
                      { "word": "hello", "punctuated_word": "Hello.", "start": 0.0, "end": 0.4, "speaker": 0 },
                      { "word": "yes", "punctuated_word": "Yes.", "start": 0.5, "end": 0.8, "speaker": 1 }
                    ]
                  }
                ]
              }
            }
            """.utf8),
            providerID: "deepgram-transcribe"
        )

        XCTAssertEqual(segments.map(\.text), ["Hello.", "Yes."])
        XCTAssertEqual(segments.map(\.speechFinal), [false, true])
    }
}

private actor TranscriptSegmentCollector {
    private var segments: [TranscriptSegment] = []

    var texts: [String] {
        segments.map(\.text)
    }

    func append(_ segment: TranscriptSegment) {
        segments.append(segment)
    }

    func values() -> [TranscriptSegment] {
        segments
    }
}

private final class FakeDeepgramWebSocketTask: DeepgramWebSocketTask {
    var resumeCallCount = 0
    var sentMessages: [URLSessionWebSocketTask.Message] = []
    var cancelCloseCode: URLSessionWebSocketTask.CloseCode?
    private var receiveHandlers: [(Result<URLSessionWebSocketTask.Message, Error>) -> Void] = []
    private var pendingResults: [Result<URLSessionWebSocketTask.Message, Error>] = []

    func resume() {
        resumeCallCount += 1
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        sentMessages.append(message)
    }

    func receive(completionHandler: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
        if !pendingResults.isEmpty {
            completionHandler(pendingResults.removeFirst())
            return
        }
        receiveHandlers.append(completionHandler)
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        cancelCloseCode = closeCode
    }

    func completeReceive(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
        guard !receiveHandlers.isEmpty else {
            pendingResults.append(result)
            return
        }
        let handler = receiveHandlers.removeFirst()
        handler(result)
    }
}

private final class FakeDeepgramStreamingClient: DeepgramStreamingTranscriptionClient {
    struct Request: Equatable {
        let apiKey: String
        let model: String
        let sampleRate: Double
        let channelCount: Int
    }

    private(set) var requests: [Request] = []
    private let session: FakeDeepgramStreamingSession

    init(session: FakeDeepgramStreamingSession) {
        self.session = session
    }

    func connect(
        configuration: DeepgramTranscriptionConfiguration,
        sampleRate: Double,
        channelCount: Int
    ) async throws -> DeepgramStreamingTranscriptionSession {
        requests.append(Request(
            apiKey: configuration.apiKey,
            model: configuration.model,
            sampleRate: sampleRate,
            channelCount: channelCount
        ))
        return session
    }
}

private final class FakeDeepgramStreamingSession: DeepgramStreamingTranscriptionSession {
    private var continuation: AsyncStream<TranscriptSegment>.Continuation?
    private(set) var sentFrames: [AudioFrame] = []
    let segments: AsyncStream<TranscriptSegment>

    init() {
        var streamContinuation: AsyncStream<TranscriptSegment>.Continuation!
        self.segments = AsyncStream { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation
    }

    func send(_ frame: AudioFrame) async throws {
        sentFrames.append(frame)
    }

    func close() async {
        continuation?.finish()
    }

    func yield(_ segment: TranscriptSegment) {
        continuation?.yield(segment)
    }

    func yieldJSON(_ json: String) {
        for segment in DeepgramStreamingResponseMapper.segments(
            from: Data(json.utf8),
            providerID: "deepgram-transcribe"
        ) {
            continuation?.yield(segment)
        }
    }
}
