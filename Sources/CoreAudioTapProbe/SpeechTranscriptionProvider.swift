import Foundation

enum SpeechProvider: String, Equatable {
    case local
    case whisper

    static var supportedValuesDescription: String {
        "local, whisper"
    }
}

protocol AudioFrameTranscriber: AnyObject {
    func append(_ frame: AudioFrame) throws
    func finish()
}

protocol SpeechTranscriptionProvider {
    var provider: SpeechProvider { get }
    func start(transcriptURL: URL, localeIdentifier: String) async throws -> AudioFrameTranscriber
}

struct LocalSpeechTranscriptionProvider: SpeechTranscriptionProvider {
    let provider: SpeechProvider = .local

    func start(transcriptURL: URL, localeIdentifier: String) async throws -> AudioFrameTranscriber {
        try await SystemSpeechTranscriber.start(
            transcriptURL: transcriptURL,
            localeIdentifier: localeIdentifier
        )
    }
}

enum SpeechTranscriptionProviderFactory {
    static func provider(for provider: SpeechProvider) -> SpeechTranscriptionProvider {
        switch provider {
        case .local:
            return LocalSpeechTranscriptionProvider()
        case .whisper:
            return LocalSpeechTranscriptionProvider()
        }
    }
}
