import Foundation

enum TranscriptSpeakerLabeler {
    static func assignSpeakerLabels(to segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var mapper = SpeakerLabelMapper(speakers: segments.map(\.speaker))
        var generatedIDsBySpeaker: [TranscriptSpeaker: String] = [:]
        var nextSpeakerIndex = 1
        return segments.map { segment in
            let speaker = segment.speaker
            let label = mapper.label(for: speaker)
            let speakerID: String
            if let existingID = speaker.identifier {
                speakerID = existingID
            } else if let generatedID = generatedIDsBySpeaker[speaker] {
                speakerID = generatedID
            } else {
                speakerID = "speaker-\(nextSpeakerIndex)"
                generatedIDsBySpeaker[speaker] = speakerID
                nextSpeakerIndex += 1
            }
            return TranscriptSegment(
                id: segment.id,
                speaker: TranscriptSpeaker(identifier: speakerID, label: segment.speakerLabel ?? label),
                startTimeSeconds: segment.startTimeSeconds,
                endTimeSeconds: segment.endTimeSeconds,
                text: segment.text,
                language: segment.language,
                sourceProvider: segment.sourceProvider,
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
    }
}
