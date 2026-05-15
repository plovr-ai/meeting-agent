import Foundation

public final class MicrophoneSpeakerAttributionSink: TranscriptUpdateSink, SpeechRecognitionEventSink {
    public static let localUserSpeaker = TranscriptSpeaker(identifier: "local-user", label: "Me")

    private let transcriptDownstream: TranscriptUpdateSink?
    private let eventDownstream: SpeechRecognitionEventSink?

    public init(downstream: SpeechRecognitionEventSink) {
        self.transcriptDownstream = nil
        self.eventDownstream = downstream
    }

    public init(downstream: TranscriptUpdateSink & SpeechRecognitionEventSink) {
        self.transcriptDownstream = downstream
        self.eventDownstream = downstream
    }

    public func receive(_ event: SpeechRecognitionEvent) {
        eventDownstream?.receive(Self.attributed(event))
    }

    public func receive(_ update: TranscriptSegmentUpdate) {
        transcriptDownstream?.receive(Self.attributed(update))
    }

    public func receiveRealtime(_ update: TranscriptSegmentUpdate) {
        transcriptDownstream?.receiveRealtime(Self.attributed(update))
    }

    public func receiveFinal(_ update: TranscriptSegmentUpdate) {
        transcriptDownstream?.receiveFinal(Self.attributed(update))
    }

    public static func attributed(_ event: SpeechRecognitionEvent) -> SpeechRecognitionEvent {
        switch event {
        case .hypothesis(let payload):
            return .hypothesis(payload.withSpeaker(localUserSpeaker))
        case .final(let payload):
            return .final(payload.withSpeaker(localUserSpeaker))
        case .providerStatus:
            return event
        }
    }

    public static func attributed(_ update: TranscriptSegmentUpdate) -> TranscriptSegmentUpdate {
        switch update {
        case .upsert(let segment):
            return .upsert(segment.withSpeaker(localUserSpeaker))
        case .replaceAll(let segments):
            return .replaceAll(segments.map { $0.withSpeaker(localUserSpeaker) })
        case .replaceWithPlainText, .translationPatch:
            return update
        }
    }
}

extension SpeechUtterancePayload {
    func withSpeaker(_ speaker: TranscriptSpeaker?) -> SpeechUtterancePayload {
        SpeechUtterancePayload(
            providerID: providerID,
            providerResultID: providerResultID,
            providerUtteranceID: providerUtteranceID,
            speaker: speaker,
            startTimeSeconds: startTimeSeconds,
            endTimeSeconds: endTimeSeconds,
            text: text,
            language: language,
            confidence: confidence,
            boundary: boundary
        )
    }
}

extension TranscriptSegment {
    func withSpeaker(_ speaker: TranscriptSpeaker) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            speaker: speaker,
            startTimeSeconds: startTimeSeconds,
            endTimeSeconds: endTimeSeconds,
            text: text,
            language: language,
            sourceProvider: sourceProvider,
            isFinal: isFinal,
            speechFinal: speechFinal,
            confidence: confidence,
            createdAt: createdAt,
            timingSource: timingSource,
            translatedText: translatedText,
            translationTargetLocale: translationTargetLocale,
            translationIsFinal: translationIsFinal
        )
    }
}
