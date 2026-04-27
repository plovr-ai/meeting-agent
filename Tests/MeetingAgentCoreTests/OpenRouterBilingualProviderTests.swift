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

    func testTranslationProviderMarksMissingAndBlankTranslationsAsSourceOnly() async throws {
        let client = RecordingOpenRouterChatClient(responseContent: """
        {
          "segments": [
            { "id": "segment-1", "targetText": "   " }
          ]
        }
        """)
        let provider = OpenRouterTextTranslationProvider(
            configuration: OpenRouterChatConfiguration(apiKey: "key", model: "openai/gpt-4.1-mini"),
            client: client
        )
        let transcript = TranscriptDocument(segments: [
            TranscriptSegment(id: "segment-1", text: "hello"),
            TranscriptSegment(id: "segment-2", text: "world")
        ])

        let output = try await provider.translate(
            transcript: transcript,
            options: TranslationOptions(sourceLocale: "en-US", targetLocale: "zh-CN")
        )

        XCTAssertEqual(output.segments.map(\.status), [.sourceOnly, .sourceOnly])
        XCTAssertEqual(output.segments.first?.errorMessage, "OpenRouter response did not include a translation for segment segment-1")
        XCTAssertTrue(client.requests.first?.messages.last?.content.contains("segment-2") == true)
    }

    func testTranslationProviderRejectsInvalidJSONContent() async {
        let provider = OpenRouterTextTranslationProvider(
            configuration: OpenRouterChatConfiguration(apiKey: "key", model: "openai/gpt-4.1-mini"),
            client: RecordingOpenRouterChatClient(responseContent: "no json here")
        )

        await XCTAssertThrowsErrorAsync(
            try await provider.translate(
                transcript: TranscriptDocument(segments: [TranscriptSegment(id: "segment-1", text: "hello")]),
                options: TranslationOptions(sourceLocale: "en-US", targetLocale: "zh-CN")
            )
        ) { error in
            XCTAssertEqual(String(describing: error), "response content did not contain a JSON object")
        }
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

    func testTranscriptionProviderRequiresWAVURLAndDefaultsGeneratedFields() async throws {
        let providerWithoutAudio = OpenRouterAudioTranscriptionProvider(
            configuration: OpenRouterChatConfiguration(apiKey: "key", model: "google/gemini-2.5-flash"),
            client: RecordingOpenRouterChatClient(responseContent: "{}")
        )
        await XCTAssertThrowsErrorAsync(
            try await providerWithoutAudio.transcribe(
                audio: AudioInput(wavURL: nil, localeIdentifier: "en-US"),
                options: TranscriptionOptions(sourceLocale: "en-US")
            )
        ) { error in
            XCTAssertEqual(String(describing: error), "OpenRouter transcription requires a WAV file URL")
        }

        let client = RecordingOpenRouterChatClient(responseContent: """
        preface
        {
          "segments": [
            { "id": " ", "text": "hello", "language": " ", "speakerID": "s1", "speakerLabel": "Speaker 1" }
          ]
        }
        trailing
        """)
        let provider = OpenRouterAudioTranscriptionProvider(
            configuration: OpenRouterChatConfiguration(apiKey: "key", model: "google/gemini-2.5-flash"),
            client: client
        )

        let output = try await provider.transcribe(
            audio: AudioInput(wavURL: URL(fileURLWithPath: "/tmp/capture.wav"), localeIdentifier: "en-US"),
            options: TranscriptionOptions(sourceLocale: "en-US")
        )

        XCTAssertEqual(output.segments.first?.language, "en-US")
        XCTAssertEqual(output.segments.first?.speakerID, "s1")
        XCTAssertEqual(output.segments.first?.speakerLabel, "Speaker 1")
        XCTAssertEqual(output.segments.first?.timingSource, .unavailable)
        XCTAssertFalse(output.segments.first?.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true)
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
