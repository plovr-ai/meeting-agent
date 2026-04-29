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
    private var translationScheduler: CaptionTranslationScheduler
    private var store: LiveCaptionStore
    private var turnAssembler: CaptionTurnAssembler
    private var interimSegmentsByID: [String: TranscriptSegment] = [:]

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
        translationScheduler = CaptionTranslationScheduler(
            provider: translationProvider,
            performanceEventLogger: performanceEventLogger
        )
        interimSegmentsByID = [:]
    }

    public func apply(_ result: TranscriptSegmentAccumulationResult) async -> LiveCaptionPipelineSnapshot {
        if result.plainTextReplacement != nil {
            reset(sourceLocale: sourceLocale, targetLocale: targetLocale)
            return snapshot(
                captionHealth: .failed("Plain text transcript replacements are not supported by live captions."),
                translationHealth: .idle
            )
        }

        let currentSegmentIDs = Set(result.document.segments.map(\.id))
        applyEvents(
            turnAssembler.removeSegments(notIn: currentSegmentIDs),
            currentSegments: result.document.segments
        )

        let changedSegmentIDs = Set(result.changedSegmentIDs)
        for segment in result.document.segments where changedSegmentIDs.contains(segment.id) {
            applyEvents(turnAssembler.apply(segment), sourceSegment: segment)
        }
        await scheduleTranslations()

        return snapshot(
            captionHealth: store.turns.isEmpty ? .idle : .live,
            translationHealth: currentTranslationHealth()
        )
    }

    public func replay(_ document: TranscriptDocument) async -> LiveCaptionPipelineSnapshot {
        reset(sourceLocale: sourceLocale, targetLocale: targetLocale)
        for segment in document.segments where segment.isFinal {
            applyEvents(turnAssembler.apply(segment), sourceSegment: segment)
        }
        for segment in document.segments where !segment.isFinal {
            applyEvents(turnAssembler.apply(segment), sourceSegment: segment)
        }
        await scheduleTranslations()
        return snapshot(
            captionHealth: store.turns.isEmpty ? .idle : .live,
            translationHealth: currentTranslationHealth()
        )
    }

    public func flush(reason: LiveCaptionFreezeReason) async -> LiveCaptionPipelineSnapshot {
        applyEvents(turnAssembler.flush(reason: reason))
        await scheduleTranslations()
        return snapshot(
            captionHealth: store.turns.isEmpty ? .idle : .live,
            translationHealth: currentTranslationHealth()
        )
    }

    public func reset(sourceLocale: String, targetLocale: String) {
        self.sourceLocale = sourceLocale
        self.targetLocale = targetLocale
        store = LiveCaptionStore(sourceLocale: sourceLocale, targetLocale: targetLocale)
        turnAssembler = CaptionTurnAssembler(sourceLocale: sourceLocale, targetLocale: targetLocale)
        translationScheduler = CaptionTranslationScheduler(
            provider: translationProvider,
            performanceEventLogger: performanceEventLogger
        )
        interimSegmentsByID = [:]
    }

    private func applyEvents(
        _ events: [CaptionTurnEvent],
        sourceSegment: TranscriptSegment? = nil,
        currentSegments: [TranscriptSegment] = []
    ) {
        for event in events {
            switch event {
            case .draftUpdated(let turn):
                if let sourceSegment,
                   let previousSegment = interimSegmentsByID[sourceSegment.id] {
                    let updated = store.replaceRepresentedSegment(
                        previousSegment,
                        with: sourceSegment,
                        applying: turn
                    )
                    hydrateCachedTranslation(from: sourceSegment, toTurnID: updated.id)
                    interimSegmentsByID[sourceSegment.id] = sourceSegment
                    continue
                }
                store.upsert(turn)
                if let sourceSegment {
                    hydrateCachedTranslation(from: sourceSegment, toTurnID: turn.id)
                }
            case .sealed(let turn):
                if let sourceSegment,
                   let previousSegment = interimSegmentsByID[sourceSegment.id] {
                    let updated = store.replaceRepresentedSegment(
                        previousSegment,
                        with: sourceSegment,
                        applying: turn
                    )
                    hydrateCachedTranslation(from: sourceSegment, toTurnID: updated.id)
                    if sourceSegment.isFinal {
                        interimSegmentsByID[sourceSegment.id] = nil
                    }
                    continue
                }
                store.upsert(turn)
                if let sourceSegment {
                    hydrateCachedTranslation(from: sourceSegment, toTurnID: turn.id)
                    if sourceSegment.isFinal {
                        interimSegmentsByID[sourceSegment.id] = nil
                    }
                }
            case .interimUpdated(let segment):
                let turn = store.append(segment)
                hydrateCachedTranslation(from: segment, toTurnID: turn.id)
                interimSegmentsByID[segment.id] = segment
            case .removed(let turnID):
                let updatedTurn = store.removeSourceSegment(turnID, remainingSegments: currentSegments)
                interimSegmentsByID[turnID] = nil
                if let updatedTurn,
                   updatedTurn.sourceSegmentIDs.count == 1,
                   let sourceSegmentID = updatedTurn.sourceSegmentIDs.first,
                   let remainingSegment = currentSegments.first(where: { $0.id == sourceSegmentID }) {
                    hydrateCachedTranslation(from: remainingSegment, toTurnID: updatedTurn.id)
                }
            }
        }
    }

    private func hydrateCachedTranslation(from segment: TranscriptSegment, toTurnID turnID: String) {
        guard let translatedText = segment.translatedText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !translatedText.isEmpty,
              let targetLocale = segment.translationTargetLocale?.trimmingCharacters(in: .whitespacesAndNewlines),
              let current = store.turns.first(where: { $0.id == turnID }),
              current.sourceSegmentIDs == [segment.id],
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

    private func scheduleTranslations() async {
        let updates = await translationScheduler.translationUpdates(for: store)
        for update in updates {
            translationScheduler.apply(update, to: &store)
        }
    }

    private func currentTranslationHealth() -> LivePipelineHealth {
        guard !store.turns.isEmpty else {
            return .idle
        }
        if let failed = store.turns.first(where: {
            if case .failed = $0.translationHealth { return true }
            return false
        }) {
            if case .failed(let message) = failed.translationHealth {
                return .degraded(message)
            }
        }
        if store.turns.contains(where: { $0.translationHealth == .pending }) {
            return .pending
        }
        if store.turns.contains(where: { $0.translationHealth == .live }) {
            return .live
        }
        return .idle
    }
}
