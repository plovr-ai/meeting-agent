import Foundation

public enum PrimaryChainPreflightStatus: Equatable {
    case available
    case unavailable
}

public struct PrimaryChainPreflightResult: Equatable {
    public var status: PrimaryChainPreflightStatus
    public var messages: [String]

    public init(status: PrimaryChainPreflightStatus, messages: [String]) {
        self.status = status
        self.messages = messages
    }
}

public enum PrimaryChainPreflight {
    public static func evaluate(
        configuration: SpeechTranscriptionConfiguration,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> PrimaryChainPreflightResult {
        var messages: [String] = []

        if configuration.usesDeepgram,
           normalized(configuration.deepgramAPIKey) == nil,
           normalized(environment["MEETING_AGENT_DEEPGRAM_API_KEY"]) == nil {
            messages.append("Deepgram API key is not configured")
        }

        if configuration.hostedTranscriptionProviderID == SpeechTranscriptionConfiguration.defaultOpenAIRealtimeTranscriptionProviderID,
           normalized(configuration.openAIRealtimeAPIKey) == nil,
           normalized(environment["MEETING_AGENT_OPENAI_API_KEY"]) == nil {
            messages.append("OpenAI API key is not configured")
        }

        if configuration.usesAliyunRealtime,
           normalized(configuration.dashScopeAPIKey) == nil,
           normalized(environment["DASHSCOPE_API_KEY"]) == nil,
           normalized(environment["MEETING_AGENT_DASHSCOPE_API_KEY"]) == nil {
            messages.append("DashScope API key is not configured")
        }

        if configuration.usesOpenRouter,
           normalized(configuration.openRouterAPIKey) == nil,
           normalized(environment["MEETING_AGENT_OPENROUTER_API_KEY"]) == nil {
            messages.append("OpenRouter API key is not configured")
        }

        let uniqueMessages = Array(Set(messages)).sorted()
        return PrimaryChainPreflightResult(
            status: uniqueMessages.isEmpty ? .available : .unavailable,
            messages: uniqueMessages
        )
    }

    private static func normalized(_ value: String?) -> String? {
        SpeechTranscriptionConfiguration.normalized(value)
    }
}
