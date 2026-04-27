import Foundation
import XCTest
@testable import MeetingAgentCore

final class OpenAIRealtimeTranslationProviderTests: XCTestCase {
    func testDecodesConnectedEventsAndRateLimits() throws {
        let created = try OpenAIRealtimeEventDecoder.decode(Data(#"{"type":"session.created"}"#.utf8))
        let updated = try OpenAIRealtimeEventDecoder.decode(Data(#"{"type":"session.updated"}"#.utf8))
        let rateLimits = try OpenAIRealtimeEventDecoder.decode(Data(#"{"type":"rate_limits.updated"}"#.utf8))

        XCTAssertEqual(created, .connected)
        XCTAssertEqual(updated, .connected)
        XCTAssertEqual(rateLimits, .rateLimitsUpdated)
    }

    func testIgnoresKnownTerminalAndUnknownEvents() throws {
        XCTAssertNil(try OpenAIRealtimeEventDecoder.decode(Data(#"{"type":"response.done"}"#.utf8)))
        XCTAssertNil(try OpenAIRealtimeEventDecoder.decode(Data(#"{"type":"response.output_audio.done"}"#.utf8)))
        XCTAssertNil(try OpenAIRealtimeEventDecoder.decode(Data(#"{"type":"unknown.event"}"#.utf8)))
    }

    func testDecodesOutputAudioDelta() throws {
        let json = #"{"type":"response.output_audio.delta","delta":"AQID"}"#

        let event = try OpenAIRealtimeEventDecoder.decode(Data(json.utf8))

        XCTAssertEqual(event, .targetAudioDelta(Data([1, 2, 3])))
    }

    func testDecodesTranscriptDelta() throws {
        let json = #"{"type":"response.output_audio_transcript.delta","delta":"你好"}"#

        let event = try OpenAIRealtimeEventDecoder.decode(Data(json.utf8))

        XCTAssertEqual(event, .targetTextDelta("你好"))
    }

    func testDecodesTranscriptDeltaWithMissingTextAsEmptyDelta() throws {
        let json = #"{"type":"response.output_audio_transcript.delta"}"#

        let event = try OpenAIRealtimeEventDecoder.decode(Data(json.utf8))

        XCTAssertEqual(event, .targetTextDelta(""))
    }

    func testDecodesTranscriptDone() throws {
        let json = #"{"type":"response.output_audio_transcript.done","transcript":"你好。"}"#

        let event = try OpenAIRealtimeEventDecoder.decode(Data(json.utf8))

        XCTAssertEqual(event, .targetTextFinal("你好。"))
    }

    func testDecodesTranscriptDoneWithMissingTextAsEmptyFinal() throws {
        let json = #"{"type":"response.output_audio_transcript.done"}"#

        let event = try OpenAIRealtimeEventDecoder.decode(Data(json.utf8))

        XCTAssertEqual(event, .targetTextFinal(""))
    }

    func testDecodesError() throws {
        let json = #"{"type":"error","error":{"message":"bad request"}}"#

        let event = try OpenAIRealtimeEventDecoder.decode(Data(json.utf8))

        XCTAssertEqual(event, .failed("bad request"))
    }

    func testDecodesErrorWithoutMessage() throws {
        let json = #"{"type":"error"}"#

        let event = try OpenAIRealtimeEventDecoder.decode(Data(json.utf8))

        XCTAssertEqual(event, .failed("OpenAI Realtime error"))
    }

    func testRejectsInvalidBase64AudioDelta() {
        let json = #"{"type":"response.output_audio.delta","delta":"not base64"}"#

        XCTAssertThrowsError(try OpenAIRealtimeEventDecoder.decode(Data(json.utf8))) { error in
            XCTAssertEqual(String(describing: error), "OpenAI Realtime audio delta was not valid base64")
        }
    }

    func testRejectsInvalidEventJSON() {
        XCTAssertThrowsError(try OpenAIRealtimeEventDecoder.decode(Data("{".utf8)))
    }

    func testProviderErrorDescriptionsCoverAllCases() {
        XCTAssertEqual(String(describing: OpenAIRealtimeProviderError.missingAPIKey), "MEETING_AGENT_OPENAI_API_KEY is not configured")
        XCTAssertEqual(String(describing: OpenAIRealtimeProviderError.invalidEvent), "OpenAI Realtime event could not be decoded")
        XCTAssertEqual(String(describing: OpenAIRealtimeProviderError.invalidBase64Audio), "OpenAI Realtime audio delta was not valid base64")
        XCTAssertEqual(String(describing: OpenAIRealtimeProviderError.transportClosed), "OpenAI Realtime WebSocket transport is closed")
    }

    func testBuildsSessionUpdateMessage() throws {
        let config = RealtimeTranslationConfiguration(
            apiKey: "key",
            model: "gpt-realtime",
            targetLocale: "ja-JP",
            voice: "marin"
        )

        let data = try OpenAIRealtimeMessageFactory.sessionUpdate(configuration: config)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let session = object?["session"] as? [String: Any]

        XCTAssertEqual(object?["type"] as? String, "session.update")
        XCTAssertEqual(session?["type"] as? String, "realtime")
        XCTAssertEqual(session?["model"] as? String, "gpt-realtime")
        XCTAssertTrue((session?["instructions"] as? String)?.contains("ja-JP") == true)
        let audio = session?["audio"] as? [String: Any]
        let input = audio?["input"] as? [String: Any]
        let output = audio?["output"] as? [String: Any]
        let turnDetection = input?["turn_detection"] as? [String: Any]
        let format = output?["format"] as? [String: Any]
        XCTAssertEqual(turnDetection?["type"] as? String, "server_vad")
        XCTAssertEqual(output?["voice"] as? String, "marin")
        XCTAssertEqual(format?["type"] as? String, "audio/pcm")
        XCTAssertEqual(format?["rate"] as? Int, 24_000)
    }

    func testBuildsAppendAudioMessage() throws {
        let data = try OpenAIRealtimeMessageFactory.appendAudio(Data([1, 2, 3]))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(object?["type"] as? String, "input_audio_buffer.append")
        XCTAssertEqual(object?["audio"] as? String, "AQID")
    }

    func testProviderSendsSessionUpdateOnStart() async throws {
        let transport = FakeRealtimeWebSocketTransport()
        let provider = OpenAIRealtimeSpeechTranslationProvider(
            transportFactory: { _, _ in transport }
        )
        let config = RealtimeTranslationConfiguration(
            apiKey: "key",
            model: "gpt-realtime",
            targetLocale: "zh-CN",
            voice: "marin"
        )

        _ = try await provider.start(configuration: config)

        XCTAssertEqual(transport.sentMessages.count, 1)
        let object = try JSONSerialization.jsonObject(with: transport.sentMessages[0]) as? [String: Any]
        XCTAssertEqual(object?["type"] as? String, "session.update")
    }

    func testProviderPassesURLAndAPIKeyToTransportFactory() async throws {
        var capturedURL: URL?
        var capturedAPIKey: String?
        let provider = OpenAIRealtimeSpeechTranslationProvider(
            transportFactory: { url, apiKey in
                capturedURL = url
                capturedAPIKey = apiKey
                return FakeRealtimeWebSocketTransport()
            }
        )

        _ = try await provider.start(configuration: RealtimeTranslationConfiguration(
            apiKey: "key",
            model: "gpt-realtime",
            targetLocale: "fr-FR"
        ))

        XCTAssertEqual(capturedAPIKey, "key")
        XCTAssertEqual(capturedURL?.absoluteString, "wss://api.openai.com/v1/realtime?model=gpt-realtime")
    }

    func testSessionAppendSendsBase64PCM16() async throws {
        let transport = FakeRealtimeWebSocketTransport()
        let provider = OpenAIRealtimeSpeechTranslationProvider(
            transportFactory: { _, _ in transport }
        )
        let session = try await provider.start(configuration: RealtimeTranslationConfiguration(apiKey: "key"))
        let samples: [Int16] = [1, -2]
        let pcm = Data(samples.flatMap { sample -> [UInt8] in
            let value = sample.littleEndian
            return withUnsafeBytes(of: value) { Array($0) }
        })
        let frame = AudioFrame(pcm: pcm, sampleRate: 24_000, channelCount: 1, timestampNanos: 0)

        try await session.append([frame])

        XCTAssertEqual(transport.sentMessages.count, 2)
        let object = try JSONSerialization.jsonObject(with: transport.sentMessages[1]) as? [String: Any]
        XCTAssertEqual(object?["type"] as? String, "input_audio_buffer.append")
        XCTAssertEqual(object?["audio"] as? String, pcm.base64EncodedString())
    }

    func testSessionAppendIgnoresEmptyFrames() async throws {
        let transport = FakeRealtimeWebSocketTransport()
        let provider = OpenAIRealtimeSpeechTranslationProvider(
            transportFactory: { _, _ in transport }
        )
        let session = try await provider.start(configuration: RealtimeTranslationConfiguration(apiKey: "key"))

        try await session.append([])

        XCTAssertEqual(transport.sentMessages.count, 1)
    }

    func testSessionEmitsDecodedTransportEvents() async throws {
        let transport = FakeRealtimeWebSocketTransport()
        let provider = OpenAIRealtimeSpeechTranslationProvider(
            transportFactory: { _, _ in transport }
        )
        let session = try await provider.start(configuration: RealtimeTranslationConfiguration(apiKey: "key"))
        var iterator = session.events.makeAsyncIterator()

        try await Task.sleep(nanoseconds: 20_000_000)
        transport.emit(Data(#"{"type":"response.output_audio_transcript.delta","delta":"你好"}"#.utf8))

        let event = await iterator.next()
        XCTAssertEqual(event, .targetTextDelta("你好"))
    }

    func testSessionEmitsFailureForInvalidTransportEventAndStopsWhenStreamCloses() async throws {
        let transport = FakeRealtimeWebSocketTransport()
        let provider = OpenAIRealtimeSpeechTranslationProvider(
            transportFactory: { _, _ in transport }
        )
        let session = try await provider.start(configuration: RealtimeTranslationConfiguration(apiKey: "key"))
        var iterator = session.events.makeAsyncIterator()

        try await Task.sleep(nanoseconds: 20_000_000)
        transport.emit(Data(#"{"type":"response.output_audio.delta","delta":"bad"}"#.utf8))
        transport.finish()

        let failed = await iterator.next()
        let stopped = await iterator.next()
        XCTAssertEqual(failed, .failed("OpenAI Realtime audio delta was not valid base64"))
        XCTAssertEqual(stopped, .stopped)
    }

    func testSessionStopClosesTransportAndEmitsStopped() async throws {
        let transport = FakeRealtimeWebSocketTransport()
        let provider = OpenAIRealtimeSpeechTranslationProvider(
            transportFactory: { _, _ in transport }
        )
        let session = try await provider.start(configuration: RealtimeTranslationConfiguration(apiKey: "key"))
        var iterator = session.events.makeAsyncIterator()

        await session.stop()

        let stopped = await iterator.next()
        XCTAssertTrue(transport.didClose)
        XCTAssertEqual(stopped, .stopped)
    }

    func testProviderRejectsMissingAPIKey() async {
        let provider = OpenAIRealtimeSpeechTranslationProvider(
            transportFactory: { _, _ in FakeRealtimeWebSocketTransport() }
        )

        do {
            _ = try await provider.start(configuration: RealtimeTranslationConfiguration(apiKey: " "))
            XCTFail("Expected missing API key error")
        } catch {
            XCTAssertTrue(String(describing: error).contains("MEETING_AGENT_OPENAI_API_KEY is not configured"))
        }
    }

    func testProviderPropagatesTransportConnectFailure() async {
        let transport = FakeRealtimeWebSocketTransport()
        transport.connectError = ProbeError.coreAudio("network unavailable")
        let provider = OpenAIRealtimeSpeechTranslationProvider(
            transportFactory: { _, _ in transport }
        )

        await XCTAssertThrowsErrorAsync(
            try await provider.start(configuration: RealtimeTranslationConfiguration(apiKey: "key"))
        ) { error in
            XCTAssertEqual(String(describing: error), "Core Audio error: network unavailable")
        }
        XCTAssertTrue(transport.sentMessages.isEmpty)
    }

    func testProviderPropagatesSessionUpdateSendFailure() async {
        let transport = FakeRealtimeWebSocketTransport()
        transport.sendError = OpenAIRealtimeProviderError.transportClosed
        let provider = OpenAIRealtimeSpeechTranslationProvider(
            transportFactory: { _, _ in transport }
        )

        await XCTAssertThrowsErrorAsync(
            try await provider.start(configuration: RealtimeTranslationConfiguration(apiKey: "key"))
        ) { error in
            XCTAssertEqual(String(describing: error), "OpenAI Realtime WebSocket transport is closed")
        }
        XCTAssertEqual(transport.connectCallCount, 1)
    }

    func testURLSessionTransportSendFailsBeforeConnect() async {
        let transport = URLSessionRealtimeWebSocketTransport(
            url: URL(string: "wss://example.test/realtime")!,
            apiKey: "key"
        )

        do {
            try await transport.send(Data(#"{"type":"ping"}"#.utf8))
            XCTFail("Expected closed transport error")
        } catch {
            XCTAssertEqual(String(describing: error), "OpenAI Realtime WebSocket transport is closed")
        }
    }

    func testURLSessionTransportConnectAndCloseManageUnderlyingTaskLifecycle() async throws {
        let task = FakeURLSessionRealtimeWebSocketTask()
        var capturedRequest: URLRequest?
        let transport = URLSessionRealtimeWebSocketTransport(
            url: URL(string: "wss://example.test/realtime")!,
            apiKey: "key",
            webSocketFactory: { request, _ in
                capturedRequest = request
                return task
            }
        )

        try await transport.connect()
        await transport.close()

        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer key")
        XCTAssertEqual(task.resumeCallCount, 1)
        XCTAssertEqual(task.cancelCloseCodes, [.goingAway])
        await XCTAssertThrowsErrorAsync(
            try await transport.send(Data(#"{"type":"ping"}"#.utf8))
        ) { error in
            XCTAssertEqual(String(describing: error), "OpenAI Realtime WebSocket transport is closed")
        }
    }

    func testURLSessionTransportSendsTextAndYieldsIncomingDataAndStrings() async throws {
        let task = FakeURLSessionRealtimeWebSocketTask()
        let transport = URLSessionRealtimeWebSocketTransport(
            url: URL(string: "wss://example.test/realtime")!,
            apiKey: "key",
            webSocketFactory: { _, _ in task }
        )
        let stream = transport.incomingMessages
        var iterator = stream.makeAsyncIterator()

        try await transport.connect()
        try await transport.send(Data(#"{"type":"ping"}"#.utf8))
        task.completeReceive(with: .success(.data(Data([1, 2, 3]))))
        task.completeReceive(with: .success(.string("hello")))
        task.completeReceive(with: .failure(OpenAIRealtimeProviderError.transportClosed))

        guard case .string(#"{"type":"ping"}"#) = task.sentMessages.first else {
            XCTFail("Expected text WebSocket message")
            return
        }
        let dataMessage = await iterator.next()
        let stringMessage = await iterator.next()
        let end = await iterator.next()
        XCTAssertEqual(dataMessage, Data([1, 2, 3]))
        XCTAssertEqual(stringMessage, Data("hello".utf8))
        XCTAssertNil(end)
    }
}

private final class FakeRealtimeWebSocketTransport: RealtimeWebSocketTransport {
    var sentMessages: [Data] = []
    var connectError: Error?
    var sendError: Error?
    var connectCallCount = 0
    private(set) var didClose = false
    private var continuation: AsyncStream<Data>.Continuation?

    var incomingMessages: AsyncStream<Data> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func connect() async throws {
        connectCallCount += 1
        if let connectError {
            throw connectError
        }
    }

    func send(_ data: Data) async throws {
        if let sendError {
            throw sendError
        }
        sentMessages.append(data)
    }

    func close() async {
        didClose = true
        continuation?.finish()
    }

    func emit(_ data: Data) {
        continuation?.yield(data)
    }

    func finish() {
        continuation?.finish()
    }
}

private final class FakeURLSessionRealtimeWebSocketTask: URLSessionRealtimeWebSocketTask {
    private(set) var resumeCallCount = 0
    private(set) var sentMessages: [URLSessionWebSocketTask.Message] = []
    private(set) var cancelCloseCodes: [URLSessionWebSocketTask.CloseCode] = []
    private var receiveHandlers: [@Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void] = []

    func resume() {
        resumeCallCount += 1
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        sentMessages.append(message)
    }

    func receive(completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
        receiveHandlers.append(completionHandler)
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        cancelCloseCodes.append(closeCode)
    }

    func completeReceive(with result: Result<URLSessionWebSocketTask.Message, Error>) {
        guard !receiveHandlers.isEmpty else { return }
        receiveHandlers.removeFirst()(result)
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
