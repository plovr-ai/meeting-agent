import Foundation

public struct LiveCaptionPipelineSnapshot: Equatable {
    public var turns: [LiveCaptionTurn]
    public var captionHealth: LivePipelineHealth
    public var translationHealth: LivePipelineHealth

    public init(
        turns: [LiveCaptionTurn],
        captionHealth: LivePipelineHealth,
        translationHealth: LivePipelineHealth
    ) {
        self.turns = turns
        self.captionHealth = captionHealth
        self.translationHealth = translationHealth
    }
}

@MainActor
public final class LiveCaptionPipeline {
    private var sourceLocale: String
    private var targetLocale: String
    private let translationProvider: TextTranslationProvider?
    private let performanceEventLogger: PerformanceEventLogger?
    private var store: LiveCaptionStore
    private var turnAssembler: CaptionTurnAssembler

    public init(
        sourceLocale: String,
        targetLocale: String,
        translationProvider: TextTranslationProvider?,
        performanceEventLogger: PerformanceEventLogger?
    ) {
        self.sourceLocale = sourceLocale
        self.targetLocale = targetLocale
        self.translationProvider = translationProvider
        self.performanceEventLogger = performanceEventLogger
        store = LiveCaptionStore(sourceLocale: sourceLocale, targetLocale: targetLocale)
        turnAssembler = CaptionTurnAssembler(sourceLocale: sourceLocale, targetLocale: targetLocale)
    }

    public func apply(_ result: TranscriptSegmentAccumulationResult) async -> LiveCaptionPipelineSnapshot {
        if result.plainTextReplacement != nil {
            reset(sourceLocale: sourceLocale, targetLocale: targetLocale)
        }
        return await replay(result.document)
    }

    public func replay(_ document: TranscriptDocument) async -> LiveCaptionPipelineSnapshot {
        reset(sourceLocale: sourceLocale, targetLocale: targetLocale)
        for segment in document.segments where segment.isFinal {
            applyEvents(turnAssembler.apply(segment), sourceSegment: segment)
        }
        for segment in document.segments where !segment.isFinal {
            applyEvents(turnAssembler.apply(segment), sourceSegment: segment)
        }
        return snapshot(
            captionHealth: store.turns.isEmpty ? .idle : .live,
            translationHealth: .idle
        )
    }

    public func flush(reason: LiveCaptionFreezeReason) async -> LiveCaptionPipelineSnapshot {
        applyEvents(turnAssembler.flush(reason: reason))
        return snapshot(
            captionHealth: store.turns.isEmpty ? .idle : .live,
            translationHealth: .idle
        )
    }

    public func reset(sourceLocale: String, targetLocale: String) {
        self.sourceLocale = sourceLocale
        self.targetLocale = targetLocale
        store = LiveCaptionStore(sourceLocale: sourceLocale, targetLocale: targetLocale)
        turnAssembler = CaptionTurnAssembler(sourceLocale: sourceLocale, targetLocale: targetLocale)
    }

    private func applyEvents(
        _ events: [CaptionTurnEvent],
        sourceSegment: TranscriptSegment? = nil
    ) {
        for event in events {
            switch event {
            case .draftUpdated(let turn), .sealed(let turn):
                store.upsert(turn)
                if let sourceSegment {
                    hydrateCachedTranslation(from: sourceSegment, toTurnID: turn.id)
                }
            case .removed(let turnID):
                store.remove(turnID: turnID)
            }
        }
    }

    private func hydrateCachedTranslation(from segment: TranscriptSegment, toTurnID turnID: String) {
        guard let translatedText = segment.translatedText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !translatedText.isEmpty,
              let targetLocale = segment.translationTargetLocale?.trimmingCharacters(in: .whitespacesAndNewlines),
              let current = store.turns.first(where: { $0.id == turnID }),
              targetLocale == current.targetLocale
        else {
            return
        }
        if current.displayState == .sealed,
           current.boundaryStrength == .hard,
           segment.translationIsFinal != true {
            return
        }
        store.attachTranslation(translatedText, toTurnID: turnID)
        if segment.translationIsFinal == true {
            store.markTranslationFinal(forTurnID: turnID)
        }
    }

    private func snapshot(
        captionHealth: LivePipelineHealth,
        translationHealth: LivePipelineHealth
    ) -> LiveCaptionPipelineSnapshot {
        return LiveCaptionPipelineSnapshot(
            turns: store.turns,
            captionHealth: captionHealth,
            translationHealth: translationHealth
        )
    }
}
