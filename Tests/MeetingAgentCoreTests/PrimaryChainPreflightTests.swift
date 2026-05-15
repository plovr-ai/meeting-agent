import XCTest
@testable import MeetingAgentCore

final class PrimaryChainPreflightTests: XCTestCase {
    func testDeepgramPrimaryChainReportsMissingDeepgramCredentials() {
        let configuration = SpeechTranscriptionConfiguration.default

        let result = PrimaryChainPreflight.evaluate(
            configuration: configuration,
            environment: [:]
        )

        XCTAssertEqual(result.status, .unavailable)
        XCTAssertEqual(result.messages, [
            "Deepgram API key is not configured"
        ])
    }

    func testOpenAIRealtimeTranscriptionIsAvailableWithCredentials() {
        let configuration = SpeechTranscriptionConfiguration(
            provider: .whisper,
            localeIdentifier: "en-US",
            whisperBinaryPath: nil,
            whisperModelPath: nil,
            transcriptionExecutionMode: .hosted,
            hostedTranscriptionProviderID: SpeechTranscriptionConfiguration.defaultOpenAIRealtimeTranscriptionProviderID,
            hostedTranscriptionModelID: SpeechTranscriptionConfiguration.defaultOpenAIRealtimeTranscriptionModelID,
            openRouterAPIKey: "openrouter-key",
            openAIRealtimeAPIKey: "openai-key"
        )

        let result = PrimaryChainPreflight.evaluate(
            configuration: configuration,
            environment: [:]
        )

        XCTAssertEqual(result.status, .available)
        XCTAssertEqual(result.messages, [])
    }

    func testAliyunRealtimeTranscriptionReportsMissingDashScopeCredentials() {
        let configuration = SpeechTranscriptionConfiguration(
            provider: .whisper,
            localeIdentifier: "zh-CN",
            whisperBinaryPath: nil,
            whisperModelPath: nil,
            transcriptionExecutionMode: .hosted,
            hostedTranscriptionProviderID: SpeechTranscriptionConfiguration.defaultAliyunRealtimeTranscriptionProviderID,
            hostedTranscriptionModelID: SpeechTranscriptionConfiguration.defaultAliyunRealtimeTranscriptionModelID
        )

        let missing = PrimaryChainPreflight.evaluate(
            configuration: configuration,
            environment: [:]
        )
        let available = PrimaryChainPreflight.evaluate(
            configuration: configuration,
            environment: ["DASHSCOPE_API_KEY": "dashscope-key"]
        )

        XCTAssertEqual(missing.status, .unavailable)
        XCTAssertEqual(missing.messages, ["DashScope API key is not configured"])
        XCTAssertEqual(available.status, .available)
        XCTAssertEqual(available.messages, [])
    }

    func testEnvironmentCredentialsSatisfyPreflight() {
        let result = PrimaryChainPreflight.evaluate(
            configuration: .default,
            environment: [
                "MEETING_AGENT_DEEPGRAM_API_KEY": "deepgram-key"
            ]
        )

        XCTAssertEqual(result.status, .available)
        XCTAssertEqual(result.messages, [])
    }
}
