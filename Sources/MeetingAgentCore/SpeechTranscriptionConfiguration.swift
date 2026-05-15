import Foundation

public enum SpeechConfigurationValidationStatus: Equatable {
    case available
    case unavailable(String)
}

public struct SpeechTranscriptionConfiguration: Codable, Equatable {
    public static let defaultLocalTranscriptionProviderID = "whisper-local"
    public static let defaultHostedTranscriptionProviderID = "openrouter-transcribe"
    public static let defaultHostedTranscriptionModelID = "google/gemini-2.5-flash"
    public static let defaultHostedSummaryModelID = "openai/gpt-4.1-mini"
    public static let defaultDeepgramTranscriptionProviderID = "deepgram-transcribe"
    public static let defaultDeepgramModelID = "nova-3"
    public static let defaultOpenAIRealtimeTranscriptionProviderID = "openai-realtime-transcribe"
    public static let defaultOpenAIRealtimeTranscriptionModelID = "gpt-4o-transcribe"
    public static let defaultAliyunRealtimeTranscriptionProviderID = "aliyun-paraformer-realtime-transcribe"
    public static let defaultAliyunRealtimeTranscriptionModelID = "paraformer-realtime-v2"

    public var provider: SpeechProvider
    public var localeIdentifier: String
    public var whisperBinaryPath: String?
    public var whisperModelPath: String?
    public var transcriptionExecutionMode: ProviderExecutionMode
    public var localTranscriptionProviderID: String
    public var hostedTranscriptionProviderID: String
    public var hostedTranscriptionModelID: String
    public var hostedSummaryModelID: String
    public var openRouterAPIKey: String?
    public var openAIRealtimeAPIKey: String?
    public var deepgramAPIKey: String?
    public var deepgramModelID: String
    public var dashScopeAPIKey: String?
    public var aliyunRealtimeModelID: String

    public static let `default` = SpeechTranscriptionConfiguration(
        provider: .whisper,
        localeIdentifier: "en-US",
        whisperBinaryPath: nil,
        whisperModelPath: nil,
        transcriptionExecutionMode: .hosted,
        localTranscriptionProviderID: defaultLocalTranscriptionProviderID,
        hostedTranscriptionProviderID: defaultDeepgramTranscriptionProviderID,
        hostedTranscriptionModelID: defaultHostedTranscriptionModelID,
        hostedSummaryModelID: defaultHostedSummaryModelID,
        openRouterAPIKey: nil,
        openAIRealtimeAPIKey: nil,
        deepgramAPIKey: nil,
        deepgramModelID: defaultDeepgramModelID,
        dashScopeAPIKey: nil,
        aliyunRealtimeModelID: defaultAliyunRealtimeTranscriptionModelID
    )

    public init(
        provider: SpeechProvider,
        localeIdentifier: String,
        whisperBinaryPath: String?,
        whisperModelPath: String?,
        transcriptionExecutionMode: ProviderExecutionMode = .local,
        localTranscriptionProviderID: String = defaultLocalTranscriptionProviderID,
        hostedTranscriptionProviderID: String = defaultHostedTranscriptionProviderID,
        hostedTranscriptionModelID: String = defaultHostedTranscriptionModelID,
        hostedSummaryModelID: String = defaultHostedSummaryModelID,
        openRouterAPIKey: String? = nil,
        openAIRealtimeAPIKey: String? = nil,
        deepgramAPIKey: String? = nil,
        deepgramModelID: String = defaultDeepgramModelID,
        dashScopeAPIKey: String? = nil,
        aliyunRealtimeModelID: String = defaultAliyunRealtimeTranscriptionModelID
    ) {
        self.provider = provider
        self.localeIdentifier = Self.normalized(localeIdentifier, fallback: "en-US") ?? "en-US"
        self.whisperBinaryPath = Self.normalized(whisperBinaryPath)
        self.whisperModelPath = Self.normalized(whisperModelPath)
        self.transcriptionExecutionMode = transcriptionExecutionMode
        self.localTranscriptionProviderID = Self.normalized(
            localTranscriptionProviderID,
            fallback: Self.defaultLocalTranscriptionProviderID
        ) ?? Self.defaultLocalTranscriptionProviderID
        self.hostedTranscriptionProviderID = Self.normalized(
            hostedTranscriptionProviderID,
            fallback: Self.defaultHostedTranscriptionProviderID
        ) ?? Self.defaultHostedTranscriptionProviderID
        self.hostedTranscriptionModelID = Self.normalized(
            hostedTranscriptionModelID,
            fallback: Self.defaultHostedTranscriptionModelID
        ) ?? Self.defaultHostedTranscriptionModelID
        self.hostedSummaryModelID = Self.normalized(
            hostedSummaryModelID,
            fallback: Self.defaultHostedSummaryModelID
        ) ?? Self.defaultHostedSummaryModelID
        self.openRouterAPIKey = Self.normalized(openRouterAPIKey)
        self.openAIRealtimeAPIKey = Self.normalized(openAIRealtimeAPIKey)
        self.deepgramAPIKey = Self.normalized(deepgramAPIKey)
        self.deepgramModelID = Self.normalized(deepgramModelID, fallback: Self.defaultDeepgramModelID)
            ?? Self.defaultDeepgramModelID
        self.dashScopeAPIKey = Self.normalized(dashScopeAPIKey)
        self.aliyunRealtimeModelID = Self.normalized(
            aliyunRealtimeModelID,
            fallback: Self.defaultAliyunRealtimeTranscriptionModelID
        ) ?? Self.defaultAliyunRealtimeTranscriptionModelID
    }

