import Foundation

public struct DeepgramTranscriptReconciliationOutput: Equatable {
    public let realtimeUpdates: [TranscriptSegmentAccumulationResult]
    public let finalUpdates: [TranscriptSegmentAccumulationResult]
    public let finalDocument: TranscriptDocument
}

public struct DeepgramTranscriptReconciler {
    private var realtimeAccumulator = TranscriptSegmentAccumulator()
    private var finalSegments: [TranscriptSegment] = []

    public init() {}

    public mutating func apply(_ segments: [TranscriptSegment]) -> DeepgramTranscriptReconciliationOutput {
        var realtimeUpdates: [TranscriptSegmentAccumulationResult] = []
        var finalUpdates: [TranscriptSegmentAccumulationResult] = []

        for segment in segments {
            let realtimeResult = realtimeAccumulator.apply(.upsert(segment))
            realtimeUpdates.append(TranscriptSegmentAccumulationResult(
                document: realtimeResult.document,
                changedSegmentIDs: realtimeResult.changedSegmentIDs,
                plainTextReplacement: realtimeResult.plainTextReplacement,
                source: .realtime
            ))

            guard segment.isFinal else { continue }
            upsertFinal(segment)
            let document = TranscriptDocument(segments: finalSegments)
            finalUpdates.append(TranscriptSegmentAccumulationResult(
                document: document,
                changedSegmentIDs: [segment.id],
                plainTextReplacement: nil,
                source: .final
            ))
        }

        return DeepgramTranscriptReconciliationOutput(
            realtimeUpdates: realtimeUpdates,
            finalUpdates: finalUpdates,
            finalDocument: TranscriptDocument(segments: finalSegments)
        )
    }

    public mutating func apply(_ segment: TranscriptSegment) -> DeepgramTranscriptReconciliationOutput {
        apply([segment])
    }

    private mutating func upsertFinal(_ incoming: TranscriptSegment) {
        if let sameID = finalSegments.firstIndex(where: { $0.id == incoming.id }) {
            finalSegments[sameID] = segment(incoming, preservingTranslationFrom: finalSegments[sameID])
            sortFinalSegments()
            return
        }

        if incoming.timingSource == .precise,
           let overlap = finalSegments.firstIndex(where: { finalOverlaps($0, incoming) }) {
            finalSegments[overlap] = segment(incoming, preservingTranslationFrom: finalSegments[overlap])
            sortFinalSegments()
            return
        }

        finalSegments.append(incoming)
        sortFinalSegments()
    }

    private mutating func sortFinalSegments() {
        finalSegments.sort { first, second in
            let firstStart = first.startTimeSeconds ?? .greatestFiniteMagnitude
            let secondStart = second.startTimeSeconds ?? .greatestFiniteMagnitude
            if firstStart != secondStart {
                return firstStart < secondStart
            }
            return first.createdAt < second.createdAt
        }
    }

    private func finalOverlaps(_ existing: TranscriptSegment, _ incoming: TranscriptSegment) -> Bool {
        guard existing.sourceProvider == incoming.sourceProvider,
              speakersAreCompatible(existing.speaker, incoming.speaker),
              existing.timingSource == .precise,
              incoming.timingSource == .precise,
              let existingStart = existing.startTimeSeconds,
              let existingEnd = existing.endTimeSeconds,
              let incomingStart = incoming.startTimeSeconds,
              let incomingEnd = incoming.endTimeSeconds
        else {
            return false
        }
        let overlap = min(existingEnd, incomingEnd) - max(existingStart, incomingStart)
        guard overlap > 0 else { return false }
        let shorter = min(existingEnd - existingStart, incomingEnd - incomingStart)
        return shorter <= 0 || overlap / shorter >= 0.5
    }

    private func speakersAreCompatible(_ first: TranscriptSpeaker, _ second: TranscriptSpeaker) -> Bool {
        guard let firstID = first.identifier,
              let secondID = second.identifier
        else {
            return true
        }
        return firstID == secondID
    }

    private func segment(
        _ incoming: TranscriptSegment,
        preservingTranslationFrom existing: TranscriptSegment
    ) -> TranscriptSegment {
        guard incoming.translatedText == nil,
              incoming.translationTargetLocale == nil,
              incoming.translationIsFinal == nil
        else {
            return incoming
        }
        return TranscriptSegment(
            id: incoming.id,
            speaker: incoming.speaker,
            startTimeSeconds: incoming.startTimeSeconds,
            endTimeSeconds: incoming.endTimeSeconds,
            text: incoming.text,
            language: incoming.language,
            sourceProvider: incoming.sourceProvider,
            isFinal: incoming.isFinal,
            speechFinal: incoming.speechFinal,
            confidence: incoming.confidence,
            createdAt: incoming.createdAt,
            timingSource: incoming.timingSource,
            translatedText: existing.translatedText,
            translationTargetLocale: existing.translationTargetLocale,
            translationIsFinal: existing.translationIsFinal
        )
    }
}
