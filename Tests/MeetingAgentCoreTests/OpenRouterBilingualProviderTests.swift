import XCTest
@testable import MeetingAgentCore

final class OpenRouterBilingualProviderTests: XCTestCase {
    func testTranslationProviderUsesConfiguredModelAndMapsSegments() async throws {
        let client = RecordingOpenRouterChatClient(responseContent: """
        {
          "segments": [
            { "id": "segment-1", "targetText": "你好" }
          ]
        }
        """)
        let provider = OpenRouterTextTranslationProvider(
            configuration: OpenRouterChatConfiguration(apiKey: "key", model: "openai/gpt-4.1-mini"),
            client: client
        )
        let transcript = TranscriptDocument(segments: [
            TranscriptSegment(
                id: "segment-1",
                startTimeSeconds: 1,
                endTimeSeconds: 2,
                text: "hello",
                language: "en-US",
                sourceProvider: "whisper-local"
            )
        ])

        let output = try await provider.translate(
            transcript: transcript,
            options: TranslationOptions(sourceLocale: "en-US", targetLocale: "zh-CN")
        )

        XCTAssertEqual(client.requests.first?.model, "openai/gpt-4.1-mini")
        XCTAssertEqual(output.segments.first?.id, "segment-1")
        XCTAssertEqual(output.segments.first?.sourceText, "hello")
        XCTAssertEqual(output.segments.first?.targetText, "你好")
        XCTAssertEqual(output.segments.first?.providerChain, ["openrouter-translation"])
    }

    func testTranscriptionProviderUsesConfiguredModelAndMapsSegments() async throws {
        let client = RecordingOpenRouterChatClient(responseContent: """
        {
          "segments": [
            { "id": "segment-1", "text": "hello", "language": "en-US", "startTimeSeconds": 0.0, "endTimeSeconds": 1.2 }
          ]
        }
        """)
        let provider = OpenRouterAudioTranscriptionProvider(
            configuration: OpenRouterChatConfiguration(apiKey: "key", model: "google/gemini-2.5-flash"),
            client: client
        )
        let wavURL = URL(fileURLWithPath: "/tmp/capture.wav")

        let output = try await provider.transcribe(
            audio: AudioInput(wavURL: wavURL, localeIdentifier: "en-US"),
            options: TranscriptionOptions(sourceLocale: "en-US")
        )

        XCTAssertEqual(client.requests.first?.model, "google/gemini-2.5-flash")
        XCTAssertEqual(output.segments.first?.id, "segment-1")
        XCTAssertEqual(output.segments.first?.text, "hello")
        XCTAssertEqual(output.segments.first?.sourceProvider, "openrouter-transcribe")
    }
}

private final class RecordingOpenRouterChatClient: OpenRouterChatClient {
    struct Request: Equatable {
        let model: String
        let messages: [OpenRouterChatMessage]
    }

    private(set) var requests: [Request] = []
    private let responseContent: String

    init(responseContent: String) {
        self.responseContent = responseContent
    }

    func complete(
        configuration: OpenRouterChatConfiguration,
        messages: [OpenRouterChatMessage],
        responseFormat: OpenRouterResponseFormat?
    ) async throws -> String {
        requests.append(Request(model: configuration.model, messages: messages))
        return responseContent
    }
}
