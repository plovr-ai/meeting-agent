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
        XCTAssertEqual(output.segments.first?.speakerID, "deepgram-speaker-2")
        XCTAssertNil(output.segments.first?.speakerLabel)
        XCTAssertEqual(output.segments.first?.sourceProvider, "deepgram-transcribe")
    }

    func testProviderWritesDeepgramSpeakersIntoUserLabelsThroughTranscriptWriter() async throws {
        let transcriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("deepgram-users-\(UUID().uuidString)")
            .appendingPathExtension("txt")
        defer {
            try? FileManager.default.removeItem(at: transcriptURL)
            try? FileManager.default.removeItem(at: transcriptURL.deletingPathExtension().appendingPathExtension("json"))
        }
        let client = RecordingDeepgramClient(response: """
        {
          "results": {
            "utterances": [
              { "id": "utt-1", "start": 0.0, "end": 1.0, "confidence": 0.91, "transcript": "hello", "speaker": 2 },
              { "id": "utt-2", "start": 1.1, "end": 2.0, "confidence": 0.89, "transcript": "hi", "speaker": 7 },
              { "id": "utt-3", "start": 2.1, "end": 3.0, "confidence": 0.90, "transcript": "again", "speaker": 2 }
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
        try TranscriptFileWriter(url: transcriptURL).replace(with: output.segments)

        let document = try TranscriptFileWriter.readDocument(
            from: transcriptURL.deletingPathExtension().appendingPathExtension("json")
        )
        XCTAssertEqual(document.segments.map(\.speakerID), [
            "deepgram-speaker-2",
            "deepgram-speaker-7",
            "deepgram-speaker-2"
        ])
        XCTAssertEqual(document.segments.map(\.speakerLabel), ["User A", "User B", "User A"])
        XCTAssertEqual(
            try String(contentsOf: transcriptURL, encoding: .utf8),
            """
            User A:
            hello

            User B:
            hi

            User A:
            again

            """
        )
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
