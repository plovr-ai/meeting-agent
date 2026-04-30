import Foundation

public enum CaptionTurnEvent: Equatable {
    case draftUpdated(LiveCaptionTurn)
    case interimUpdated(TranscriptSegment)
    case sealed(LiveCaptionTurn)
    case removed(turnID: String)
}

public struct CaptionTurnAssembler: Equatable {
    private var chunker: LiveCaptionChunker
    private var openDraftsBySegmentID: [String: LiveCaptionTurn] = [:]
    private var openDraftSegmentIDs: [String] = []
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
            clearOpenDraft(for: segment.id)
            return chunker.append(segment).map(event(from:))
        }

        let draft = draftTurn(for: segment)
        if openDraftsBySegmentID[segment.id] != nil {
            openDraftsBySegmentID[segment.id] = draft
            return [.draftUpdated(draft)]
        }
        openDraftSegmentIDs.append(segment.id)
        openDraftsBySegmentID[segment.id] = draft
        return [.interimUpdated(segment)]
    }

    public mutating func removeSegments(notIn segmentIDs: Set<String>) -> [CaptionTurnEvent] {
        let removedSegmentIDs = openDraftSegmentIDs.filter { !segmentIDs.contains($0) }
        for segmentID in removedSegmentIDs {
            openDraftsBySegmentID[segmentID] = nil
        }
        openDraftSegmentIDs.removeAll { !segmentIDs.contains($0) }
        return removedSegmentIDs.map { .removed(turnID: $0) }
    }

    public mutating func flush(reason: LiveCaptionFreezeReason) -> [CaptionTurnEvent] {
        var events = chunker.flushOpenChunk(reason: reason).map(event(from:))
        for segmentID in openDraftSegmentIDs {
            guard let draft = openDraftsBySegmentID[segmentID] else { continue }
            events.append(.sealed(LiveCaptionTurn(
                id: draft.id,
                sourceSegmentID: draft.sourceSegmentID,
                sourceSegmentIDs: draft.sourceSegmentIDs,
                speaker: draft.speaker,
                originalText: draft.originalText,
                translatedText: draft.translatedText,
                sourceLocale: draft.sourceLocale,
                targetLocale: draft.targetLocale,
                isFinal: true,
                captionHealth: draft.captionHealth,
                translationHealth: .pending,
                createdAt: draft.createdAt,
                chunkState: .frozen,
                translationRevision: draft.translationRevision,
                freezeReason: reason,
                displayState: .sealed,
                translationState: .final,
                boundaryReason: reason,
                boundaryStrength: reason.boundaryStrength
            )))
            openDraftsBySegmentID[segmentID] = nil
        }
        openDraftSegmentIDs.removeAll()
        return events
    }

    private func event(from update: LiveCaptionChunkUpdate) -> CaptionTurnEvent {
        if update.turn.displayState == .sealed {
            return .sealed(update.turn)
        }
        return .draftUpdated(update.turn)
    }

    private mutating func clearOpenDraft(for segmentID: String) {
        guard openDraftsBySegmentID[segmentID] != nil else { return }
        openDraftsBySegmentID[segmentID] = nil
        openDraftSegmentIDs.removeAll { $0 == segmentID }
    }

    private func draftTurn(for segment: TranscriptSegment) -> LiveCaptionTurn {
        let previous = openDraftsBySegmentID[segment.id]
        var translationRevision = 1
        var translatedText: String?
        var translationHealth: LivePipelineHealth = .pending
        var stableOriginalTextPrefix: String?
        var unstableOriginalTextTail: String?
        if let previous {
            translationRevision = previous.translationRevision
            if previous.originalText != segment.text {
                translationRevision += 1
            }
            translatedText = previous.translatedText
            if previous.originalText == segment.text {
                translationHealth = previous.translationHealth
            }
            let stability = stableDisplayText(previous: previous, segment: segment)
            stableOriginalTextPrefix = stability.prefix
            unstableOriginalTextTail = stability.tail
        }
        return LiveCaptionTurn(
            id: previous?.id ?? segment.id,
            sourceSegmentID: segment.id,
            sourceSegmentIDs: [segment.id],
            speaker: segment.speaker,
            originalText: segment.text,
            stableOriginalTextPrefix: stableOriginalTextPrefix,
            unstableOriginalTextTail: unstableOriginalTextTail,
            translatedText: translatedText,
            sourceLocale: segment.language ?? sourceLocale,
            targetLocale: targetLocale,
            isFinal: false,
            captionHealth: .live,
            translationHealth: translationHealth,
            createdAt: segment.createdAt,
            chunkState: .draft,
            translationRevision: translationRevision,
            freezeReason: nil,
            displayState: .draft,
            translationState: .draft,
            boundaryReason: nil,
            boundaryStrength: nil
        )
    }

    private func stableDisplayText(
        previous: LiveCaptionTurn,
        segment: TranscriptSegment
    ) -> (prefix: String, tail: String) {
        guard previous.speaker == segment.speaker else {
            return ("", segment.text)
        }
        let prefix = stablePrefix(previous.originalText, segment.text)
        let tail = String(segment.text.dropFirst(prefix.count))
        return (prefix, tail)
    }

    private func stablePrefix(_ previous: String, _ current: String) -> String {
        guard !previous.isEmpty, !current.isEmpty else { return "" }
        let previousCharacters = Array(previous)
        let currentCharacters = Array(current)
        var index = 0
        while index < previousCharacters.count,
              index < currentCharacters.count,
              previousCharacters[index] == currentCharacters[index] {
            index += 1
        }
        let rawPrefix = String(currentCharacters.prefix(index))
        if index == currentCharacters.count || index == previousCharacters.count {
            return rawPrefix
        }
        return rawPrefix.trimmingToLastWordBoundary()
    }
}

private extension String {
    func trimmingToLastWordBoundary() -> String {
        guard let boundary = lastIndex(where: { $0.isWhitespace || $0.isPunctuation }) else {
            return ""
        }
        return String(self[...boundary])
    }
}