    private enum CodingKeys: String, CodingKey {
        case provider
        case localeIdentifier
        // Legacy key used when translation had a separate target language setting.
        case targetLocaleIdentifier
        case whisperBinaryPath
        case whisperModelPath
        case transcriptionExecutionMode
        case localTranscriptionProviderID
        case hostedTranscriptionProviderID
        case hostedTranscriptionModelID
        case hostedSummaryModelID
        case openRouterAPIKey
        case openAIRealtimeAPIKey
        case deepgramAPIKey
        case deepgramModelID
        case dashScopeAPIKey
        case aliyunRealtimeModelID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedLocaleIdentifier = try container.decode(String.self, forKey: .localeIdentifier)
        let legacyTargetLocaleIdentifier = try container.decodeIfPresent(String.self, forKey: .targetLocaleIdentifier)
        let localeIdentifier = Self.normalized(legacyTargetLocaleIdentifier) ?? storedLocaleIdentifier
        self.init(
            provider: try container.decode(SpeechProvider.self, forKey: .provider),
            localeIdentifier: localeIdentifier,
            whisperBinaryPath: try container.decodeIfPresent(String.self, forKey: .whisperBinaryPath),
            whisperModelPath: try container.decodeIfPresent(String.self, forKey: .whisperModelPath),
            transcriptionExecutionMode: try container.decodeIfPresent(ProviderExecutionMode.self, forKey: .transcriptionExecutionMode) ?? .local,
            localTranscriptionProviderID: try container.decodeIfPresent(String.self, forKey: .localTranscriptionProviderID) ?? Self.defaultLocalTranscriptionProviderID,
            hostedTranscriptionProviderID: try container.decodeIfPresent(String.self, forKey: .hostedTranscriptionProviderID) ?? Self.defaultHostedTranscriptionProviderID,
            hostedTranscriptionModelID: try container.decodeIfPresent(String.self, forKey: .hostedTranscriptionModelID) ?? Self.defaultHostedTranscriptionModelID,
            hostedSummaryModelID: try container.decodeIfPresent(String.self, forKey: .hostedSummaryModelID) ?? Self.defaultHostedSummaryModelID,
            openRouterAPIKey: try container.decodeIfPresent(String.self, forKey: .openRouterAPIKey),
            openAIRealtimeAPIKey: try container.decodeIfPresent(String.self, forKey: .openAIRealtimeAPIKey),
            deepgramAPIKey: try container.decodeIfPresent(String.self, forKey: .deepgramAPIKey),
            deepgramModelID: try container.decodeIfPresent(String.self, forKey: .deepgramModelID) ?? Self.defaultDeepgramModelID,
            dashScopeAPIKey: try container.decodeIfPresent(String.self, forKey: .dashScopeAPIKey),
            aliyunRealtimeModelID: try container.decodeIfPresent(String.self, forKey: .aliyunRealtimeModelID)
                ?? Self.defaultAliyunRealtimeTranscriptionModelID
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .provider)
        try container.encode(localeIdentifier, forKey: .localeIdentifier)
        try container.encodeIfPresent(whisperBinaryPath, forKey: .whisperBinaryPath)
        try container.encodeIfPresent(whisperModelPath, forKey: .whisperModelPath)
        try container.encode(transcriptionExecutionMode, forKey: .transcriptionExecutionMode)
        try container.encode(localTranscriptionProviderID, forKey: .localTranscriptionProviderID)
        try container.encode(hostedTranscriptionProviderID, forKey: .hostedTranscriptionProviderID)
        try container.encode(hostedTranscriptionModelID, forKey: .hostedTranscriptionModelID)
        try container.encode(hostedSummaryModelID, forKey: .hostedSummaryModelID)
        try container.encodeIfPresent(openRouterAPIKey, forKey: .openRouterAPIKey)
        try container.encodeIfPresent(openAIRealtimeAPIKey, forKey: .openAIRealtimeAPIKey)
        try container.encodeIfPresent(deepgramAPIKey, forKey: .deepgramAPIKey)
        try container.encode(deepgramModelID, forKey: .deepgramModelID)
        try container.encodeIfPresent(dashScopeAPIKey, forKey: .dashScopeAPIKey)
        try container.encode(aliyunRealtimeModelID, forKey: .aliyunRealtimeModelID)
    }

