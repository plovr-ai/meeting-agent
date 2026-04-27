import XCTest
@testable import MeetingAgentCore

final class DeepgramTranscriptionProviderTests: XCTestCase {
    func testProviderSendsConfiguredRequestAndMapsUtterances() async throws {
        let client = RecordingDeepgramClient(response: """
        {
          "results": {
            "utterances": [
              {
                "id": "utt-1",
                "start": 0.4,
                "end": 1.8,
                "confidence": 0.91,
                "transcript": "hello team",
                "speaker": 2
              }
            ],
            "channels": [
              {
                "alternatives": [
                  { "transcript": "hello team" }
                ]
              }
            ]
          }
        }
        """)
        let provider = DeepgramAudioTranscriptionProvider(
            configuration: DeepgramTranscriptionConfiguration(apiKey: "key", model: "nova-3"),
            client: client
        )
        let wavURL = URL(fileURLWithPath: "/tmp/capture.wav")

        let output = try await provider.transcribe(
            audio: AudioInput(wavURL: wavURL, localeIdentifier: "en-US"),
            options: TranscriptionOptions(sourceLocale: "en-US")
        )

        XCTAssertEqual(client.requests.first?.apiKey, "key")
        XCTAssertEqual(client.requests.first?.model, "nova-3")
        XCTAssertEqual(client.requests.first?.language, "en-US")
        XCTAssertEqual(client.requests.first?.wavURL, wavURL)
        XCTAssertEqual(output.segments.first?.id, "utt-1")
        XCTAssertEqual(output.segments.first?.text, "hello team")
        XCTAssertEqual(output.segments.first?.speaker.label, "Speaker 2")
        XCTAssertEqual(output.segments.first?.sourceProvider, "deepgram-transcribe")
    }

    func testProviderFallsBackToChannelTranscriptWhenUtterancesAreAbsent() async throws {
        let client = RecordingDeepgramClient(response: """
        {
          "results": {
            "channels": [
              {
                "alternatives": [
                  {
                    "transcript": "whole transcript",
                    "confidence": 0.8
                  }
                ]
              }
            ]
          }
        }
        """)
        let provider = DeepgramAudioTranscriptionProvider(
            configuration: DeepgramTranscriptionConfiguration(apiKey: "key", model: "nova-3"),
            client: client
        )

        let output = try await provider.transcribe(
            audio: AudioInput(wavURL: URL(fileURLWithPath: "/tmp/capture.wav"), localeIdentifier: "en-US"),
            options: TranscriptionOptions(sourceLocale: "en-US")
        )

        XCTAssertEqual(output.segments.map(\.text), ["whole transcript"])
        XCTAssertEqual(output.segments.first?.confidence, 0.8)
    }
}

private final class RecordingDeepgramClient: DeepgramTranscriptionClient {
    struct Request: Equatable {
        let apiKey: String
        let model: String
        let language: String
        let wavURL: URL
    }

    private(set) var requests: [Request] = []
    private let response: String

    init(response: String) {
        self.response = response
    }

    func transcribe(
        configuration: DeepgramTranscriptionConfiguration,
        wavURL: URL,
        language: String
    ) async throws -> Data {
        requests.append(Request(
            apiKey: configuration.apiKey,
            model: configuration.model,
            language: language,
            wavURL: wavURL
        ))
        return Data(response.utf8)
    }
}
