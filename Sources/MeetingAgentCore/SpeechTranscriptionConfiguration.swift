import Foundation

public enum SpeechConfigurationValidationStatus: Equatable {
    case available
    case unavailable(String)
}

public struct SpeechTranscriptionConfiguration: Codable, Equatable {
    public var provider: SpeechProvider
    public var localeIdentifier: String
    public var targetLocaleIdentifier: String
    public var bilingualPipelineProfileID: String
    public var whisperBinaryPath: String?
    public var whisperModelPath: String?

    public static let `default` = SpeechTranscriptionConfiguration(
        provider: .whisper,
        localeIdentifier: "en-US",
        targetLocaleIdentifier: "zh-CN",
        bilingualPipelineProfileID: "local-whisper-hosted-translation",
        whisperBinaryPath: nil,
        whisperModelPath: nil
    )

    public init(
        provider: SpeechProvider,
        localeIdentifier: String,
        targetLocaleIdentifier: String = "zh-CN",
        bilingualPipelineProfileID: String = "local-whisper-hosted-translation",
        whisperBinaryPath: String?,
        whisperModelPath: String?
    ) {
        self.provider = provider
        self.localeIdentifier = Self.normalized(localeIdentifier, fallback: "en-US") ?? "en-US"
        self.targetLocaleIdentifier = Self.normalized(targetLocaleIdentifier, fallback: "zh-CN") ?? "zh-CN"
        self.bilingualPipelineProfileID = Self.normalized(
            bilingualPipelineProfileID,
            fallback: "local-whisper-hosted-translation"
        ) ?? "local-whisper-hosted-translation"
        self.whisperBinaryPath = Self.normalized(whisperBinaryPath)
        self.whisperModelPath = Self.normalized(whisperModelPath)
    }

    private enum CodingKeys: String, CodingKey {
        case provider
        case localeIdentifier
        case targetLocaleIdentifier
        case bilingualPipelineProfileID
        case whisperBinaryPath
        case whisperModelPath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            provider: try container.decode(SpeechProvider.self, forKey: .provider),
            localeIdentifier: try container.decode(String.self, forKey: .localeIdentifier),
            targetLocaleIdentifier: try container.decodeIfPresent(String.self, forKey: .targetLocaleIdentifier) ?? "zh-CN",
            bilingualPipelineProfileID: try container.decodeIfPresent(String.self, forKey: .bilingualPipelineProfileID) ?? "local-whisper-hosted-translation",
            whisperBinaryPath: try container.decodeIfPresent(String.self, forKey: .whisperBinaryPath),
            whisperModelPath: try container.decodeIfPresent(String.self, forKey: .whisperModelPath)
        )
    }

    public func validationStatus(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> SpeechConfigurationValidationStatus {
        guard provider == .whisper else { return .available }
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
        let data = try JSONEncoder.meetingAgent.encode(configuration)
        userDefaults.set(data, forKey: key)
    }
}
