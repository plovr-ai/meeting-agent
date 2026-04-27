import XCTest
@testable import MeetingAgentCore

final class SpeechTranscriptionProviderTests: XCTestCase {
    func testSpeechProviderSupportedValuesAndDefaultFailureReason() {
        let transcriber = MinimalAudioFrameTranscriber()

        XCTAssertEqual(SpeechProvider.supportedValuesDescription, "local, whisper")
        XCTAssertNil(transcriber.failureReason)
    }

    func testDefaultProviderStartUsesStreamContext() async throws {
        let provider = MinimalSpeechTranscriptionProvider()
        let context = SpeechTranscriptionStreamContext(
            transcriptURL: URL(fileURLWithPath: "/tmp/transcript.txt"),
            localeIdentifier: "en-US",
            sampleRate: 16_000,
            channelCount: 1
        )

        _ = try await provider.start(context: context)

        XCTAssertEqual(provider.startedTranscriptURL, context.transcriptURL)
        XCTAssertEqual(provider.startedLocaleIdentifier, "en-US")
    }

    func testDefaultProviderRejectsRetryingExistingAudio() async {
        let provider = MinimalSpeechTranscriptionProvider(provider: .whisper)

        await XCTAssertThrowsErrorAsync(
            try await provider.transcribeExistingAudio(context: SpeechTranscriptionContext(
                inputAudioURL: URL(fileURLWithPath: "/tmp/audio.wav"),
                transcriptURL: URL(fileURLWithPath: "/tmp/transcript.txt"),
                localeIdentifier: "en-US",
                meetingID: UUID(),
                previousTranscript: nil
            ))
        ) { error in
            XCTAssertEqual(
                String(describing: error),
                "Speech recognition error: whisper does not support retrying from an existing audio file"
            )
        }
    }

    func testStreamingFactoryRejectsHostedNonDeepgramStreaming() async {
        await XCTAssertThrowsErrorAsync(
            try await StreamingSpeechTranscriberFactory.startTranscriber(
                configuration: SpeechTranscriptionConfiguration(
                    provider: .whisper,
                    localeIdentifier: "en-US",
                    whisperBinaryPath: nil,
                    whisperModelPath: nil,
                    transcriptionExecutionMode: .hosted,
                    hostedTranscriptionProviderID: "openrouter-transcribe"
                ),
                transcriptURL: URL(fileURLWithPath: "/tmp/transcript.txt"),
                sampleRate: 16_000,
                channelCount: 1
            )
        ) { error in
            XCTAssertEqual(
                String(describing: error),
                "Speech recognition error: Hosted transcription provider openrouter-transcribe does not support streaming audio"
            )
        }
    }

    func testStreamingFactoryRoutesOpenAIRealtimeTranscriptionProvider() async {
        var configuration = SpeechTranscriptionConfiguration.default
        configuration.transcriptionExecutionMode = .hosted
        configuration.hostedTranscriptionProviderID = SpeechTranscriptionConfiguration.defaultOpenAIRealtimeTranscriptionProviderID
        configuration.openAIRealtimeAPIKey = nil

        await XCTAssertThrowsErrorAsync(
            try await StreamingSpeechTranscriberFactory.startTranscriber(
                configuration: configuration,
                transcriptURL: URL(fileURLWithPath: "/tmp/transcript.txt"),
                sampleRate: 24_000,
                channelCount: 1
            )
        ) { error in
            XCTAssertEqual(String(describing: error), OpenAIRealtimeTranscriptionProviderError.missingAPIKey.description)
        }
    }

    func testFactoryReturnsLocalAndWhisperProviders() {
        XCTAssertTrue(SpeechTranscriptionProviderFactory.provider(for: .local) is LocalSpeechTranscriptionProvider)
        XCTAssertTrue(SpeechTranscriptionProviderFactory.provider(for: .whisper) is WhisperSpeechTranscriptionProvider)
        XCTAssertEqual(LocalSpeechTranscriptionProvider().provider, .local)
    }
}

private final class MinimalAudioFrameTranscriber: AudioFrameTranscriber {
    func append(_ frame: AudioFrame) throws {}
    func finish() {}
}

private final class MinimalSpeechTranscriptionProvider: SpeechTranscriptionProvider {
    let provider: SpeechProvider
    var startedTranscriptURL: URL?
    var startedLocaleIdentifier: String?

    init(provider: SpeechProvider = .local) {
        self.provider = provider
    }

    func start(transcriptURL: URL, localeIdentifier: String) async throws -> AudioFrameTranscriber {
        startedTranscriptURL = transcriptURL
        startedLocaleIdentifier = localeIdentifier
        return MinimalAudioFrameTranscriber()
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
