import Foundation

public enum SpeechProvider: String, Codable, Equatable, CaseIterable {
    case local
    case whisper

    public static var supportedValuesDescription: String {
        "local, whisper"
    }
}

public protocol AudioFrameTranscriber: AnyObject {
    var failureReason: String? { get }
    func append(_ frame: AudioFrame) throws
    func finish()
}

public extension AudioFrameTranscriber {
    var failureReason: String? { nil }
}

public struct SpeechTranscriptionContext: Equatable {
    public let inputAudioURL: URL?
    public let transcriptURL: URL
    public let localeIdentifier: String
    public let meetingID: UUID?
    public let previousTranscript: String?

    public init(
        inputAudioURL: URL?,
        transcriptURL: URL,
        localeIdentifier: String,
        meetingID: UUID?,
        previousTranscript: String?
    ) {
        self.inputAudioURL = inputAudioURL
        self.transcriptURL = transcriptURL
        self.localeIdentifier = localeIdentifier
        self.meetingID = meetingID
        self.previousTranscript = previousTranscript
    }
}

public protocol SpeechTranscriptionProvider {
    var provider: SpeechProvider { get }
    func start(transcriptURL: URL, localeIdentifier: String) async throws -> AudioFrameTranscriber
    func transcribeExistingAudio(context: SpeechTranscriptionContext) async throws
}

public extension SpeechTranscriptionProvider {
    func transcribeExistingAudio(context: SpeechTranscriptionContext) async throws {
        throw ProbeError.speechRecognition("\(provider.rawValue) does not support retrying from an existing audio file")
    }
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
    public static func provider(
        for provider: SpeechProvider,
        configuration: SpeechTranscriptionConfiguration = .default
    ) -> SpeechTranscriptionProvider {
        switch provider {
        case .local:
            return LocalSpeechTranscriptionProvider()
        case .whisper:
            return WhisperSpeechTranscriptionProvider(appConfiguration: configuration)
        }
    }
}
