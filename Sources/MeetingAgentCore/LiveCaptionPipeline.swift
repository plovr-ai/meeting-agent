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

public enum LiveCaptionTranslationMode: Equatable {
    case legacyReplayBackfill
    case unitPipelineActiveRecording
}

@MainActor
public final class LiveCaptionPipeline {
    private var sourceLocale: String
    private var targetLocale: String
    private let translationProvider: TextTranslationProvider?
    private let performanceEventLogger: PerformanceEventLogger?
    private let persistTranslation: ((CaptionTranslationAttachmentTarget, String, Bool) -> Bool)?
    private let translationMode: LiveCaptionTranslationMode
    private var translationBackfillScheduler: ReplayTranslationBackfillScheduler
    private var store: LiveCaptionStore
    private var turnAssembler: CaptionTurnAssembler
    private var interimSegmentsByID: [String: TranscriptSegment] = [:]
    private var ingestedSegmentSignaturesByID: [String: String] = [:]
    private var storeGeneration = 0

    private enum CaptionVisibilityPath: String {
        case realtime
        case replay
    }

    public init(
        sourceLocale: String,
        targetLocale: String,
        translationProvider: TextTranslationProvider?,
        performanceEventLogger: PerformanceEventLogger?,
        persistTranslation: ((CaptionTranslationAttachmentTarget, String, Bool) -> Bool)? = nil,
        translationMode: LiveCaptionTranslationMode = .legacyReplayBackfill
    ) {
        self.sourceLocale = sourceLocale
        self.targetLocale = targetLocale
        self.translationProvider = translationProvider
        self.performanceEventLogger = performanceEventLogger
        self.persistTranslation = persistTranslation
        self.translationMode = translationMode
        store = LiveCaptionStore(sourceLocale: sourceLocale, targetLocale: targetLocale)
        turnAssembler = CaptionTurnAssembler(sourceLocale: sourceLocale, targetLocale: targetLocale)
        translationBackfillScheduler = ReplayTranslationBackfillScheduler(
            provider: translationProvider,
            performanceEventLogger: performanceEventLogger,
            persistTranslation: persistTranslation
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
            let receivedAt = Date()
            logSegmentIngestedIfNeeded(segment, path: segment.isFinal ? "final" : "interim")
            applyEvents(
                turnAssembler.apply(segment),
                sourceSegment: segment,
                segmentReceivedAt: receivedAt,
                visibilityPath: .realtime
            )
        }
        completeTranslationsWithoutProviderIfNeeded()
        return snapshot(
            captionHealth: store.turns.isEmpty ? .idle : .live,
            translationHealth: currentTranslationHealth()
        )
    }

    public func replay(_ document: TranscriptDocument) async -> LiveCaptionPipelineSnapshot {
        replayCaptions(document)
        await scheduleFinalTranslationsOnly()
        return snapshot(
            captionHealth: store.turns.isEmpty ? .idle : .live,
            translationHealth: currentTranslationHealth()
        )
    }

    public func replayCaptionsOnly(_ document: TranscriptDocument) -> LiveCaptionPipelineSnapshot {
        replayCaptions(document)
        return snapshot(
            captionHealth: store.turns.isEmpty ? .idle : .live,
            translationHealth: currentTranslationHealth()
        )
    }

    public func flush(reason: LiveCaptionFreezeReason) async -> LiveCaptionPipelineSnapshot {
        _ = flushCaptionsOnly(reason: reason)
        await scheduleFinalTranslationsOnly()
        return snapshot(
            captionHealth: store.turns.isEmpty ? .idle : .live,
            translationHealth: currentTranslationHealth()
        )
    }

    public func flushCaptionsOnly(reason: LiveCaptionFreezeReason) -> LiveCaptionPipelineSnapshot {
        applyEvents(turnAssembler.flush(reason: reason))
        return snapshot(
            captionHealth: store.turns.isEmpty ? .idle : .live,
            translationHealth: currentTranslationHealth()
        )
    }

    public func scheduleLegacyReplayBackfillTranslations() async -> LiveCaptionPipelineSnapshot {
        await scheduleFinalTranslationsOnly()
        return snapshot(
            captionHealth: store.turns.isEmpty ? .idle : .live,
            translationHealth: currentTranslationHealth()
        )
    }

    public func scheduleLivePendingTranslations() async -> LiveCaptionPipelineSnapshot {
        await scheduleLiveTranslations()
        return snapshot(
            captionHealth: store.turns.isEmpty ? .idle : .live,
            translationHealth: currentTranslationHealth()
        )
    }

