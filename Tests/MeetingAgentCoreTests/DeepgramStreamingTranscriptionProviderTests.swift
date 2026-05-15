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
        XCTAssertEqual(query["language"], "multi")
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

    func testURLSessionStreamingSessionLogsRawWebSocketResponsesBeforeMapping() async throws {
        let task = FakeDeepgramWebSocketTask()
        let logger = RecordingDeepgramRawResponseLogger()
        let session = URLSessionDeepgramStreamingSession(task: task, rawResponseLogger: logger)
        let received = TranscriptSegmentCollector()
        let receiveTask = Task {
            for await segment in session.segments {
                await received.append(segment)
            }
        }
        try await Task.sleep(nanoseconds: 10_000_000)

        let stringPayload = """
        {
          "is_final": true,
          "channel": {
            "alternatives": [
              { "transcript": "string payload", "confidence": 0.7, "words": [] }
            ]
          }
        }
        """
        let dataPayload = Data(#"{"is_final":false}"#.utf8)
        task.completeReceive(.success(.string(stringPayload)))
        task.completeReceive(.success(.data(dataPayload)))
        task.completeReceive(.failure(ProbeError.speechRecognition("closed")))
        try await Task.sleep(nanoseconds: 10_000_000)
        await session.close()
        await receiveTask.value

        let receivedTexts = await received.texts
        XCTAssertEqual(receivedTexts, ["string payload"])
        XCTAssertEqual(logger.entries.count, 2)
        XCTAssertEqual(logger.entries.map(\.context.providerID), ["deepgram-transcribe", "deepgram-transcribe"])
        XCTAssertEqual(logger.entries.map(\.context.transport), [.webSocket, .webSocket])
        XCTAssertEqual(String(data: logger.entries[0].data, encoding: .utf8), stringPayload)
        XCTAssertEqual(logger.entries[1].data, dataPayload)
    }

    func testURLSessionStreamingSessionLogsStructuredDeepgramResponseMetrics() async throws {
        let task = FakeDeepgramWebSocketTask()
        let performanceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("deepgram-raw-response-\(UUID().uuidString)")
            .appendingPathExtension("jsonl")
        defer { try? FileManager.default.removeItem(at: performanceURL) }
        let session = URLSessionDeepgramStreamingSession(
            task: task,
            performanceEventLogger: PerformanceEventLogger(url: performanceURL)
        )
        let received = TranscriptSegmentCollector()
        let receiveTask = Task {
            for await segment in session.segments {
                await received.append(segment)
            }
        }
        try await Task.sleep(nanoseconds: 10_000_000)

        let payload = """
        {
          "type": "Results",
          "start": 1.25,
          "duration": 2.5,
          "is_final": false,
          "speech_final": true,
          "channel": {
            "alternatives": [
              {
                "transcript": "hello world",
                "confidence": 0.8,
                "words": [
                  { "word": "hello", "punctuated_word": "hello", "start": 1.25, "end": 1.7, "speaker": 0 },
                  { "word": "world", "punctuated_word": "world.", "start": 1.7, "end": 2.1, "speaker": 0 }
                ]
              }
            ]
          },
          "metadata": { "request_id": "request-1" }
        }
        """
        task.completeReceive(.success(.string(payload)))
        task.completeReceive(.failure(ProbeError.speechRecognition("closed")))
        try await Task.sleep(nanoseconds: 10_000_000)
        await session.close()
        await receiveTask.value

        let events = try performanceEvents(at: performanceURL)
        let response = try XCTUnwrap(events.first { $0.event == "deepgram_raw_response_received" })
        XCTAssertEqual(response.audioTimeSeconds, 3.75)
        XCTAssertEqual(response.isFinal, false)
        XCTAssertEqual(response.textLength, 11)
        XCTAssertEqual(response.metadata["providerID"], "deepgram-transcribe")
        XCTAssertEqual(response.metadata["transport"], "webSocket")
        XCTAssertEqual(response.metadata["payloadBytes"], String(Data(payload.utf8).count))
        XCTAssertEqual(response.metadata["responseType"], "Results")
        XCTAssertEqual(response.metadata["responseStartSeconds"], "1.25")
        XCTAssertEqual(response.metadata["responseDurationSeconds"], "2.5")
        XCTAssertEqual(response.metadata["speechFinal"], "true")
        XCTAssertEqual(response.metadata["requestID"], "request-1")
        XCTAssertEqual(response.metadata["firstWordStartSeconds"], "1.25")
        XCTAssertEqual(response.metadata["lastWordEndSeconds"], "2.1")
        XCTAssertEqual(response.metadata["wordCount"], "2")
    }

    func testStreamingProviderSendsAudioFramesAndWritesIncomingTranscriptSegments() async throws {
        let transcriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("deepgram-stream-\(UUID().uuidString)")
            .appendingPathExtension("txt")
        let performanceURL = transcriptURL.deletingLastPathComponent()
            .appendingPathComponent("performance-\(UUID().uuidString)")
            .appendingPathExtension("jsonl")
        defer {
            try? FileManager.default.removeItem(at: transcriptURL)
            try? FileManager.default.removeItem(at: transcriptURL.deletingPathExtension().appendingPathExtension("json"))
            try? FileManager.default.removeItem(at: performanceURL)
        }
        let session = FakeDeepgramStreamingSession()
        let client = FakeDeepgramStreamingClient(session: session)
        let updateSink = RecordingTranscriptUpdateSinkForTests()
        let provider = DeepgramStreamingSpeechTranscriptionProvider(
            configuration: DeepgramTranscriptionConfiguration(apiKey: "key", model: "nova-3"),
            client: client
        )

        let transcriber = try await provider.start(context: SpeechTranscriptionStreamContext(
            transcriptURL: transcriptURL,
            localeIdentifier: "en-US",
            sampleRate: 48_000,
            channelCount: 1,
            performanceEventLogger: PerformanceEventLogger(url: performanceURL),
            transcriptUpdateSink: updateSink
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
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(client.requests.first?.apiKey, "key")
        XCTAssertEqual(client.requests.first?.model, "nova-3")
        XCTAssertEqual(client.requests.first?.sampleRate, 48_000)
        XCTAssertEqual(client.requests.first?.channelCount, 1)
        XCTAssertEqual(session.sentFrames, [frame])
        XCTAssertEqual(updateSink.finalUpdates.count, 1)
        guard case .upsert(let updatedSegment) = updateSink.finalUpdates.first else {
            return XCTFail("Expected upsert update")
        }
        XCTAssertEqual(updatedSegment.id, "dg-1")
        XCTAssertEqual(updatedSegment.text, "hello live")
        XCTAssertEqual(updatedSegment.sourceProvider, "deepgram-transcribe")
        XCTAssertFalse(FileManager.default.fileExists(atPath: transcriptURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: transcriptURL.deletingPathExtension().appendingPathExtension("json").path))
        let eventNames = try performanceEventNames(at: performanceURL)
        XCTAssertTrue(eventNames.contains("stt_segment_received"))
        XCTAssertTrue(eventNames.contains("transcript_segment_written"))
        let audioFrameSent = try XCTUnwrap(try performanceEvents(at: performanceURL)
            .first { $0.event == "deepgram_audio_frame_sent" })
        XCTAssertEqual(audioFrameSent.audioTimeSeconds, 2.0 / 48_000.0)
        XCTAssertEqual(audioFrameSent.metadata["pcmBytes"], "4")
        XCTAssertEqual(audioFrameSent.metadata["sampleRate"], "48000")
        XCTAssertEqual(audioFrameSent.metadata["channelCount"], "1")
        XCTAssertEqual(audioFrameSent.metadata["timestampNanos"], "10")
    }

    func testStreamingProviderAggregatesAudioFrameSentTelemetry() async throws {
        let transcriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("deepgram-stream-aggregate-\(UUID().uuidString)")
            .appendingPathExtension("txt")
        let performanceURL = transcriptURL.deletingLastPathComponent()
            .appendingPathComponent("performance-\(UUID().uuidString)")
            .appendingPathExtension("jsonl")
        defer {
            try? FileManager.default.removeItem(at: transcriptURL)
            try? FileManager.default.removeItem(at: transcriptURL.deletingPathExtension().appendingPathExtension("json"))
            try? FileManager.default.removeItem(at: performanceURL)
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
            sampleRate: 16_000,
            channelCount: 1,
            performanceEventLogger: PerformanceEventLogger(url: performanceURL)
        ))
        let frames = (0..<120).map { index in
            AudioFrame(
                pcm: Data(repeating: UInt8(index % 128), count: 320),
                sampleRate: 16_000,
                channelCount: 1,
                timestampNanos: UInt64(index) * 10_000_000
            )
        }

        for frame in frames {
            try transcriber.append(frame)
        }
        try await waitFor { session.sentFrames.count == frames.count }
        transcriber.finish()
        try await Task.sleep(nanoseconds: 30_000_000)

        let sentEvents = try performanceEvents(at: performanceURL)
            .filter { $0.event == "deepgram_audio_frame_sent" }
        XCTAssertLessThan(sentEvents.count, frames.count)
        XCTAssertEqual(sentEvents.first?.metadata["frameCount"], "1")
        XCTAssertEqual(sentEvents.first?.metadata["timestampNanos"], "0")
        XCTAssertEqual(sentEvents.compactMap { Int($0.metadata["frameCount"] ?? "") }.reduce(0, +), frames.count)
        XCTAssertEqual(sentEvents.last?.metadata["lastFrameTimestampNanos"], String(frames.last?.timestampNanos ?? 0))
        XCTAssertNotNil(sentEvents.last?.metadata["audioDurationSeconds"])
    }

    func testStreamingProviderForwardsSpeechRecognitionEvents() async throws {
        let transcriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("deepgram-stream-events-\(UUID().uuidString)")
            .appendingPathExtension("txt")
        defer {
            try? FileManager.default.removeItem(at: transcriptURL)
            try? FileManager.default.removeItem(at: transcriptURL.deletingPathExtension().appendingPathExtension("json"))
        }
        let session = FakeDeepgramStreamingSession()
        let client = FakeDeepgramStreamingClient(session: session)
        let eventSink = RecordingSpeechRecognitionEventSinkForTests()
        let provider = DeepgramStreamingSpeechTranscriptionProvider(
            configuration: DeepgramTranscriptionConfiguration(apiKey: "key", model: "nova-3"),
            client: client
        )

        let transcriber = try await provider.start(context: SpeechTranscriptionStreamContext(
            transcriptURL: transcriptURL,
            localeIdentifier: "zh-CN",
            sampleRate: 48_000,
            channelCount: 1,
            speechEventSink: eventSink
        ))

        session.yieldJSON("""
        {
          "is_final": false,
          "channel": {
            "alternatives": [
              {
                "transcript": "你好",
                "confidence": 0.8,
                "words": [
                  { "word": "你好", "punctuated_word": "你好", "start": 0.0, "end": 0.4, "speaker": 0 }
                ]
              }
            ]
          },
          "metadata": { "request_id": "request-1", "detected_language": "zh-CN" }
        }
        """)

        try await waitFor {
            eventSink.events.count == 1
        }
        transcriber.finish()

        guard case .hypothesis(let payload) = eventSink.events.first else {
            return XCTFail("Expected hypothesis event")
        }
        XCTAssertEqual(payload.text, "你好")
        XCTAssertEqual(payload.speaker?.identifier, "deepgram-speaker-0")
        XCTAssertFalse(FileManager.default.fileExists(atPath: transcriptURL.path))
    }

    func testStreamingProviderPublishesAssignedSpeakerLabelsToLiveUpdateSink() async throws {
        let transcriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("deepgram-stream-live-speaker-label-\(UUID().uuidString)")
            .appendingPathExtension("txt")
        defer {
            try? FileManager.default.removeItem(at: transcriptURL)
            try? FileManager.default.removeItem(at: transcriptURL.deletingPathExtension().appendingPathExtension("json"))
        }
        let session = FakeDeepgramStreamingSession()
        let client = FakeDeepgramStreamingClient(session: session)
        let updateSink = RecordingTranscriptUpdateSinkForTests()
        let provider = DeepgramStreamingSpeechTranscriptionProvider(
            configuration: DeepgramTranscriptionConfiguration(apiKey: "key", model: "nova-3"),
            client: client
        )
        let transcriber = try await provider.start(context: SpeechTranscriptionStreamContext(
            transcriptURL: transcriptURL,
            localeIdentifier: "en-US",
            sampleRate: 48_000,
            channelCount: 1,
            transcriptUpdateSink: updateSink
        ))

        session.yieldJSON("""
        {
          "is_final": false,
          "channel": {
            "alternatives": [
              {
                "transcript": "hello live",
                "confidence": 0.7,
                "words": [
                  { "word": "hello", "punctuated_word": "hello", "start": 0.0, "end": 0.4, "speaker": 0 },
                  { "word": "live", "punctuated_word": "live", "start": 0.4, "end": 0.8, "speaker": 0 }
                ]
              }
            ]
          }
        }
        """)
        try await waitFor { updateSink.realtimeUpdates.count == 1 }
        transcriber.finish()

        guard case .upsert(let updatedSegment) = updateSink.realtimeUpdates.first else {
            return XCTFail("Expected upsert update")
        }
        XCTAssertEqual(updatedSegment.speakerID, "deepgram-speaker-0")
        XCTAssertEqual(updatedSegment.speakerLabel, "User A")
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
            providerID: "deepgram-transcribe"
        )

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.id, "deepgram-transcribe-stream-active")
        XCTAssertEqual(segments.first?.text, "hello interim")
        XCTAssertEqual(segments.first?.isFinal, false)
    }

    func testStreamingProviderPublishesInterimRealtimeButPersistsOnlyFinal() async throws {
        let transcriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("deepgram-stream-interim-\(UUID().uuidString)")
            .appendingPathExtension("txt")
        defer {
            try? FileManager.default.removeItem(at: transcriptURL)
            try? FileManager.default.removeItem(at: transcriptURL.deletingPathExtension().appendingPathExtension("json"))
        }
        let session = FakeDeepgramStreamingSession()
        let client = FakeDeepgramStreamingClient(session: session)
        let updateSink = RecordingTranscriptUpdateSinkForTests()
        let provider = DeepgramStreamingSpeechTranscriptionProvider(
            configuration: DeepgramTranscriptionConfiguration(apiKey: "key", model: "nova-3"),
            client: client
        )
        let transcriber = try await provider.start(context: SpeechTranscriptionStreamContext(
            transcriptURL: transcriptURL,
            localeIdentifier: "en-US",
            sampleRate: 48_000,
            channelCount: 1,
            transcriptUpdateSink: updateSink
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
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertFalse(FileManager.default.fileExists(atPath: transcriptURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: transcriptURL.deletingPathExtension().appendingPathExtension("json").path))
        XCTAssertEqual(updateSink.realtimeTexts, ["hello"])
        XCTAssertEqual(updateSink.finalTexts, [])

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
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertFalse(FileManager.default.fileExists(atPath: transcriptURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: transcriptURL.deletingPathExtension().appendingPathExtension("json").path))
        XCTAssertEqual(updateSink.realtimeTexts, ["hello", "hello world"])
        XCTAssertEqual(updateSink.finalTexts, ["hello world"])
    }

    func testStreamingProviderPreservesFinalSegmentsBeforeSpeechFinal() async throws {
        let transcriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("deepgram-stream-buffer-\(UUID().uuidString)")
            .appendingPathExtension("txt")
        defer {
            try? FileManager.default.removeItem(at: transcriptURL)
            try? FileManager.default.removeItem(at: transcriptURL.deletingPathExtension().appendingPathExtension("json"))
        }
        let session = FakeDeepgramStreamingSession()
        let client = FakeDeepgramStreamingClient(session: session)
        let updateSink = RecordingTranscriptUpdateSinkForTests()
        let provider = DeepgramStreamingSpeechTranscriptionProvider(
            configuration: DeepgramTranscriptionConfiguration(apiKey: "key", model: "nova-3"),
            client: client
        )
        let transcriber = try await provider.start(context: SpeechTranscriptionStreamContext(
            transcriptURL: transcriptURL,
            localeIdentifier: "en-US",
            sampleRate: 48_000,
            channelCount: 1,
            transcriptUpdateSink: updateSink
        ))

        session.yieldJSON("""
        {
          "is_final": true,
          "speech_final": false,
          "channel": {
            "alternatives": [
              {
                "transcript": "my credit card number is two two",
                "confidence": 0.9,
                "words": [
                  { "word": "my", "punctuated_word": "my", "start": 0.0, "end": 0.2, "speaker": 0 },
                  { "word": "credit", "punctuated_word": "credit", "start": 0.2, "end": 0.5, "speaker": 0 },
                  { "word": "card", "punctuated_word": "card", "start": 0.5, "end": 0.8, "speaker": 0 },
                  { "word": "number", "punctuated_word": "number", "start": 0.8, "end": 1.1, "speaker": 0 },
                  { "word": "is", "punctuated_word": "is", "start": 1.1, "end": 1.2, "speaker": 0 },
                  { "word": "two", "punctuated_word": "two", "start": 1.2, "end": 1.5, "speaker": 0 },
                  { "word": "two", "punctuated_word": "two", "start": 1.5, "end": 1.8, "speaker": 0 }
                ]
              }
            ]
          }
        }
        """)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(updateSink.finalTexts, ["my credit card number is two two"])
        XCTAssertEqual(updateSink.finalSegments.map(\.speechFinal), [false])

        session.yieldJSON("""
        {
          "is_final": true,
          "speech_final": true,
          "channel": {
            "alternatives": [
              {
                "transcript": "two three three three",
                "confidence": 0.9,
                "words": [
                  { "word": "two", "punctuated_word": "two", "start": 1.8, "end": 2.1, "speaker": 0 },
                  { "word": "three", "punctuated_word": "three", "start": 2.1, "end": 2.4, "speaker": 0 },
                  { "word": "three", "punctuated_word": "three", "start": 2.4, "end": 2.7, "speaker": 0 },
                  { "word": "three", "punctuated_word": "three.", "start": 2.7, "end": 3.0, "speaker": 0 }
                ]
              }
            ]
          }
        }
        """)
        try await Task.sleep(nanoseconds: 30_000_000)
        transcriber.finish()
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(updateSink.finalSegments.map(\.text), [
            "my credit card number is two two",
            "two three three three."
        ])
        XCTAssertEqual(updateSink.finalSegments.map(\.id), [
            "deepgram-transcribe-stream-0.0",
            "deepgram-transcribe-stream-1.8"
        ])
        XCTAssertEqual(updateSink.finalSegments.map(\.speakerID), [
            "deepgram-speaker-0",
            "deepgram-speaker-0"
        ])
        XCTAssertEqual(updateSink.finalSegments.map(\.speechFinal), [false, true])
    }

    func testStreamingProviderFlushesBufferedFinalSegmentsWithoutWordTimingsOnFinish() async throws {
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
        try await Task.sleep(nanoseconds: 30_000_000)

        let document = try MeetingTranscriptStore.readDocument(
            from: transcriptURL.deletingPathExtension().appendingPathExtension("json")
        ).transcriptDocument
        XCTAssertEqual(document.segments.map(\.text), ["first final", "second final"])
        XCTAssertEqual(document.segments.map(\.id), [
            "deepgram-transcribe-stream-active-0",
            "deepgram-transcribe-stream-active-1"
        ])
        XCTAssertEqual(document.segments.map(\.isFinal), [true, true])
    }

    func testStreamingTranscriberSendsAudioFramesSerially() async throws {
        let transcriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("deepgram-stream-serial-send-\(UUID().uuidString)")
            .appendingPathExtension("txt")
        defer {
            try? FileManager.default.removeItem(at: transcriptURL)
            try? FileManager.default.removeItem(at: transcriptURL.deletingPathExtension().appendingPathExtension("json"))
        }
        let session = FakeDeepgramStreamingSession()
        session.suspendedFramePCM = Data([1])
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
        let first = AudioFrame(pcm: Data([1]), sampleRate: 48_000, channelCount: 1, timestampNanos: 1)
        let second = AudioFrame(pcm: Data([2]), sampleRate: 48_000, channelCount: 1, timestampNanos: 2)

        try transcriber.append(first)
        try transcriber.append(second)
        try await waitFor { session.isSuspendingFrame }

        XCTAssertEqual(session.sentFrames, [])

        session.resumeSuspendedSend()
        try await waitFor { session.sentFrames.count == 2 }
        transcriber.finish()

        XCTAssertEqual(session.sentFrames, [first, second])
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
        try await Task.sleep(nanoseconds: 30_000_000)

        let document = try MeetingTranscriptStore.readDocument(
            from: transcriptURL.deletingPathExtension().appendingPathExtension("json")
        ).transcriptDocument
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
        channelCount: Int,
        performanceEventLogger: PerformanceEventLogger?
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

private final class RecordingDeepgramRawResponseLogger: DeepgramRawResponseLogger {
    struct Entry {
        let data: Data
        let context: DeepgramRawResponseContext
    }

    private(set) var entries: [Entry] = []

    func logRawResponse(_ data: Data, context: DeepgramRawResponseContext) {
        entries.append(Entry(data: data, context: context))
    }
}

private func performanceEventNames(at url: URL) throws -> [String] {
    try performanceEvents(at: url).map(\.event)
}

private func performanceEvents(at url: URL) throws -> [PerformanceEvent] {
    try String(contentsOf: url, encoding: .utf8)
        .split(separator: "\n")
        .map { try JSONDecoder.meetingAgent.decode(PerformanceEvent.self, from: Data($0.utf8)) }
}

private final class FakeDeepgramStreamingSession: DeepgramStreamingTranscriptionSession {
    private var continuation: AsyncStream<TranscriptSegment>.Continuation?
    private var eventContinuation: AsyncStream<SpeechRecognitionEvent>.Continuation?
    private(set) var sentFrames: [AudioFrame] = []
    var suspendedFramePCM: Data?
    private var suspendedSendContinuation: CheckedContinuation<Void, Never>?
    let segments: AsyncStream<TranscriptSegment>
    let speechEvents: AsyncStream<SpeechRecognitionEvent>

    var isSuspendingFrame: Bool {
        suspendedSendContinuation != nil
    }

    init() {
        var streamContinuation: AsyncStream<TranscriptSegment>.Continuation!
        var eventStreamContinuation: AsyncStream<SpeechRecognitionEvent>.Continuation!
        self.segments = AsyncStream { continuation in
            streamContinuation = continuation
        }
        self.speechEvents = AsyncStream { continuation in
            eventStreamContinuation = continuation
        }
        self.continuation = streamContinuation
        self.eventContinuation = eventStreamContinuation
    }

    func send(_ frame: AudioFrame) async throws {
        if frame.pcm == suspendedFramePCM {
            await withCheckedContinuation { continuation in
                suspendedSendContinuation = continuation
            }
        }
        sentFrames.append(frame)
    }

    func resumeSuspendedSend() {
        suspendedSendContinuation?.resume()
        suspendedSendContinuation = nil
    }

    func close() async {
        continuation?.finish()
        eventContinuation?.finish()
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
        for event in DeepgramSpeechEventAdapter.events(
            from: Data(json.utf8),
            providerID: "deepgram-transcribe"
        ) {
            eventContinuation?.yield(event)
        }
    }
}

private final class RecordingSpeechRecognitionEventSinkForTests: SpeechRecognitionEventSink {
    private(set) var events: [SpeechRecognitionEvent] = []

    func receive(_ event: SpeechRecognitionEvent) {
        events.append(event)
    }
}

private final class RecordingTranscriptUpdateSinkForTests: TranscriptUpdateSink {
    private(set) var updates: [TranscriptSegmentUpdate] = []
    private(set) var realtimeUpdates: [TranscriptSegmentUpdate] = []
    private(set) var finalUpdates: [TranscriptSegmentUpdate] = []

    var realtimeTexts: [String] {
        realtimeUpdates.compactMap(Self.text)
    }

    var finalTexts: [String] {
        finalUpdates.compactMap(Self.text)
    }

    var finalSegments: [TranscriptSegment] {
        finalUpdates.compactMap(Self.segment)
    }

    func receive(_ update: TranscriptSegmentUpdate) {
        updates.append(update)
    }

    func receiveRealtime(_ update: TranscriptSegmentUpdate) {
        updates.append(update)
        realtimeUpdates.append(update)
    }

    func receiveFinal(_ update: TranscriptSegmentUpdate) {
        updates.append(update)
        finalUpdates.append(update)
    }

    private static func text(from update: TranscriptSegmentUpdate) -> String? {
        if case .upsert(let segment) = update {
            return segment.text
        }
        return nil
    }

    private static func segment(from update: TranscriptSegmentUpdate) -> TranscriptSegment? {
        if case .upsert(let segment) = update {
            return segment
        }
        return nil
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
