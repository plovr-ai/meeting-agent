import XCTest
@testable import MeetingAgentCore

final class DeepgramSpeechEventAdapterTests: XCTestCase {
    func testMapsInterimDeepgramResponseToHypothesisEventWithSpeaker() throws {
        let events = DeepgramSpeechEventAdapter.events(
            from: Data("""
            {
              "type": "Results",
              "start": 1.25,
              "is_final": false,
              "speech_final": false,
              "channel": {
                "alternatives": [
                  {
                    "transcript": "你好",
                    "confidence": 0.82,
                    "words": [
                      { "word": "你好", "punctuated_word": "你好", "start": 1.25, "end": 1.7, "speaker": 0 }
                    ]
                  }
                ]
              },
              "metadata": { "request_id": "request-1", "detected_language": "zh-CN" }
            }
            """.utf8),
            providerID: "deepgram-transcribe"
        )

        XCTAssertEqual(events.count, 1)
        guard case .hypothesis(let payload) = events[0] else {
            return XCTFail("Expected hypothesis event")
        }
        XCTAssertEqual(payload.providerID, "deepgram-transcribe")
        XCTAssertEqual(payload.providerResultID, "request-1")
        XCTAssertEqual(payload.providerUtteranceID, "deepgram-transcribe-stream-1.25")
        XCTAssertEqual(payload.speaker?.identifier, "deepgram-speaker-0")
        XCTAssertEqual(payload.text, "你好")
        XCTAssertEqual(payload.language, "zh-CN")
        XCTAssertEqual(payload.confidence, 0.82)
        XCTAssertFalse(payload.boundary.speechFinal)
    }

    func testMapsFinalSpeechFinalOnlyOnLastSpeakerRun() throws {
        let events = DeepgramSpeechEventAdapter.events(
            from: Data("""
            {
              "type": "Results",
              "start": 0,
              "is_final": true,
              "speech_final": true,
              "channel": {
                "alternatives": [
                  {
                    "transcript": "Hello. Yes.",
                    "confidence": 0.9,
                    "words": [
                      { "word": "hello", "punctuated_word": "Hello.", "start": 0.0, "end": 0.4, "speaker": 0 },
                      { "word": "yes", "punctuated_word": "Yes.", "start": 0.5, "end": 0.8, "speaker": 1 }
                    ]
                  }
                ]
              },
              "metadata": { "request_id": "request-2" }
            }
            """.utf8),
            providerID: "deepgram-transcribe"
        )

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.compactMap(\.payload?.speaker?.identifier), ["deepgram-speaker-0", "deepgram-speaker-1"])
        XCTAssertEqual(events.map(\.isFinal), [true, true])
        XCTAssertEqual(events.compactMap(\.payload?.boundary.speechFinal), [false, true])
        XCTAssertEqual(events.compactMap(\.payload?.boundary.punctuationFinal), [true, true])
    }

    func testBlankOrNonResultPayloadProducesNoEvents() {
        XCTAssertTrue(DeepgramSpeechEventAdapter.events(from: Data(#"{"type":"Metadata"}"#.utf8), providerID: "deepgram").isEmpty)
        XCTAssertTrue(DeepgramSpeechEventAdapter.events(from: Data(#"{"is_final":false}"#.utf8), providerID: "deepgram").isEmpty)
    }
}
