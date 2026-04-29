import Foundation

public enum CaptionTurnEvent: Equatable {
    case draftUpdated(LiveCaptionTurn)
    case interimUpdated(TranscriptSegment)
    case sealed(LiveCaptionTurn)
    case removed(turnID: String)
}

public struct CaptionTurnAssembler: Equatable {
    private var chunker: LiveCaptionChunker
    private var interimTurnIDs: Set<String> = []
    private let sourceLocale: String
    private let targetLocale: String

    public init(
        sourceLocale: String,
        targetLocale: String,
        policy: LiveCaptionChunkingPolicy = LiveCaptionChunkingPolicy()
    ) {
        self.sourceLocale = sourceLocale
        self.targetLocale = targetLocale
        chunker = LiveCaptionChunker(
            sourceLocale: sourceLocale,
            targetLocale: targetLocale,
            policy: policy
        )
    }

    public mutating func apply(_ segment: TranscriptSegment) -> [CaptionTurnEvent] {
        guard !segment.isFinal else {
            return chunker.append(segment).map(event(from:))
        }

        interimTurnIDs.insert(segment.id)
        return [.interimUpdated(segment)]
    }

    public mutating func removeSegments(notIn segmentIDs: Set<String>) -> [CaptionTurnEvent] {
        let removedTurnIDs = interimTurnIDs.subtracting(segmentIDs).sorted()
        interimTurnIDs.subtract(removedTurnIDs)
        return removedTurnIDs.map { .removed(turnID: $0) }
    }

    public mutating func flush(reason: LiveCaptionFreezeReason) -> [CaptionTurnEvent] {
        chunker.flushOpenChunk(reason: reason).map(event(from:))
    }

    private func event(from update: LiveCaptionChunkUpdate) -> CaptionTurnEvent {
        if update.turn.displayState == .sealed {
            return .sealed(update.turn)
        }
        return .draftUpdated(update.turn)
    }
}
