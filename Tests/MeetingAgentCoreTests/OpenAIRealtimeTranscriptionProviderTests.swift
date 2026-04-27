import Foundation
import XCTest
@testable import MeetingAgentCore

final class OpenAIRealtimeTranscriptionProviderTests: XCTestCase {
    func testDecoderMapsDeltaCompletedAndFailureEvents() throws {
        let delta = try OpenAIRealtimeTranscriptionEventDecoder.decode(Data("""
        {"type":"conversation.item.input_audio_transcription.delta","item_id":"item-1","delta":"Hello"}
        """.utf8))
        let completed = try OpenAIRealtimeTranscriptionEventDecoder.decode(Data("""
        {"type":"conversation.item.input_audio_transcription.completed","item_id":"item-1","transcript":"Hello world"}
        """.utf8))
        let error = try OpenAIRealtimeTranscriptionEventDecoder.decode(Data("""
        {"type":"error","error":{"message":"bad key"}}
        """.utf8))

        XCTAssertEqual(delta, .delta(itemID: "item-1", text: "Hello"))
        XCTAssertEqual(completed, .completed(itemID: "item-1", transcript: "Hello world"))
        XCTAssertEqual(error, .failed("bad key"))
    }

    func testDecoderIgnoresUnrelatedEvents() throws {
        let event = try OpenAIRealtimeTranscriptionEventDecoder.decode(Data("""
        {"type":"session.updated"}
        """.utf8))

        XCTAssertNil(event)
    }
}
