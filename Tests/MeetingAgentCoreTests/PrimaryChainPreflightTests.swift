import XCTest
@testable import MeetingAgentCore

final class PrimaryChainPreflightTests: XCTestCase {
    func testDeepgramPrimaryChainReportsMissingDeepgramAndOpenRouterCredentials() {
        let configuration = SpeechTranscriptionConfiguration.default

        let result = PrimaryChainPreflight.evaluate(
            configuration: configuration,
            credentials: [:],
            environment: [:]
        )

        XCTAssertEqual(result.status, .unavailable)
        XCTAssertEqual(result.messages, [
            "Deepgram API key is not configured",
            "OpenRouter API key is not configured"
        ])
    }

    func testOpenAIRealtimeTranscriptionWithOpenRouterTranslationIsAvailableWithCredentials() {
        let configuration = SpeechTranscriptionConfiguration(
            provider: .whisper,
            localeIdentifier: "en-US",
            targetLocaleIdentifier: "zh-CN",
            whisperBinaryPath: nil,
            whisperModelPath: nil,
            transcriptionExecutionMode: .hosted,
            translationExecutionMode: .hosted,
            hostedTranscriptionProviderID: SpeechTranscriptionConfiguration.defaultOpenAIRealtimeTranscriptionProviderID,
            hostedTranslationProviderID: SpeechTranscriptionConfiguration.defaultHostedTranslationProviderID,
            hostedTranscriptionModelID: SpeechTranscriptionConfiguration.defaultOpenAIRealtimeTranscriptionModelID
        )

        let result = PrimaryChainPreflight.evaluate(
            configuration: configuration,
            credentials: [
                .openAI: "openai-key",
                .openRouter: "openrouter-key"
            ],
            environment: [:]
        )

        XCTAssertEqual(result.status, .available)
        XCTAssertEqual(result.messages, [])
    }

    func testEnvironmentCredentialsSatisfyPreflight() {
        let result = PrimaryChainPreflight.evaluate(
            configuration: .default,
            credentials: [:],
            environment: [
                "MEETING_AGENT_DEEPGRAM_API_KEY": "deepgram-key",
                "MEETING_AGENT_OPENROUTER_API_KEY": "openrouter-key"
            ]
        )

        XCTAssertEqual(result.status, .available)
        XCTAssertEqual(result.messages, [])
    }
}
