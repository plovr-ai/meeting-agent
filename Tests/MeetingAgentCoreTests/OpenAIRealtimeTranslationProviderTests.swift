import Foundation
import XCTest
@testable import MeetingAgentCore

final class OpenAIRealtimeTranslationProviderTests: XCTestCase {
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

    func testDecodesTranscriptDone() throws {
        let json = #"{"type":"response.output_audio_transcript.done","transcript":"你好。"}"#

        let event = try OpenAIRealtimeEventDecoder.decode(Data(json.utf8))

        XCTAssertEqual(event, .targetTextFinal("你好。"))
    }

    func testDecodesError() throws {
        let json = #"{"type":"error","error":{"message":"bad request"}}"#

        let event = try OpenAIRealtimeEventDecoder.decode(Data(json.utf8))

        XCTAssertEqual(event, .failed("bad request"))
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
}

private final class FakeRealtimeWebSocketTransport: RealtimeWebSocketTransport {
    var sentMessages: [Data] = []
    private var continuation: AsyncStream<Data>.Continuation?

    var incomingMessages: AsyncStream<Data> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func connect() async throws {}

    func send(_ data: Data) async throws {
        sentMessages.append(data)
    }

    func close() async {
        continuation?.finish()
    }

    func emit(_ data: Data) {
        continuation?.yield(data)
    }
}