    public func validationStatus(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        bundledResourceURL: URL? = Bundle.main.resourceURL,
        developmentResourceSearchRoots: [URL] = [URL(fileURLWithPath: FileManager.default.currentDirectoryPath)]
    ) -> SpeechConfigurationValidationStatus {
        if usesOpenRouter {
            guard Self.normalized(openRouterAPIKey) != nil
                || Self.normalized(environment["MEETING_AGENT_OPENROUTER_API_KEY"]) != nil
            else {
                return .unavailable("OpenRouter API key is not configured")
            }
        }
        if usesDeepgram {
            guard Self.normalized(deepgramAPIKey) != nil
                || Self.normalized(environment["MEETING_AGENT_DEEPGRAM_API_KEY"]) != nil
            else {
                return .unavailable("Deepgram API key is not configured")
            }
            guard Self.normalized(deepgramModelID) != nil else {
                return .unavailable("Deepgram model is not configured")
            }
        }
        if usesAliyunRealtime {
            guard Self.normalized(dashScopeAPIKey) != nil
                || Self.normalized(environment["DASHSCOPE_API_KEY"]) != nil
                || Self.normalized(environment["MEETING_AGENT_DASHSCOPE_API_KEY"]) != nil
            else {
                return .unavailable("DashScope API key is not configured")
            }
            guard Self.normalized(aliyunRealtimeModelID) != nil else {
                return .unavailable("Aliyun realtime model is not configured")
            }
        }
        if transcriptionExecutionMode == .hosted,
           !usesDeepgram,
           !usesAliyunRealtime,
           Self.normalized(hostedTranscriptionModelID) == nil {
            return .unavailable("Hosted transcription model is not configured")
        }
        guard transcriptionExecutionMode == .local,
              localTranscriptionProviderID == Self.defaultLocalTranscriptionProviderID,
              provider == .whisper
        else {
            return .available
        }
        guard let whisperBinaryPath = WhisperConfigurationResolver.binaryPath(
            explicitPath: whisperBinaryPath,
            environment: environment,
            fileManager: fileManager,
            bundledResourceURL: bundledResourceURL,
            developmentResourceSearchRoots: developmentResourceSearchRoots
        ) else {
            return .unavailable("Whisper binary path is not configured")
        }
        guard let whisperModelPath = WhisperConfigurationResolver.modelPath(
            explicitPath: whisperModelPath,
            environment: environment,
            fileManager: fileManager,
            bundledResourceURL: bundledResourceURL,
            developmentResourceSearchRoots: developmentResourceSearchRoots
        ) else {
            return .unavailable("Whisper model path is not configured")
        }

        let binaryURL = URL(fileURLWithPath: whisperBinaryPath)
        let modelURL = URL(fileURLWithPath: whisperModelPath)
        guard fileManager.fileExists(atPath: binaryURL.path) else {
            return .unavailable("Whisper binary does not exist at \(binaryURL.path)")
        }
        guard fileManager.isExecutableFile(atPath: binaryURL.path) else {
            return .unavailable("Whisper binary is not executable at \(binaryURL.path)")
        }
        guard fileManager.fileExists(atPath: modelURL.path) else {
            return .unavailable("Whisper model does not exist at \(modelURL.path)")
        }
        guard fileManager.isReadableFile(atPath: modelURL.path) else {
            return .unavailable("Whisper model is not readable at \(modelURL.path)")
        }
        return .available
    }

