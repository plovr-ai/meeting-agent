import Foundation

public enum SpeechProvider: String, Equatable {
    case local
    case whisper

    public static var supportedValuesDescription: String {
        "local, whisper"
    }
}

public protocol AudioFrameTranscriber: AnyObject {
    func append(_ frame: AudioFrame) throws
    func finish()
}

public protocol SpeechTranscriptionProvider {
    var provider: SpeechProvider { get }
    func start(transcriptURL: URL, localeIdentifier: String) async throws -> AudioFrameTranscriber
}

public struct LocalSpeechTranscriptionProvider: SpeechTranscriptionProvider {
    public let provider: SpeechProvider = .local

    public init() {}

    public func start(transcriptURL: URL, localeIdentifier: String) async throws -> AudioFrameTranscriber {
        try await SystemSpeechTranscriber.start(
            transcriptURL: transcriptURL,
            localeIdentifier: localeIdentifier
        )
    }
}

public enum SpeechTranscriptionProviderFactory {
    public static func provider(for provider: SpeechProvider) -> SpeechTranscriptionProvider {
        switch provider {
        case .local:
            return LocalSpeechTranscriptionProvider()
        case .whisper:
            return WhisperSpeechTranscriptionProvider()
        }
    }
}
