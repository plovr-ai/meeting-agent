import Foundation

public struct WhisperAudioTranscriptionProvider: AudioTranscriptionProvider {
    public let descriptor = ProviderDescriptor(
        id: "whisper-local",
        displayName: "Whisper Local",
        capability: .audioTranscription,
        executionMode: .local,
        supportedSourceLocales: ["*"],
        supportedTargetLocales: [],
        requiresNetwork: false,
        requiresAPIKey: false
    )

    private let speechProvider: SpeechTranscriptionProvider
    private let fileManager: FileManager

    public init(
        speechProvider: SpeechTranscriptionProvider = SpeechTranscriptionProviderFactory.provider(for: .whisper),
        fileManager: FileManager = .default
    ) {
        self.speechProvider = speechProvider
        self.fileManager = fileManager
    }

    public func transcribe(audio: AudioInput, options: TranscriptionOptions) async throws -> TranscriptDocument {
        let transcriptURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        let context = SpeechTranscriptionContext(
            inputAudioURL: audio.wavURL,
            transcriptURL: transcriptURL,
            localeIdentifier: options.sourceLocale,
            meetingID: nil,
            previousTranscript: nil
        )
        try await speechProvider.transcribeExistingAudio(context: context)
        let rawText = try String(contentsOf: transcriptURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty else {
            return TranscriptDocument(segments: [])
        }
        return TranscriptDocument(segments: [
            TranscriptSegment(
                text: rawText,
                language: options.sourceLocale,
                sourceProvider: descriptor.id
            )
        ])
    }
}
