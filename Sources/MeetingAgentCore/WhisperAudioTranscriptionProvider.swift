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
        configuration: SpeechTranscriptionConfiguration = .default,
        speechProvider: SpeechTranscriptionProvider? = nil,
        fileManager: FileManager = .default
    ) {
        self.speechProvider = speechProvider ?? SpeechTranscriptionProviderFactory.provider(
            for: .whisper,
            configuration: configuration
        )
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
        let document = try await speechProvider.transcribeExistingAudio(context: context)
        return TranscriptDocument(
            version: document.version,
            segments: document.segments.map { segment in
                TranscriptSegment(
                    id: segment.id,
                    speaker: segment.speaker,
                    startTimeSeconds: segment.startTimeSeconds,
                    endTimeSeconds: segment.endTimeSeconds,
                    text: segment.text,
                    language: segment.language ?? options.sourceLocale,
                    sourceProvider: descriptor.id,
                    isFinal: segment.isFinal,
                    speechFinal: segment.speechFinal,
                    confidence: segment.confidence,
                    createdAt: segment.createdAt,
                    timingSource: segment.timingSource,
                    translatedText: segment.translatedText,
                    translationTargetLocale: segment.translationTargetLocale,
                    translationIsFinal: segment.translationIsFinal
                )
            }
        )
    }
}
