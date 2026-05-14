import XCTest
@testable import MeetingAgentCore

final class DeepgramSpeechEventAdapterTests: XCTestCase {
    func testDocumentedEndpointingSequenceMapsToEventsAndReducerSections() throws {
        let responses = [
            deepgramResult(start: 0.0, duration: 1.1, isFinal: false, speechFinal: false, text: "yeah so", words: [
                word("yeah", start: 0.0, end: 0.4),
                word("so", start: 0.4, end: 1.1)
            ]),
            deepgramResult(start: 0.0, duration: 2.2, isFinal: false, speechFinal: false, text: "yeah so my credit card number", words: [
                word("yeah", start: 0.0, end: 0.4),
                word("so", start: 0.4, end: 0.7),
                word("my", start: 0.7, end: 0.9),
                word("credit", start: 0.9, end: 1.3),
                word("card", start: 1.3, end: 1.6),
                word("number", start: 1.6, end: 2.2)
            ]),
            deepgramResult(start: 0.0, duration: 3.2, isFinal: false, speechFinal: false, text: "yeah so my credit card number is two two", words: [
                word("yeah", start: 0.0, end: 0.4),
                word("so", start: 0.4, end: 0.7),
                word("my", start: 0.7, end: 0.9),
                word("credit", start: 0.9, end: 1.3),
                word("card", start: 1.3, end: 1.6),
                word("number", start: 1.6, end: 2.0),
                word("is", start: 2.0, end: 2.2),
                word("two", start: 2.2, end: 2.7),
                word("two", start: 2.7, end: 3.2)
            ]),
            deepgramResult(start: 0.0, duration: 4.3, isFinal: false, speechFinal: false, text: "yeah so my credit card number is two two two two three", words: [
                word("yeah", start: 0.0, end: 0.4),
                word("so", start: 0.4, end: 0.7),
                word("my", start: 0.7, end: 0.9),
                word("credit", start: 0.9, end: 1.3),
                word("card", start: 1.3, end: 1.6),
                word("number", start: 1.6, end: 2.0),
                word("is", start: 2.0, end: 2.2),
                word("two", start: 2.2, end: 2.7),
                word("two", start: 2.7, end: 3.26),
                word("two", start: 3.26, end: 3.7),
                word("two", start: 3.7, end: 4.0),
                word("three", start: 4.0, end: 4.3)
            ]),
            deepgramResult(start: 0.0, duration: 3.26, isFinal: true, speechFinal: false, text: "yeah so my credit card number is two two", words: [
                word("yeah", start: 0.0, end: 0.4),
                word("so", start: 0.4, end: 0.7),
                word("my", start: 0.7, end: 0.9),
                word("credit", start: 0.9, end: 1.3),
                word("card", start: 1.3, end: 1.6),
                word("number", start: 1.6, end: 2.0),
                word("is", start: 2.0, end: 2.2),
                word("two", start: 2.2, end: 2.7),
                word("two", start: 2.7, end: 3.26)
            ]),
            deepgramResult(start: 3.26, duration: 1.84, isFinal: false, speechFinal: false, text: "two two three three three three", words: [
                word("two", start: 3.26, end: 3.7),
                word("two", start: 3.7, end: 4.0),
                word("three", start: 4.0, end: 4.3),
                word("three", start: 4.3, end: 4.6),
                word("three", start: 4.6, end: 4.85),
                word("three", start: 4.85, end: 5.1)
            ]),
            deepgramResult(start: 3.26, duration: 2.24, isFinal: true, speechFinal: true, text: "two two three three three three", words: [
                word("two", start: 3.26, end: 3.7),
                word("two", start: 3.7, end: 4.0),
                word("three", start: 4.0, end: 4.3),
                word("three", start: 4.3, end: 4.6),
                word("three", start: 4.6, end: 4.85),
                word("three", start: 4.85, end: 5.5)
            ])
        ]

        let events = responses.flatMap {
            DeepgramSpeechEventAdapter.events(from: Data($0.utf8), providerID: "deepgram-transcribe")
        }

        XCTAssertEqual(events.map(\.isFinal), [false, false, false, false, true, false, true])
        XCTAssertEqual(events.compactMap(\.payload?.boundary.speechFinal), [false, false, false, false, false, false, true])
        XCTAssertEqual(events.compactMap(\.payload?.providerUtteranceID), [
            "deepgram-transcribe-stream-0.0",
            "deepgram-transcribe-stream-0.0",
            "deepgram-transcribe-stream-0.0",
            "deepgram-transcribe-stream-0.0",
            "deepgram-transcribe-stream-0.0",
            "deepgram-transcribe-stream-3.26",
            "deepgram-transcribe-stream-3.26"
        ])

        let reducer = CaptionReducer(provider: CaptionProviderInfo(id: "deepgram-transcribe", model: "nova-3", locale: "en-US"))
        let document = events.reduce(into: reducer) { reducer, event in
            _ = reducer.apply(event)
        }.document

        XCTAssertEqual(document.turns.count, 1)
        XCTAssertEqual(document.turns[0].sections.map(\.text), [
            "yeah so my credit card number is two two",
            "two two three three three three"
        ])
        XCTAssertEqual(document.turns[0].state, .final)
    }

