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
}
