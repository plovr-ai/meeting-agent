import Foundation

public enum SpeechRecognitionEvent: Equatable, Sendable {
    case hypothesis(SpeechUtterancePayload)
    case final(SpeechUtterancePayload)
    case providerStatus(ProviderStatus)

    public var payload: SpeechUtterancePayload? {
        switch self {
        case .hypothesis(let payload), .final(let payload):
            return payload
        case .providerStatus:
            return nil
        }
    }

    public var isFinal: Bool {
        switch self {
        case .final:
            return true
        case .hypothesis, .providerStatus:
            return false
        }
    }
}

public struct ProviderStatus: Equatable, Sendable {
    public let providerID: String
    public let message: String

    public init(providerID: String, message: String) {
        let normalizedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.providerID = normalizedProviderID.isEmpty ? "unknown" : normalizedProviderID
        self.message = message.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct SpeechBoundary: Equatable, Sendable {
    public let speechFinal: Bool
    public let punctuationFinal: Bool
    public let pauseDurationSeconds: Double?

    public var endsTurn: Bool {
        speechFinal || punctuationFinal || pauseDurationSeconds != nil
    }

    public init(
        speechFinal: Bool = false,
        punctuationFinal: Bool = false,
        pauseDurationSeconds: Double? = nil
    ) {
        self.speechFinal = speechFinal
        self.punctuationFinal = punctuationFinal
        self.pauseDurationSeconds = pauseDurationSeconds
    }

    public static func detectsPunctuationFinal(in text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else {
            return false
        }
        return ["。", "！", "？", ".", "!", "?"].contains(String(last))
    }
}

public struct SpeechUtteranceKey: Hashable, Equatable, Sendable {
    public let providerID: String
    public let speakerID: String?
    public let startTimeSeconds: Double?

    public init(providerID: String, speakerID: String?, startTimeSeconds: Double?) {
        let normalizedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.providerID = normalizedProviderID.isEmpty ? "unknown" : normalizedProviderID
        self.speakerID = speakerID.nilIfBlank
        self.startTimeSeconds = startTimeSeconds
    }
}

public struct SpeechUtterancePayload: Equatable, Sendable {
    public let providerID: String
    public let providerResultID: String?
    public let providerUtteranceID: String?
    public let fallbackKey: SpeechUtteranceKey
    public let speaker: TranscriptSpeaker?
    public let startTimeSeconds: Double?
    public let endTimeSeconds: Double?
    public let text: String
    public let language: String?
    public let confidence: Double?
    public let boundary: SpeechBoundary

    public init(
        providerID: String,
        providerResultID: String? = nil,
        providerUtteranceID: String?,
        speaker: TranscriptSpeaker?,
        startTimeSeconds: Double?,
        endTimeSeconds: Double?,
        text: String,
        language: String?,
        confidence: Double?,
        boundary: SpeechBoundary
    ) {
        let normalizedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.providerID = normalizedProviderID.isEmpty ? "unknown" : normalizedProviderID
        self.providerResultID = providerResultID.nilIfBlank
        self.providerUtteranceID = providerUtteranceID.nilIfBlank
        self.speaker = speaker
        self.startTimeSeconds = startTimeSeconds
        self.endTimeSeconds = endTimeSeconds
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.language = language.nilIfBlank
        self.confidence = confidence
        self.boundary = boundary
        self.fallbackKey = SpeechUtteranceKey(
            providerID: self.providerID,
            speakerID: speaker?.identifier,
            startTimeSeconds: startTimeSeconds
        )
    }
}

private extension Optional where Wrapped == String {
    var nilIfBlank: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