    func testInterimResultsWithDriftingWordStartIDsStillCollapseInReducer() throws {
        let responses = [
            deepgramResult(start: 0.0, duration: 8.0, isFinal: false, speechFinal: false, text: "英国", words: [
                word("英国", start: 7.6, end: 8.0)
            ]),
            deepgramResult(start: 0.0, duration: 8.1, isFinal: false, speechFinal: false, text: "英国、法国、德国", words: [
                word("英国、法国、德国", start: 7.7, end: 8.1)
            ]),
            deepgramResult(start: 0.0, duration: 9.2, isFinal: false, speechFinal: false, text: "英国、法国、德国这些在近代", words: [
                word("英国、法国、德国这些在近代", start: 7.7, end: 9.2)
            ])
        ]
        let events = responses.flatMap {
            DeepgramSpeechEventAdapter.events(from: Data($0.utf8), providerID: "deepgram-transcribe")
        }

        let reducer = CaptionReducer(provider: CaptionProviderInfo(id: "deepgram-transcribe", model: "nova-3", locale: "zh-Hans"))
        let document = events.reduce(into: reducer) { reducer, event in
            _ = reducer.apply(event)
        }.document

        XCTAssertEqual(events.compactMap(\.payload?.providerUtteranceID), [
            "deepgram-transcribe-stream-0.0",
            "deepgram-transcribe-stream-0.0",
            "deepgram-transcribe-stream-0.0"
        ])
        XCTAssertEqual(events.compactMap(\.payload?.startTimeSeconds), [0.0, 0.0, 0.0])
        XCTAssertEqual(events.compactMap(\.payload?.endTimeSeconds), [8.0, 8.1, 9.2])
        XCTAssertEqual(document.turns.count, 1)
        XCTAssertEqual(document.turns[0].sections.count, 1)
        XCTAssertEqual(document.turns[0].text, "英国、法国、德国这些在近代")
    }

    func testTranscriptOnlyResultsUseResponseWindowAsFallbackUtteranceID() throws {
        let events = DeepgramSpeechEventAdapter.events(
            from: Data(deepgramResult(
                start: 1.25,
                duration: 2.5,
                isFinal: false,
                speechFinal: false,
                text: "hello world",
                words: []
            ).utf8),
            providerID: "deepgram-transcribe"
        )

        XCTAssertEqual(events.count, 1)
        guard case .hypothesis(let payload) = events[0] else {
            return XCTFail("Expected hypothesis event")
        }
        XCTAssertEqual(payload.providerUtteranceID, "deepgram-transcribe-stream-1.25")
        XCTAssertEqual(payload.startTimeSeconds, 1.25)
        XCTAssertEqual(payload.endTimeSeconds, 3.75)
        XCTAssertEqual(payload.text, "hello world")
    }

