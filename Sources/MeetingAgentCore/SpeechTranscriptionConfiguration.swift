import Foundation

public enum SpeechConfigurationValidationStatus: Equatable {
    case available
    case unavailable(String)
}

public struct SpeechTranscriptionConfiguration: Codable, Equatable {
    public static let defaultBilingualPipelineProfileID = "local-whisper-hosted-translation"
    public static let defaultLocalTranscriptionProviderID = "whisper-local"
    public static let defaultLocalTranslationProviderID = "qwen-local-translation"
    public static let defaultHostedTranscriptionProviderID = "openrouter-transcribe"
    public static let defaultHostedTranslationProviderID = "openrouter-translation"
    public static let defaultHostedTranscriptionModelID = "google/gemini-2.5-flash"
    public static let defaultHostedTranslationModelID = "openai/gpt-4.1-mini"
    public static let defaultDeepgramTranscriptionProviderID = "deepgram-transcribe"
    public static let defaultDeepgramModelID = "nova-3"

    public var provider: SpeechProvider
    public var localeIdentifier: String
    public var targetLocaleIdentifier: String
    public var bilingualPipelineProfileID: String
    public var whisperBinaryPath: String?
    public var whisperModelPath: String?
    public var transcriptionExecutionMode: ProviderExecutionMode
    public var translationExecutionMode: ProviderExecutionMode
    public var localTranscriptionProviderID: String
    public var localTranslationProviderID: String
    public var hostedTranscriptionProviderID: String
    public var hostedTranslationProviderID: String
    public var hostedTranscriptionModelID: String
    public var hostedTranslationModelID: String
    public var openRouterAPIKey: String?
    public var openAIRealtimeAPIKey: String?
    public var deepgramAPIKey: String?
    public var deepgramModelID: String

    public static let `default` = SpeechTranscriptionConfiguration(
        provider: .whisper,
        localeIdentifier: "en-US",
        targetLocaleIdentifier: "zh-CN",
        bilingualPipelineProfileID: defaultBilingualPipelineProfileID,
        whisperBinaryPath: nil,
        whisperModelPath: nil,
        transcriptionExecutionMode: .local,
        translationExecutionMode: .hosted,
        localTranscriptionProviderID: defaultLocalTranscriptionProviderID,
        localTranslationProviderID: defaultLocalTranslationProviderID,
        hostedTranscriptionProviderID: defaultHostedTranscriptionProviderID,
        hostedTranslationProviderID: defaultHostedTranslationProviderID,
        hostedTranscriptionModelID: defaultHostedTranscriptionModelID,
        hostedTranslationModelID: defaultHostedTranslationModelID,
        openRouterAPIKey: nil,
        openAIRealtimeAPIKey: nil,
        deepgramAPIKey: nil,
        deepgramModelID: defaultDeepgramModelID
    )

    public init(
        provider: SpeechProvider,
        localeIdentifier: String,
        targetLocaleIdentifier: String = "zh-CN",
        bilingualPipelineProfileID: String = defaultBilingualPipelineProfileID,
        whisperBinaryPath: String?,
        whisperModelPath: String?,
        transcriptionExecutionMode: ProviderExecutionMode = .local,
        translationExecutionMode: ProviderExecutionMode = .hosted,
        localTranscriptionProviderID: String = defaultLocalTranscriptionProviderID,
        localTranslationProviderID: String = defaultLocalTranslationProviderID,
        hostedTranscriptionProviderID: String = defaultHostedTranscriptionProviderID,
        hostedTranslationProviderID: String = defaultHostedTranslationProviderID,
        hostedTranscriptionModelID: String = defaultHostedTranscriptionModelID,
        hostedTranslationModelID: String = defaultHostedTranslationModelID,
        openRouterAPIKey: String? = nil,
        openAIRealtimeAPIKey: String? = nil,
        deepgramAPIKey: String? = nil,
        deepgramModelID: String = defaultDeepgramModelID
    ) {
        self.provider = provider
        self.localeIdentifier = Self.normalized(localeIdentifier, fallback: "en-US") ?? "en-US"
        self.targetLocaleIdentifier = Self.normalized(targetLocaleIdentifier, fallback: "zh-CN") ?? "zh-CN"
        self.bilingualPipelineProfileID = Self.normalized(
            bilingualPipelineProfileID,
            fallback: Self.defaultBilingualPipelineProfileID
        ) ?? Self.defaultBilingualPipelineProfileID
        self.whisperBinaryPath = Self.normalized(whisperBinaryPath)
        self.whisperModelPath = Self.normalized(whisperModelPath)
        self.transcriptionExecutionMode = transcriptionExecutionMode
        self.translationExecutionMode = translationExecutionMode
        self.localTranscriptionProviderID = Self.normalized(
            localTranscriptionProviderID,
            fallback: Self.defaultLocalTranscriptionProviderID
        ) ?? Self.defaultLocalTranscriptionProviderID
        self.localTranslationProviderID = Self.normalized(
            localTranslationProviderID,
            fallback: Self.defaultLocalTranslationProviderID
        ) ?? Self.defaultLocalTranslationProviderID
        self.hostedTranscriptionProviderID = Self.normalized(
            hostedTranscriptionProviderID,
            fallback: Self.defaultHostedTranscriptionProviderID
        ) ?? Self.defaultHostedTranscriptionProviderID
        self.hostedTranslationProviderID = Self.normalized(
            hostedTranslationProviderID,
            fallback: Self.defaultHostedTranslationProviderID
        ) ?? Self.defaultHostedTranslationProviderID
        self.hostedTranscriptionModelID = Self.normalized(
            hostedTranscriptionModelID,
            fallback: Self.defaultHostedTranscriptionModelID
        ) ?? Self.defaultHostedTranscriptionModelID
        self.hostedTranslationModelID = Self.normalized(
            hostedTranslationModelID,
            fallback: Self.defaultHostedTranslationModelID
        ) ?? Self.defaultHostedTranslationModelID
        self.openRouterAPIKey = Self.normalized(openRouterAPIKey)
        self.openAIRealtimeAPIKey = Self.normalized(openAIRealtimeAPIKey)
        self.deepgramAPIKey = Self.normalized(deepgramAPIKey)
        self.deepgramModelID = Self.normalized(deepgramModelID, fallback: Self.defaultDeepgramModelID)
            ?? Self.defaultDeepgramModelID
    }