    public func attachTranslationResults(
        _ results: [TranslationResult],
        visibleUpdatedAt: Date = Date()
    ) -> LiveCaptionPipelineSnapshot {
        for result in results {
            attachTranslationResult(result, visibleUpdatedAt: visibleUpdatedAt)
        }
        return snapshot(
            captionHealth: store.turns.isEmpty ? .idle : .live,
            translationHealth: currentTranslationHealth()
        )
    }

    public func reset(sourceLocale: String, targetLocale: String) {
        storeGeneration += 1
        self.sourceLocale = sourceLocale
        self.targetLocale = targetLocale
        resetCaptionProjection(sourceLocale: sourceLocale, targetLocale: targetLocale)
        translationBackfillScheduler = ReplayTranslationBackfillScheduler(
            provider: translationProvider,
            performanceEventLogger: performanceEventLogger,
            persistTranslation: persistTranslation
        )
    }

    private func resetCaptionProjection(sourceLocale: String, targetLocale: String) {
        store = LiveCaptionStore(sourceLocale: sourceLocale, targetLocale: targetLocale)
        turnAssembler = CaptionTurnAssembler(sourceLocale: sourceLocale, targetLocale: targetLocale)
        interimSegmentsByID = [:]
    }

    private func applyEvents(
        _ events: [CaptionTurnEvent],
        sourceSegment: TranscriptSegment? = nil,
        segmentReceivedAt: Date? = nil,
        currentSegments: [TranscriptSegment] = [],
        visibilityPath: CaptionVisibilityPath = .realtime
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
                    logCaptionTurnVisible(updated, sourceSegment: sourceSegment, receivedAt: segmentReceivedAt, visibilityPath: visibilityPath)
                    interimSegmentsByID[sourceSegment.id] = sourceSegment
                    continue
                }
                let updated = store.upsert(turn)
                if let sourceSegment {
                    hydrateCachedTranslation(from: sourceSegment, toTurnID: updated.id)
                    logCaptionTurnVisible(updated, sourceSegment: sourceSegment, receivedAt: segmentReceivedAt, visibilityPath: visibilityPath)
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
                    logCaptionTurnVisible(updated, sourceSegment: sourceSegment, receivedAt: segmentReceivedAt, visibilityPath: visibilityPath)
                    if sourceSegment.isFinal {
                        interimSegmentsByID[sourceSegment.id] = nil
                    }
                    continue
                }
                let updated = store.upsert(turn)
                if let sourceSegment {
                    hydrateCachedTranslation(from: sourceSegment, toTurnID: updated.id)
                    logCaptionTurnVisible(updated, sourceSegment: sourceSegment, receivedAt: segmentReceivedAt, visibilityPath: visibilityPath)
                    if sourceSegment.isFinal {
                        interimSegmentsByID[sourceSegment.id] = nil
                    }
                }
            case .interimUpdated(let segment):
                let turn = store.append(segment)
                hydrateCachedTranslation(from: segment, toTurnID: turn.id)
                logCaptionTurnVisible(turn, sourceSegment: segment, receivedAt: segmentReceivedAt, visibilityPath: visibilityPath)
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