    func testFinalizeResultMapsRemainingInterimAudioToFinalEvent() throws {
        let payload = """
        {
          "type": "Results",
          "start": 10.0,
          "duration": 1.4,
          "is_final": true,
          "speech_final": true,
          "from_finalize": true,
          "channel": {
            "alternatives": [
              {
                "transcript": "forced final",
                "confidence": 0.86,
                "words": [
                  { "word": "forced", "punctuated_word": "forced", "start": 10.0, "end": 10.5, "speaker": 0 },
                  { "word": "final", "punctuated_word": "final", "start": 10.5, "end": 11.4, "speaker": 0 }
                ]
              }
            ]
          },
          "metadata": { "request_id": "request-finalize", "detected_language": "en-US" }
        }
        """

        let events = DeepgramSpeechEventAdapter.events(
            from: Data(payload.utf8),
            providerID: "deepgram-transcribe"
        )

        XCTAssertEqual(events.count, 1)
        guard case .final(let eventPayload) = events[0] else {
            return XCTFail("Expected final event")
        }
        XCTAssertEqual(eventPayload.providerResultID, "request-finalize")
        XCTAssertEqual(eventPayload.providerUtteranceID, "deepgram-transcribe-stream-10.0")
        XCTAssertEqual(eventPayload.text, "forced final")
        XCTAssertTrue(eventPayload.boundary.speechFinal)
    }

    func testDeepgramNonResultMessagesDoNotCreateTranscriptEvents() {
        let payloads = [
            #"{"type":"Metadata","request_id":"request-1","duration":45.5,"channels":2}"#,
            #"{"type":"UtteranceEnd","channel":[0],"last_word_end":2.395}"#,
            #"{"type":"SpeechStarted","channel":[0],"timestamp":0.5}"#
        ]

        for payload in payloads {
            XCTAssertTrue(DeepgramSpeechEventAdapter.events(
                from: Data(payload.utf8),
                providerID: "deepgram-transcribe"
            ).isEmpty)
        }
    }

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
        XCTAssertEqual(events.compactMap(\.payload?.providerUtteranceID), [
            "deepgram-transcribe-stream-0.0-run-0",
            "deepgram-transcribe-stream-0.0-run-1"
        ])
        XCTAssertEqual(events.map(\.isFinal), [true, true])
        XCTAssertEqual(events.compactMap(\.payload?.boundary.speechFinal), [false, true])
        XCTAssertEqual(events.compactMap(\.payload?.boundary.punctuationFinal), [true, true])
    }

    func testBlankOrNonResultPayloadProducesNoEvents() {
        XCTAssertTrue(DeepgramSpeechEventAdapter.events(from: Data(#"{"type":"Metadata"}"#.utf8), providerID: "deepgram").isEmpty)
        XCTAssertTrue(DeepgramSpeechEventAdapter.events(from: Data(#"{"is_final":false}"#.utf8), providerID: "deepgram").isEmpty)
    }

    private func deepgramResult(
        start: Double,
        duration: Double,
        isFinal: Bool,
        speechFinal: Bool,
        text: String,
        words: [String]
    ) -> String {
        """
        {
          "type": "Results",
          "start": \(start),
          "duration": \(duration),
          "is_final": \(isFinal),
          "speech_final": \(speechFinal),
          "channel": {
            "alternatives": [
              {
                "transcript": "\(text)",
                "confidence": 0.9,
                "words": [\(words.joined(separator: ","))]
              }
            ]
          },
          "metadata": { "request_id": "request-1", "detected_language": "zh-Hans" }
        }
        """
    }

    private func word(_ text: String, start: Double, end: Double, speaker: Int = 0) -> String {
        #"{"word":"\#(text)","punctuated_word":"\#(text)","start":\#(start),"end":\#(end),"speaker":\#(speaker)}"#
    }
}