    private enum CodingKeys: String, CodingKey {
        case provider
        case localeIdentifier
        case targetLocaleIdentifier
        case bilingualPipelineProfileID
        case whisperBinaryPath
        case whisperModelPath
        case transcriptionExecutionMode
        case translationExecutionMode
        case localTranscriptionProviderID
        case localTranslationProviderID
        case hostedTranscriptionProviderID
        case hostedTranslationProviderID
        case hostedTranscriptionModelID
        case hostedTranslationModelID
        case openRouterAPIKey
        case openAIRealtimeAPIKey
        case deepgramAPIKey
        case deepgramModelID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            provider: try container.decode(SpeechProvider.self, forKey: .provider),
            localeIdentifier: try container.decode(String.self, forKey: .localeIdentifier),
            targetLocaleIdentifier: try container.decodeIfPresent(String.self, forKey: .targetLocaleIdentifier) ?? "zh-CN",
            bilingualPipelineProfileID: try container.decodeIfPresent(String.self, forKey: .bilingualPipelineProfileID) ?? Self.defaultBilingualPipelineProfileID,
            whisperBinaryPath: try container.decodeIfPresent(String.self, forKey: .whisperBinaryPath),
            whisperModelPath: try container.decodeIfPresent(String.self, forKey: .whisperModelPath),
            transcriptionExecutionMode: try container.decodeIfPresent(ProviderExecutionMode.self, forKey: .transcriptionExecutionMode) ?? .local,
            translationExecutionMode: try container.decodeIfPresent(ProviderExecutionMode.self, forKey: .translationExecutionMode) ?? .hosted,
            localTranscriptionProviderID: try container.decodeIfPresent(String.self, forKey: .localTranscriptionProviderID) ?? Self.defaultLocalTranscriptionProviderID,
            localTranslationProviderID: try container.decodeIfPresent(String.self, forKey: .localTranslationProviderID) ?? Self.defaultLocalTranslationProviderID,
            hostedTranscriptionProviderID: try container.decodeIfPresent(String.self, forKey: .hostedTranscriptionProviderID) ?? Self.defaultHostedTranscriptionProviderID,
            hostedTranslationProviderID: try container.decodeIfPresent(String.self, forKey: .hostedTranslationProviderID) ?? Self.defaultHostedTranslationProviderID,
            hostedTranscriptionModelID: try container.decodeIfPresent(String.self, forKey: .hostedTranscriptionModelID) ?? Self.defaultHostedTranscriptionModelID,
            hostedTranslationModelID: try container.decodeIfPresent(String.self, forKey: .hostedTranslationModelID) ?? Self.defaultHostedTranslationModelID,
            openRouterAPIKey: try container.decodeIfPresent(String.self, forKey: .openRouterAPIKey),
            openAIRealtimeAPIKey: try container.decodeIfPresent(String.self, forKey: .openAIRealtimeAPIKey),
            deepgramAPIKey: try container.decodeIfPresent(String.self, forKey: .deepgramAPIKey),
            deepgramModelID: try container.decodeIfPresent(String.self, forKey: .deepgramModelID) ?? Self.defaultDeepgramModelID
        )
    }

    public func validationStatus(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
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
        if transcriptionExecutionMode == .hosted,
           Self.normalized(hostedTranscriptionModelID) == nil {
            return .unavailable("Hosted transcription model is not configured")
        }
        if translationExecutionMode == .hosted,
           Self.normalized(hostedTranslationModelID) == nil {
            return .unavailable("Hosted translation model is not configured")
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
            fileManager: fileManager
        ) else {
            return .unavailable("Whisper binary path is not configured")
        }
        guard let whisperModelPath = WhisperConfigurationResolver.modelPath(
            explicitPath: whisperModelPath,
            environment: environment
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
        (transcriptionExecutionMode == .hosted && hostedTranscriptionProviderID == Self.defaultHostedTranscriptionProviderID)
            || (translationExecutionMode == .hosted && hostedTranslationProviderID == Self.defaultHostedTranslationProviderID)
    }

    public var usesDeepgram: Bool {
        transcriptionExecutionMode == .hosted
            && hostedTranscriptionProviderID == Self.defaultDeepgramTranscriptionProviderID
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

    public init(
        userDefaults: UserDefaults = .standard,
        key: String = "SpeechTranscriptionConfiguration"
    ) {
        self.userDefaults = userDefaults
        self.key = key
    }

    public func load() throws -> SpeechTranscriptionConfiguration {
        guard let data = userDefaults.data(forKey: key) else {
            return .default
        }
        return try JSONDecoder.meetingAgent.decode(SpeechTranscriptionConfiguration.self, from: data)
    }

    public func save(_ configuration: SpeechTranscriptionConfiguration) throws {
        var persisted = configuration
        persisted.openRouterAPIKey = nil
        persisted.openAIRealtimeAPIKey = nil
        persisted.deepgramAPIKey = nil
        let data = try JSONEncoder.meetingAgent.encode(persisted)
        userDefaults.set(data, forKey: key)
    }
}
