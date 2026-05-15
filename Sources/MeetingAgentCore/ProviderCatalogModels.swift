import Foundation

public enum ProviderCapability: String, Codable, Equatable {
    case audioTranscription
}

public enum ProviderExecutionMode: String, Codable, Equatable, Hashable {
    case local
    case hosted
}

public struct ProviderDescriptor: Codable, Equatable {
    public var id: String
    public var displayName: String
    public var capability: ProviderCapability
    public var executionMode: ProviderExecutionMode
    public var supportedSourceLocales: [String]
    public var supportedTargetLocales: [String]
    public var requiresNetwork: Bool
    public var requiresAPIKey: Bool

    public init(
        id: String,
        displayName: String,
        capability: ProviderCapability,
        executionMode: ProviderExecutionMode,
        supportedSourceLocales: [String],
        supportedTargetLocales: [String],
        requiresNetwork: Bool,
        requiresAPIKey: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.capability = capability
        self.executionMode = executionMode
        self.supportedSourceLocales = supportedSourceLocales
        self.supportedTargetLocales = supportedTargetLocales
        self.requiresNetwork = requiresNetwork
        self.requiresAPIKey = requiresAPIKey
    }

    public func supports(sourceLocale: String, targetLocale: String?) -> Bool {
        supports(locale: sourceLocale, in: supportedSourceLocales)
            && (targetLocale.map { supports(locale: $0, in: supportedTargetLocales) } ?? true)
    }

    private func supports(locale: String, in supportedLocales: [String]) -> Bool {
        supportedLocales.contains("*") || supportedLocales.contains(locale)
    }
}

public struct ProviderRegistry {
    private var descriptorsByID: [String: ProviderDescriptor]

    public init(descriptors: [ProviderDescriptor]) {
        descriptorsByID = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0) })
    }

    public func descriptor(id: String) -> ProviderDescriptor? {
        descriptorsByID[id]
    }

    public func descriptors(capability: ProviderCapability) -> [ProviderDescriptor] {
        descriptorsByID.values
            .filter { $0.capability == capability }
            .sorted { $0.id < $1.id }
    }
}

public struct AudioInput: Equatable {
    public var wavURL: URL?
    public var frames: [AudioFrame]
    public var localeIdentifier: String

    public init(wavURL: URL? = nil, frames: [AudioFrame] = [], localeIdentifier: String) {
        self.wavURL = wavURL
        self.frames = frames
        self.localeIdentifier = localeIdentifier
    }
}

public struct TranscriptionOptions: Equatable {
    public var sourceLocale: String

    public init(sourceLocale: String) {
        self.sourceLocale = sourceLocale
    }
}

public protocol AudioTranscriptionProvider {
    var descriptor: ProviderDescriptor { get }
    func transcribe(audio: AudioInput, options: TranscriptionOptions) async throws -> TranscriptDocument
}