    public var usesOpenRouter: Bool {
        transcriptionExecutionMode == .hosted && hostedTranscriptionProviderID == Self.defaultHostedTranscriptionProviderID
    }

    public var usesDeepgram: Bool {
        transcriptionExecutionMode == .hosted
            && hostedTranscriptionProviderID == Self.defaultDeepgramTranscriptionProviderID
    }

    public var usesAliyunRealtime: Bool {
        transcriptionExecutionMode == .hosted
            && hostedTranscriptionProviderID == Self.defaultAliyunRealtimeTranscriptionProviderID
    }

    public var effectiveTranscriptionProviderID: String {
        transcriptionExecutionMode == .hosted ? hostedTranscriptionProviderID : localTranscriptionProviderID
    }

    public static func normalized(_ value: String?, fallback: String? = nil) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return fallback
        }
        return trimmed
    }
}

public final class SpeechTranscriptionConfigurationStore {
    private let userDefaults: UserDefaults
    private let key: String
    private let packagedDefaultsURL: URL?

    public init(
        userDefaults: UserDefaults = .standard,
        key: String = "SpeechTranscriptionConfiguration",
        packagedDefaultsURL: URL? = Bundle.main.url(
            forResource: "DefaultSpeechTranscriptionCredentials",
            withExtension: "json"
        )
    ) {
        self.userDefaults = userDefaults
        self.key = key
        self.packagedDefaultsURL = packagedDefaultsURL
    }

    public func load() throws -> SpeechTranscriptionConfiguration {
        guard let data = userDefaults.data(forKey: key) else {
            return try configurationWithPackagedDefaults()
        }
        return try JSONDecoder.meetingAgent.decode(SpeechTranscriptionConfiguration.self, from: data)
    }

    public func save(_ configuration: SpeechTranscriptionConfiguration) throws {
        let data = try JSONEncoder.meetingAgent.encode(configuration)
        userDefaults.set(data, forKey: key)
    }

    private func configurationWithPackagedDefaults() throws -> SpeechTranscriptionConfiguration {
        var configuration = SpeechTranscriptionConfiguration.default
        guard let packagedDefaultsURL else {
            return configuration
        }
        let data = try Data(contentsOf: packagedDefaultsURL)
        let defaults = try JSONDecoder.meetingAgent.decode(PackagedSpeechConfigurationDefaults.self, from: data)
        configuration.openRouterAPIKey = defaults.openRouterAPIKey
        configuration.deepgramAPIKey = defaults.deepgramAPIKey
        configuration.dashScopeAPIKey = defaults.dashScopeAPIKey
        return configuration
    }
}

private struct PackagedSpeechConfigurationDefaults: Decodable {
    let openRouterAPIKey: String?
    let deepgramAPIKey: String?
    let dashScopeAPIKey: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        openRouterAPIKey = SpeechTranscriptionConfiguration.normalized(
            try container.decodeIfPresent(String.self, forKey: .openRouterAPIKey)
        )
        deepgramAPIKey = SpeechTranscriptionConfiguration.normalized(
            try container.decodeIfPresent(String.self, forKey: .deepgramAPIKey)
        )
        dashScopeAPIKey = SpeechTranscriptionConfiguration.normalized(
            try container.decodeIfPresent(String.self, forKey: .dashScopeAPIKey)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case openRouterAPIKey
        case deepgramAPIKey
        case dashScopeAPIKey
    }
}
