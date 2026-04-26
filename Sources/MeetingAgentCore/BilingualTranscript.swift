import Foundation

public enum BilingualSubtitleSegmentStatus: String, Codable, Equatable {
    case complete
    case sourceOnly
    case targetOnly
    case failed
}

public struct PipelineProvenance: Codable, Equatable {
    public var profileID: String
    public var attemptedProviders: [String]
    public var successfulProviders: [String]
    public var fallbackReasons: [String: String]

    public init(
        profileID: String,
        attemptedProviders: [String] = [],
        successfulProviders: [String] = [],
        fallbackReasons: [String: String] = [:]
    ) {
        self.profileID = profileID
        self.attemptedProviders = attemptedProviders
        self.successfulProviders = successfulProviders
        self.fallbackReasons = fallbackReasons
    }
}

public struct TranslatedTranscript: Codable, Equatable {
    public var sourceLocale: String
    public var targetLocale: String
    public var segments: [BilingualSubtitleSegment]
    public var provenance: PipelineProvenance

    public init(
        sourceLocale: String,
        targetLocale: String,
        segments: [BilingualSubtitleSegment],
        provenance: PipelineProvenance
    ) {
        self.sourceLocale = sourceLocale
        self.targetLocale = targetLocale
        self.segments = segments
        self.provenance = provenance
    }
}

public struct BilingualTranscript: Codable, Equatable {
    public var sourceLocale: String
    public var targetLocale: String
    public var segments: [BilingualSubtitleSegment]
    public var provenance: PipelineProvenance

    public init(
        sourceLocale: String,
        targetLocale: String,
        segments: [BilingualSubtitleSegment],
        provenance: PipelineProvenance
    ) {
        self.sourceLocale = sourceLocale
        self.targetLocale = targetLocale
        self.segments = segments
        self.provenance = provenance
    }
}

public struct BilingualSubtitleSegment: Codable, Equatable, Identifiable {
    public var id: String
    public var speakerID: String?
    public var speakerLabel: String?
    public var startTimeSeconds: Double?
    public var endTimeSeconds: Double?
    public var sourceText: String
    public var targetText: String
    public var confidence: Double?
    public var status: BilingualSubtitleSegmentStatus
    public var errorMessage: String?
    public var providerChain: [String]

    public var speaker: TranscriptSpeaker {
        TranscriptSpeaker(identifier: speakerID, label: speakerLabel)
    }

    public init(
        id: String = UUID().uuidString,
        startTimeSeconds: Double? = nil,
        endTimeSeconds: Double? = nil,
        speaker: TranscriptSpeaker = .default,
        sourceText: String,
        targetText: String,
        confidence: Double? = nil,
        status: BilingualSubtitleSegmentStatus = .complete,
        errorMessage: String? = nil,
        providerChain: [String] = []
    ) {
        self.id = id
        self.speakerID = speaker.identifier
        self.speakerLabel = speaker.label
        self.startTimeSeconds = startTimeSeconds
        self.endTimeSeconds = endTimeSeconds
        self.sourceText = sourceText
        self.targetText = targetText
        self.confidence = confidence
        self.status = status
        self.errorMessage = errorMessage
        self.providerChain = providerChain
    }
}

public enum BilingualTranscriptFormatter {
    public static func render(_ transcript: BilingualTranscript) -> String {
        var mapper = SpeakerLabelMapper()
        return transcript.segments.map { segment in
            let targetText = renderedTarget(for: segment)
            return [
                mapper.label(for: segment.speaker) + ":",
                "Source: \(segment.sourceText)",
                "Target: \(targetText)"
            ].joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }

    private static func renderedTarget(for segment: BilingualSubtitleSegment) -> String {
        if !segment.targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return segment.targetText
        }
        if let errorMessage = segment.errorMessage, !errorMessage.isEmpty {
            return "[translation unavailable: \(errorMessage)]"
        }
        return "[translation unavailable]"
    }
}