    private func logCaptionTurnVisible(
        _ turn: LiveCaptionTurn,
        sourceSegment: TranscriptSegment,
        receivedAt: Date?,
        visibilityPath: CaptionVisibilityPath
    ) {
        var metadata = captionMetadata(for: turn, sourceSegment: sourceSegment)
        metadata["path"] = visibilityPath.rawValue
        if let receivedAt {
            metadata.merge(PerformanceEventLogger.durationMetadata(from: receivedAt)) { _, new in new }
        }
        performanceEventLogger?.log(
            "caption_turn_visible",
            audioTimeSeconds: sourceSegment.endTimeSeconds,
            segmentID: sourceSegment.id,
            isFinal: sourceSegment.isFinal,
            textLength: sourceSegment.text.count,
            metadata: metadata
        )
        if turn.translationFreshness == .carried,
           turn.translatedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            performanceEventLogger?.log(
                "caption_translation_carried_forward",
                audioTimeSeconds: sourceSegment.endTimeSeconds,
                segmentID: turn.id,
                isFinal: false,
                textLength: turn.translatedText?.count,
                metadata: carriedTranslationMetadata(for: turn)
            )
        }
    }

    private func carriedTranslationMetadata(for turn: LiveCaptionTurn) -> [String: String] {
        var metadata: [String: String] = [
            "turnID": turn.id,
            "sourceSegmentID": turn.sourceSegmentID,
            "sourceSegmentIDs": turn.sourceSegmentIDs.joined(separator: ","),
            "sourceLocale": turn.sourceLocale,
            "targetLocale": turn.targetLocale,
            "translationKind": "draft",
            "translationFreshness": "carried",
            "currentTextLength": String(turn.originalText.count),
            "sourceTextLength": String(turn.translationSourceText?.count ?? 0),
            "sourceLagCharacters": String(max(0, turn.originalText.count - (turn.translationSourceText?.count ?? 0)))
        ]
        if let sourceText = turn.translationSourceText {
            metadata["sourceLagWords"] = String(max(0, wordCount(in: turn.originalText) - wordCount(in: sourceText)))
        }
        if let sourceCreatedAt = turn.translationSourceCreatedAt {
            metadata["sourceLagMilliseconds"] = String(max(0, Int(turn.createdAt.timeIntervalSince(sourceCreatedAt) * 1_000)))
        }
        return metadata
    }

    private func wordCount(in text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }

    private func captionMetadata(for turn: LiveCaptionTurn, sourceSegment: TranscriptSegment) -> [String: String] {
        var metadata: [String: String] = [
            "turnID": turn.id,
            "sourceSegmentID": sourceSegment.id,
            "sourceSegmentIDs": turn.sourceSegmentIDs.joined(separator: ","),
            "sourceLocale": turn.sourceLocale,
            "targetLocale": turn.targetLocale,
            "captionState": String(describing: turn.displayState)
        ]
        let providerID = sourceSegment.sourceProvider.trimmingCharacters(in: .whitespacesAndNewlines)
        if !providerID.isEmpty {
            metadata["providerID"] = providerID
        }
        if let boundaryStrength = turn.boundaryStrength {
            metadata["boundaryStrength"] = String(describing: boundaryStrength)
        }
        if let boundaryReason = turn.boundaryReason {
            metadata["boundaryReason"] = boundaryReason.rawValue
        }
        return metadata
    }

    private func replayCaptions(_ document: TranscriptDocument) {
        let previousTranslatedTurns = store.turns.filter { $0.translatedText?.isEmpty == false }
        resetCaptionProjection(sourceLocale: sourceLocale, targetLocale: targetLocale)
        for segment in document.segments where segment.isFinal {
            logSegmentIngestedIfNeeded(segment, path: "final")
            applyEvents(turnAssembler.apply(segment), sourceSegment: segment, visibilityPath: .replay)
        }
        for segment in document.segments where !segment.isFinal {
            logSegmentIngestedIfNeeded(segment, path: "interim")
            applyEvents(turnAssembler.apply(segment), sourceSegment: segment, visibilityPath: .replay)
        }
        for previous in previousTranslatedTurns {
            guard let translatedText = previous.translatedText else { continue }
            for turn in store.turns where turn.translatedText == nil {
                let previousIDs = Set(previous.sourceSegmentIDs)
                guard previousIDs.isSubset(of: Set(turn.sourceSegmentIDs)),
                      previous.targetLocale == turn.targetLocale
                else { continue }
                store.attachTranslation(translatedText, toTurnID: turn.id)
                if previous.translationState == .final,
                   turn.displayState == .sealed,
                   turn.boundaryStrength == .hard {
                    store.markTranslationFinal(forTurnID: turn.id)
                } else if previous.sourceSegmentIDs != turn.sourceSegmentIDs
                    || previous.originalText != turn.originalText
                    || (turn.displayState == .sealed && turn.boundaryStrength == .hard) {
                    store.markTranslationPending(forTurnID: turn.id)
                }
            }
        }
        translationBackfillScheduler.cancelDraftsSuperseded(by: store.turns)
    }

    private func logSegmentIngestedIfNeeded(_ segment: TranscriptSegment, path: String) {
        let signature = [
            segment.text,
            segment.isFinal ? "final" : "interim",
            segment.speechFinal ? "speechFinal" : "open",
            segment.speakerID ?? "",
            segment.speakerLabel ?? ""
        ].joined(separator: "\u{1F}")
        guard ingestedSegmentSignaturesByID[segment.id] != signature else { return }
        ingestedSegmentSignaturesByID[segment.id] = signature
        performanceEventLogger?.logSegment(
            "caption_segment_ingested",
            segment: segment,
            metadata: ["path": path]
        )
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

    private func completeTranslationsWithoutProviderIfNeeded() {
        guard translationProvider == nil else { return }
        guard store.turns.allSatisfy({
            TranslationOptions(sourceLocale: $0.sourceLocale, targetLocale: $0.targetLocale).isSameLanguage
        }) else {
            return
        }
        for turn in store.turns where turn.translationHealth == .pending {
            store.markTranslationCompleteWithoutText(forTurnID: turn.id)
        }
    }

    private func attachTranslationResult(
        _ result: TranslationResult,
        visibleUpdatedAt: Date
    ) {
        let translatedText = result.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translatedText.isEmpty,
              result.displayState == .liveFresh || result.displayState == .stableFinal,
              let turnID = turnID(for: result)
        else {
            logTranslationProjectionMismatchIfNeeded(result)
            return
        }
        store.attachTranslation(
            translatedText,
            toTurnID: turnID,
            freshness: result.displayState == .stableFinal ? .final : .fresh,
            sourceText: result.sourceText,
            sourceCreatedAt: result.sourceCreatedAt,
            visibleUpdatedAt: visibleUpdatedAt
        )
        if result.displayState == .stableFinal {
            store.markTranslationFinal(forTurnID: turnID)
        }
    }

    private func turnID(for result: TranslationResult) -> String? {
        let sourceSegmentIDs = Set(result.sourceSegmentIDs)
        if !sourceSegmentIDs.isEmpty {
            if let exactTurn = store.turns.last(where: { Set($0.sourceSegmentIDs) == sourceSegmentIDs }) {
                return exactTurn.id
            }
            if result.displayState == .liveFresh,
               sourceSegmentIDs.count == 1,
               let turn = store.turns.last(where: { !$0.sourceSegmentIDs.filter(sourceSegmentIDs.contains).isEmpty }) {
                return turn.id
            }
            return nil
        }
        if let turn = store.turns.last(where: { $0.sourceSegmentID == result.sourceID || $0.id == result.sourceID }) {
            return turn.id
        }
        return nil
    }

    private func logTranslationProjectionMismatchIfNeeded(_ result: TranslationResult) {
        guard result.displayState == .stableFinal,
              !result.sourceSegmentIDs.isEmpty
        else {
            return
        }
        performanceEventLogger?.log(
            "translation_unit_projection_mismatch",
            segmentID: result.sourceID,
            isFinal: true,
            textLength: result.translatedText.count,
            metadata: [
                "translationKind": "final",
                "translationState": result.displayState.rawValue,
                "resultID": result.id,
                "sourceSegmentIDs": result.sourceSegmentIDs.joined(separator: ","),
                "turnSourceSegmentIDs": store.turns
                    .map { $0.sourceSegmentIDs.joined(separator: ",") }
                    .joined(separator: "|")
            ]
        )
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

    private func scheduleLiveTranslations() async {
        guard translationMode == .legacyReplayBackfill else { return }
        let generation = storeGeneration
        let updates = await translationBackfillScheduler.liveTranslationUpdates(for: store)
        guard generation == storeGeneration else {
            for update in updates {
                translationBackfillScheduler.discardStale(update, against: store)
            }
            return
        }
        for update in updates {
            let outcome = translationBackfillScheduler.apply(update, to: &store)
            if outcome.publishedVisibleText {
                logCaptionSnapshotPublished(for: update, publishedAt: Date())
            }
        }
    }

    private func scheduleFinalTranslationsOnly() async {
        guard translationMode == .legacyReplayBackfill else { return }
        let generation = storeGeneration
        let updates = await translationBackfillScheduler.finalTranslationUpdates(for: store)
        guard generation == storeGeneration else {
            for update in updates {
                translationBackfillScheduler.discardStale(update, against: store)
            }
            return
        }
        for update in updates {
            let outcome = translationBackfillScheduler.apply(update, to: &store)
            if outcome.publishedVisibleText {
                logCaptionSnapshotPublished(for: update, publishedAt: Date())
            }
        }
    }

    private func logCaptionSnapshotPublished(for update: CaptionTranslationUpdate, publishedAt: Date) {
        guard let request = update.request,
              update.attachesVisibleText
        else {
            return
        }
        var metadata = CaptionTranslationExecutionMetadata.metadata(for: request)
        if let resultReceivedAt = update.resultReceivedAt {
            metadata.merge(PerformanceEventLogger.durationMetadata(from: resultReceivedAt, to: publishedAt)) { _, new in new }
        }
        performanceEventLogger?.log(
            "caption_snapshot_published",
            segmentID: update.turnID,
            isFinal: !request.isDraft,
            textLength: update.visibleTextLength,
            metadata: metadata
        )
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
