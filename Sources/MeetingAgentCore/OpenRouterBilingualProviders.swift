import Foundation

public struct OpenRouterAudioTranscriptionProvider: AudioTranscriptionProvider {
    public let descriptor = ProviderDescriptor(
        id: "openrouter-transcribe",
        displayName: "OpenRouter Transcribe",
        capability: .audioTranscription,
        executionMode: .hosted,
        supportedSourceLocales: ["*"],
        supportedTargetLocales: [],
        requiresNetwork: true,
        requiresAPIKey: true
    )

    private let configuration: OpenRouterChatConfiguration
    private let client: OpenRouterChatClient

    public init(
        configuration: OpenRouterChatConfiguration,
        client: OpenRouterChatClient = URLSessionOpenRouterChatClient()
    ) {
        self.configuration = configuration
        self.client = client
    }

    public func transcribe(audio: AudioInput, options: TranscriptionOptions) async throws -> TranscriptDocument {
        guard let wavURL = audio.wavURL else {
            throw OpenRouterChatError.unavailable("OpenRouter transcription requires a WAV file URL")
        }
        let content = try await client.complete(
            configuration: configuration,
            messages: Self.messages(wavURL: wavURL, sourceLocale: options.sourceLocale),
            responseFormat: OpenRouterResponseFormat(type: "json_object")
        )
        let payload = try Self.decodePayload(from: content)
        return TranscriptDocument(segments: payload.segments.map { segment in
            TranscriptSegment(
                id: SpeechTranscriptionConfiguration.normalized(segment.id) ?? UUID().uuidString,
                speaker: TranscriptSpeaker(identifier: segment.speakerID, label: segment.speakerLabel),
                startTimeSeconds: segment.startTimeSeconds,
                endTimeSeconds: segment.endTimeSeconds,
                text: segment.text,
                language: SpeechTranscriptionConfiguration.normalized(segment.language) ?? options.sourceLocale,
                sourceProvider: descriptor.id,
                confidence: segment.confidence,
                timingSource: segment.startTimeSeconds == nil && segment.endTimeSeconds == nil ? .unavailable : .approximate
            )
        })
    }

    private static func messages(wavURL: URL, sourceLocale: String) -> [OpenRouterChatMessage] {
        [
            OpenRouterChatMessage(
                role: "system",
                content: "Transcribe meeting audio. Return only JSON with a segments array. Preserve timing, speaker, language, and confidence when available."
            ),
            OpenRouterChatMessage(
                role: "user",
                content: "Audio file URL: \(wavURL.path)\nSource locale: \(sourceLocale)"
            )
        ]
    }

    private static func decodePayload(from content: String) throws -> OpenRouterTranscriptionPayload {
        let json = try extractOpenRouterJSONObject(from: content)
        return try JSONDecoder.meetingAgent.decode(OpenRouterTranscriptionPayload.self, from: Data(json.utf8))
    }
}

public struct OpenRouterTextTranslationProvider: TextTranslationProvider {
    public let descriptor = ProviderDescriptor(
        id: "openrouter-translation",
        displayName: "OpenRouter Translation",
        capability: .textTranslation,
        executionMode: .hosted,
        supportedSourceLocales: ["*"],
        supportedTargetLocales: ["*"],
        requiresNetwork: true,
        requiresAPIKey: true
    )

    private let configuration: OpenRouterChatConfiguration
    private let client: OpenRouterChatClient

    public init(
        configuration: OpenRouterChatConfiguration,
        client: OpenRouterChatClient = URLSessionOpenRouterChatClient()
    ) {
        self.configuration = configuration
        self.client = client
    }

    public func translate(transcript: TranscriptDocument, options: TranslationOptions) async throws -> TranslatedTranscript {
        let content = try await client.complete(
            configuration: configuration,
            messages: Self.messages(transcript: transcript, options: options),
            responseFormat: OpenRouterResponseFormat(type: "json_object")
        )
        let payload = try Self.decodePayload(from: content)
        let translationsByID = Dictionary(uniqueKeysWithValues: payload.segments.map { ($0.id, $0.targetText) })
        let segments = transcript.segments.map { sourceSegment -> BilingualSubtitleSegment in
            let targetText = translationsByID[sourceSegment.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return BilingualSubtitleSegment(
                id: sourceSegment.id,
                startTimeSeconds: sourceSegment.startTimeSeconds,
                endTimeSeconds: sourceSegment.endTimeSeconds,
                speaker: sourceSegment.speaker,
                sourceText: sourceSegment.text,
                targetText: targetText,
                confidence: sourceSegment.confidence,
                status: targetText.isEmpty ? .sourceOnly : .complete,
                errorMessage: targetText.isEmpty ? "OpenRouter response did not include a translation for segment \(sourceSegment.id)" : nil,
                providerChain: [descriptor.id]
            )
        }
        return TranslatedTranscript(
            sourceLocale: options.sourceLocale,
            targetLocale: options.targetLocale,
            segments: segments,
            provenance: PipelineProvenance(profileID: descriptor.id, successfulProviders: [descriptor.id])
        )
    }

    private static func messages(transcript: TranscriptDocument, options: TranslationOptions) -> [OpenRouterChatMessage] {
        let payload = transcript.segments.map { segment in
            "- id: \(segment.id)\n  text: \(segment.text)"
        }.joined(separator: "\n")
        return [
            OpenRouterChatMessage(
                role: "system",
                content: "Translate meeting transcript segments. Return only JSON with segments: [{id, targetText}]. Preserve IDs exactly."
            ),
            OpenRouterChatMessage(
                role: "user",
                content: "Source locale: \(options.sourceLocale)\nTarget locale: \(options.targetLocale)\nSegments:\n\(payload)"
            )
        ]
    }

    private static func decodePayload(from content: String) throws -> OpenRouterTranslationPayload {
        let json = try extractOpenRouterJSONObject(from: content)
        return try JSONDecoder.meetingAgent.decode(OpenRouterTranslationPayload.self, from: Data(json.utf8))
    }
}

private struct OpenRouterTranscriptionPayload: Decodable {
    let segments: [Segment]

    struct Segment: Decodable {
        let id: String?
        let startTimeSeconds: Double?
        let endTimeSeconds: Double?
        let speakerID: String?
        let speakerLabel: String?
        let text: String
        let language: String?
        let confidence: Double?
    }
}

private struct OpenRouterTranslationPayload: Decodable {
    let segments: [Segment]

    struct Segment: Decodable {
        let id: String
        let targetText: String
    }
}

private func extractOpenRouterJSONObject(from content: String) throws -> String {
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let start = trimmed.firstIndex(of: "{"),
          let end = trimmed.lastIndex(of: "}"),
          start <= end
    else {
        throw OpenRouterChatError.invalidJSONContent
    }
    return String(trimmed[start...end])
}
