import Foundation

public struct CaptionTranslationSchedulerConfiguration: Equatable {
    public var draftDebounceNanoseconds: UInt64
    public var maxConcurrentTranslationRequests: Int
    public var followUpDraftMinimumIntervalNanoseconds: UInt64
    public var followUpDraftMaximumWaitNanoseconds: UInt64
    public var minimumDraftWordDelta: Int
    public var minimumDraftCharacterDelta: Int
    public var semanticBoundaryCharacters: Set<Character>
    public var minimumApproximateDraftCharacters: Int
    public var minimumApproximateDraftWords: Int
    public var maximumApproximateDraftAgeNanoseconds: UInt64
    public var approximateDraftSimilarityThreshold: Double
    public var minimumInitialDraftWordCount: Int
    public var minimumInitialDraftCharacterCount: Int
    public var minimumInitialDraftCJKCharacterCount: Int
    public var minimumBoundaryDraftCharacterCount: Int
    public var fillerDraftPhrases: Set<String>

    public init(
        draftDebounceNanoseconds: UInt64 = 750_000_000,
        maxConcurrentTranslationRequests: Int = 2,
        followUpDraftMinimumIntervalNanoseconds: UInt64 = 1_500_000_000,
        followUpDraftMaximumWaitNanoseconds: UInt64 = 3_000_000_000,
        minimumDraftWordDelta: Int = 8,
        minimumDraftCharacterDelta: Int = 48,
        semanticBoundaryCharacters: Set<Character> = Set(".?!,;:。？！、，；：\n"),
        minimumApproximateDraftCharacters: Int = 24,
        minimumApproximateDraftWords: Int = 5,
        maximumApproximateDraftAgeNanoseconds: UInt64 = 6_000_000_000,
        approximateDraftSimilarityThreshold: Double = 0.75,
        minimumInitialDraftWordCount: Int = 7,
        minimumInitialDraftCharacterCount: Int = 45,
        minimumInitialDraftCJKCharacterCount: Int = 14,
        minimumBoundaryDraftCharacterCount: Int = 8,
        fillerDraftPhrases: Set<String> = [
            "um", "uh", "er", "ah", "hmm",
            "yeah", "yep", "yes", "ok", "okay",
            "right", "sure", "so", "and", "but"
        ]
    ) {
        self.draftDebounceNanoseconds = draftDebounceNanoseconds
        self.maxConcurrentTranslationRequests = max(1, maxConcurrentTranslationRequests)
        self.followUpDraftMinimumIntervalNanoseconds = followUpDraftMinimumIntervalNanoseconds
        self.followUpDraftMaximumWaitNanoseconds = followUpDraftMaximumWaitNanoseconds
        self.minimumDraftWordDelta = max(1, minimumDraftWordDelta)
        self.minimumDraftCharacterDelta = max(1, minimumDraftCharacterDelta)
        self.semanticBoundaryCharacters = semanticBoundaryCharacters
        self.minimumApproximateDraftCharacters = max(1, minimumApproximateDraftCharacters)
        self.minimumApproximateDraftWords = max(1, minimumApproximateDraftWords)
        self.maximumApproximateDraftAgeNanoseconds = maximumApproximateDraftAgeNanoseconds
        self.approximateDraftSimilarityThreshold = approximateDraftSimilarityThreshold
        self.minimumInitialDraftWordCount = max(1, minimumInitialDraftWordCount)
        self.minimumInitialDraftCharacterCount = max(1, minimumInitialDraftCharacterCount)
        self.minimumInitialDraftCJKCharacterCount = max(1, minimumInitialDraftCJKCharacterCount)
        self.minimumBoundaryDraftCharacterCount = max(1, minimumBoundaryDraftCharacterCount)
        self.fillerDraftPhrases = fillerDraftPhrases
    }
}

@MainActor
public final class CaptionTranslationScheduler {
    private let provider: TextTranslationProvider?
    private let performanceEventLogger: PerformanceEventLogger?
    private let persistTranslation: ((CaptionTranslationAttachmentTarget, String, Bool) -> Bool)?
    private let configuration: CaptionTranslationSchedulerConfiguration
    private let now: () -> Date
    private var requestedFinalTranslationKeys: Set<String> = []
    private var activeRequestsByKey: [String: ActiveCaptionTranslationRequest] = [:]
    private var pendingDraftTokensByTurnID: [String: UUID] = [:]
    private var requestOrdinalsByTurnID: [String: Int] = [:]
    private var planner: CaptionTranslationPlanner

    public init(
        provider: TextTranslationProvider?,
        performanceEventLogger: PerformanceEventLogger?,
        persistTranslation: ((CaptionTranslationAttachmentTarget, String, Bool) -> Bool)? = nil,
        configuration: CaptionTranslationSchedulerConfiguration = CaptionTranslationSchedulerConfiguration(),
        now: @escaping () -> Date = Date.init
    ) {
        self.provider = provider
        self.performanceEventLogger = performanceEventLogger
        self.persistTranslation = persistTranslation
        self.configuration = configuration
        self.now = now
        planner = CaptionTranslationPlanner(configuration: configuration, now: now)
    }

    public func scheduleTranslations(in store: inout LiveCaptionStore) async {
        for update in await translationUpdates(for: store) {
            apply(update, to: &store)
        }
    }

    func translationUpdates(for store: LiveCaptionStore) async -> [CaptionTranslationUpdate] {
        await finalTranslationUpdates(for: store)
    }

    func finalTranslationUpdates(for store: LiveCaptionStore) async -> [CaptionTranslationUpdate] {
        await translationUpdates(for: store, includingDrafts: false)
    }

    func liveTranslationUpdates(for store: LiveCaptionStore) async -> [CaptionTranslationUpdate] {
        await translationUpdates(for: store, includingDrafts: true)
    }

    private func translationUpdates(for store: LiveCaptionStore, includingDrafts: Bool) async -> [CaptionTranslationUpdate] {
        var executions: [CaptionTranslationExecution] = []
        let turns = store.turns
            .filter { $0.translationHealth == .pending }
            .filter { turn in
                guard includingDrafts,
                      !(turn.displayState == .sealed && turn.boundaryStrength == .hard)
                else {
                    return true
                }
                return !store.turns.contains { final in
                    final.displayState == .sealed
                        && final.boundaryStrength == .hard
                        && (final.id == turn.id || (final.speaker == turn.speaker && turn.createdAt <= final.createdAt))
                }
            }
            .sorted { lhs, rhs in
                let lhsFinal = lhs.displayState == .sealed && lhs.boundaryStrength == .hard
                let rhsFinal = rhs.displayState == .sealed && rhs.boundaryStrength == .hard
                if lhsFinal != rhsFinal { return lhsFinal }
                if includingDrafts && !lhsFinal && !rhsFinal {
                    if lhs.createdAt == rhs.createdAt {
                        return lhs.id > rhs.id
                    }
                    return lhs.createdAt > rhs.createdAt
                }
                return lhs.createdAt < rhs.createdAt
            }
        for turn in turns {
            if let execution = await translationExecution(for: turn, in: store, includingDrafts: includingDrafts) {
                executions.append(execution)
            }
        }
        return await execute(executions)
    }

    @discardableResult
    func apply(_ update: CaptionTranslationUpdate, to store: inout LiveCaptionStore) -> CaptionTranslationApplyOutcome {
        switch update.result {
        case .completeWithoutText:
            guard store.turns.contains(where: { $0.id == update.turnID }) else {
                return .none
            }
            store.markTranslationCompleteWithoutText(forTurnID: update.turnID)
            return .none
        case .draftText(let text):
            guard let current = store.turns.first(where: { $0.id == update.turnID }) else {
                return .none
            }
            if isCurrentDraftUpdate(update, current: current) {
                store.attachTranslation(
                    text,
                    toTurnID: update.turnID,
                    freshness: .fresh,
                    sourceText: current.originalText,
                    sourceCreatedAt: current.createdAt,
                    visibleUpdatedAt: now()
                )
                markDraftTranslationVisible(forTurnID: update.turnID)
                if let request = update.request {
                    logExactAttached(request: request, current: current, textLength: text.count)
                    logAttached(request: request, attachedTurnID: current.id, textLength: text.count)
                }
                let target = CaptionTranslationAttachmentTarget(turn: current, sourceText: current.originalText)
                if target.sourceSegmentIDs.count == 1 {
                    _ = persistTranslation?(target, text, false)
                }
                return .attached(turnID: current.id)
            }
            guard let request = update.request else {
                return .none
            }
            if let decision = approximateDraftAttachDecision(request: request, current: current) {
                store.attachTranslation(
                    text,
                    toTurnID: update.turnID,
                    freshness: .approximate,
                    sourceText: request.sourceText,
                    sourceCreatedAt: request.turn.createdAt,
                    visibleUpdatedAt: now()
                )
                markDraftTranslationVisible(forTurnID: update.turnID)
                logApproximateAttached(request: request, current: current, textLength: text.count, decision: decision)
                logAttached(request: request, attachedTurnID: current.id, textLength: text.count)
                let target = CaptionTranslationAttachmentTarget(turn: current, sourceText: request.sourceText)
                if target.sourceSegmentIDs.count == 1 {
                    _ = persistTranslation?(target, text, false)
                }
                return .attached(turnID: current.id)
            } else {
                logHiddenStale(update: update, request: request, current: current)
                logStale(update: update, request: request, current: current)
                return .none
            }
        case .finalText(let text):
            guard let request = update.request, !request.isDraft else {
                return .none
            }
            guard let targetTurn = currentTurnForFinalRequest(request, in: store) else {
                return persistFinalTranslation(text, request: request)
            }
            let wasRebound = targetTurn.id != request.turn.id
            store.attachTranslation(text, toTurnID: targetTurn.id)
            store.markTranslationFinal(forTurnID: targetTurn.id)
            if wasRebound {
                logRebound(request: request, reboundTurnID: targetTurn.id, textLength: text.count)
            }
            logAttached(request: request, attachedTurnID: targetTurn.id, textLength: text.count)
            let target = request.attachmentTarget ?? CaptionTranslationAttachmentTarget(turn: targetTurn, sourceText: targetTurn.originalText)
            _ = persistTranslation?(target, text, true)
            return wasRebound
                ? .rebound(originalTurnID: request.turn.id, reboundTurnID: targetTurn.id)
                : .attached(turnID: targetTurn.id)
        case .failed(let message):
            guard store.turns.contains(where: { $0.id == update.turnID }) else {
                return .none
            }
            store.markTranslationFailed(forTurnID: update.turnID, message: message)
            return .none
        }
    }

    func discardStale(_ update: CaptionTranslationUpdate, against store: LiveCaptionStore) {
        guard let request = update.request,
              let current = store.turns.first(where: { $0.id == update.turnID })
        else {
            return
        }
        let currentKey = translationKey(
            for: current,
            isFinalTranslation: !request.isDraft,
            sourceText: request.sourceText
        )
        guard current.translationHealth != .pending || currentKey != update.key else {
            return
        }
        logStale(update: update, request: request, current: current)
    }

    func cancelDraftsSuperseded(by turns: [LiveCaptionTurn]) {
        let hardFinals = turns.filter { $0.displayState == .sealed && $0.boundaryStrength == .hard }
        guard !hardFinals.isEmpty else { return }
        let activeDrafts = activeRequestsByKey.values.filter(\.isDraft)
        for request in activeDrafts {
            guard hardFinals.contains(where: { final in
                final.id == request.turn.id
                    || (final.speaker == request.turn.speaker && request.turn.createdAt <= final.createdAt)
            }) else {
                continue
            }
            logCancelled(request, reason: "superseded_by_final")
            activeRequestsByKey.removeValue(forKey: request.key)
            markDraftRequestFinished(forTurnID: request.turn.id)
        }
    }

    private func translationExecution(
        for turn: LiveCaptionTurn,
        in store: LiveCaptionStore,
        includingDrafts: Bool
    ) async -> CaptionTranslationExecution? {
        let isFinalTranslation = turn.displayState == .sealed && turn.boundaryStrength == .hard
        let sourceText = translationSourceText(for: turn, in: store, final: isFinalTranslation)
        let key = translationKey(for: turn, isFinalTranslation: isFinalTranslation, sourceText: sourceText)
        let options = TranslationOptions(sourceLocale: turn.sourceLocale, targetLocale: turn.targetLocale)
        if options.isSameLanguage {
            logSkipped(turn: turn, key: key, isFinalTranslation: isFinalTranslation, reason: "same_language")
            return CaptionTranslationExecution(
                request: nil,
                segment: nil,
                options: options,
                provider: nil,
                update: CaptionTranslationUpdate(turnID: turn.id, key: key, result: .completeWithoutText, request: nil)
            )
        }

        guard isFinalTranslation || includingDrafts else {
            return nil
        }
        guard let provider else {
            return nil
        }
        if isFinalTranslation {
            cancelDraftsSuperseded(by: [turn])
            pendingDraftTokensByTurnID[turn.id] = nil
        }
        let requestID = "caption-translation-\(UUID().uuidString)"
        let requestOrdinal = nextRequestOrdinal(forTurnID: turn.id)
        let attachmentTarget = CaptionTranslationAttachmentTarget(turn: turn, sourceText: sourceText)
        let request = ActiveCaptionTranslationRequest(
            id: requestID,
            turn: turn,
            key: key,
            isDraft: !isFinalTranslation,
            revision: turn.translationRevision,
            requestOrdinalForTurn: requestOrdinal,
            sourceText: sourceText,
            attachmentTarget: isFinalTranslation ? attachmentTarget : nil,
            providerID: provider.descriptor.id,
            configuration: configuration
        )
        if request.isDraft,
           configuration.draftDebounceNanoseconds > 0 {
            let token = UUID()
            let replaced = pendingDraftTokensByTurnID.updateValue(token, forKey: turn.id) != nil
            performanceEventLogger?.log(
                replaced ? "caption_translation_debounce_replaced" : "caption_translation_debounce_scheduled",
                segmentID: turn.id,
                isFinal: false,
                textLength: turn.originalText.count,
                metadata: translationMetadata(for: request)
            )
            try? await Task.sleep(nanoseconds: configuration.draftDebounceNanoseconds)
            guard pendingDraftTokensByTurnID[turn.id] == token else {
                return nil
            }
            pendingDraftTokensByTurnID[turn.id] = nil
            performanceEventLogger?.log(
                "caption_translation_debounce_fired",
                segmentID: turn.id,
                isFinal: false,
                textLength: turn.originalText.count,
                metadata: translationMetadata(for: request)
            )
        }
        var draftDecisionMetadata: [String: String] = [:]
        if request.isDraft {
            let decision = draftTriggerDecision(for: turn, sourceText: sourceText)
            switch decision {
            case .trigger(let reason, let metadata):
                draftDecisionMetadata = metadata
                performanceEventLogger?.log(
                    "caption_translation_draft_triggered",
                    segmentID: turn.id,
                    isFinal: false,
                    textLength: turn.originalText.count,
                    metadata: metadata.merging(["reason": reason]) { current, _ in current }
                )
            case .skip(let reason, let metadata):
                performanceEventLogger?.log(
                    "caption_translation_draft_skipped",
                    segmentID: turn.id,
                    isFinal: false,
                    textLength: turn.originalText.count,
                    metadata: metadata.merging(["reason": reason]) { current, _ in current }
                )
                return nil
            }
        }
        guard !requestedFinalTranslationKeys.contains(key) else {
            logSkipped(turn: turn, key: key, isFinalTranslation: isFinalTranslation, reason: "duplicate_key")
            return nil
        }
        requestedFinalTranslationKeys.insert(key)
        activeRequestsByKey[key] = request
        if request.isDraft {
            markDraftRequestStarted(forTurnID: turn.id)
        }
        let metadata = translationMetadata(for: request, extra: request.isDraft ? draftDecisionMetadata : [:])
        performanceEventLogger?.log(
            "caption_translation_scheduled",
            segmentID: turn.id,
            isFinal: isFinalTranslation,
            textLength: turn.originalText.count,
            metadata: metadata
        )
        logCount("caption_translation_scheduled_count", request: request)

        let segment = TranscriptSegment(
            id: turn.sourceSegmentID,
            speaker: turn.speaker,
            text: sourceText,
            language: turn.sourceLocale,
            isFinal: isFinalTranslation,
            createdAt: turn.createdAt
        )
        return CaptionTranslationExecution(request: request, segment: segment, options: options, provider: provider, update: nil)
    }

    private func execute(_ executions: [CaptionTranslationExecution]) async -> [CaptionTranslationUpdate] {
        var immediateUpdates: [CaptionTranslationUpdate] = []
        var requestExecutions: [CaptionTranslationExecution] = []
        for execution in executions {
            if let update = execution.update {
                immediateUpdates.append(update)
            } else {
                requestExecutions.append(execution)
            }
        }
        guard !requestExecutions.isEmpty else {
            return immediateUpdates
        }
        let limit = min(configuration.maxConcurrentTranslationRequests, requestExecutions.count)
        let logger = performanceEventLogger
        var updates: [CaptionTranslationUpdate] = []
        await withTaskGroup(of: CaptionTranslationUpdate?.self) { group in
            var nextIndex = 0
            var running = 0

            func enqueueNext() {
                guard nextIndex < requestExecutions.count else { return }
                let execution = requestExecutions[nextIndex]
                nextIndex += 1
                running += 1
                let inFlightCount = running
                let queueDepth = requestExecutions.count - nextIndex
                logger?.log(
                    "caption_translation_enqueued",
                    segmentID: execution.request?.turn.id,
                    isFinal: execution.request.map { !$0.isDraft },
                    textLength: execution.request?.turn.originalText.count,
                    metadata: execution.request.map {
                        var metadata = CaptionTranslationExecutionMetadata.metadata(for: $0)
                        metadata["queueDepth"] = String(queueDepth)
                        metadata["inFlightCount"] = String(inFlightCount)
                        return metadata
                    } ?? [:]
                )
                group.addTask {
                    await Self.performTranslation(execution, inFlightCount: inFlightCount, queueDepth: queueDepth, logger: logger)
                }
            }

            while running < limit, nextIndex < requestExecutions.count {
                enqueueNext()
            }
            while let update = await group.next() {
                running -= 1
                if let update {
                    updates.append(update)
                }
                while running < limit, nextIndex < requestExecutions.count {
                    enqueueNext()
                }
            }
        }
        for update in updates {
            activeRequestsByKey.removeValue(forKey: update.key)
            if let request = update.request, request.isDraft {
                markDraftRequestFinished(forTurnID: request.turn.id)
            }
        }
        return immediateUpdates + updates
    }

    private static func performTranslation(
        _ execution: CaptionTranslationExecution,
        inFlightCount: Int,
        queueDepth: Int,
        logger: PerformanceEventLogger?
    ) async -> CaptionTranslationUpdate? {
        guard let request = execution.request,
              let segment = execution.segment,
              let provider = execution.provider
        else {
            return execution.update
        }
        let metadata = execution.metadata(queueDepth: queueDepth, inFlightCount: inFlightCount)
        do {
            let startedAt = Date()
            logger?.log(
                "caption_translation_started",
                segmentID: request.turn.id,
                isFinal: !request.isDraft,
                textLength: request.turn.originalText.count,
                metadata: metadata
            )
            let translated = try await performProviderTranslation(
                provider: provider,
                segment: segment,
                options: execution.options
            )
            var finishedMetadata = metadata
            finishedMetadata.merge(PerformanceEventLogger.durationMetadata(from: startedAt)) { _, new in new }
            let translatedText = translated.segments.first { $0.id == request.turn.sourceSegmentID }?.targetText ?? ""
            logger?.log(
                "caption_translation_finished",
                segmentID: request.turn.id,
                isFinal: !request.isDraft,
                textLength: translatedText.count,
                metadata: finishedMetadata
            )
            var completedRequest = request
            completedRequest.queueDepth = queueDepth
            completedRequest.inFlightCount = inFlightCount
            return CaptionTranslationUpdate(
                turnID: request.turn.id,
                key: request.key,
                result: request.isDraft ? .draftText(translatedText) : .finalText(translatedText),
                request: completedRequest,
                resultReceivedAt: Date()
            )
        } catch {
            let nsError = error as NSError
            var failureMetadata = metadata
            failureMetadata["failureReason"] = "\(nsError.domain) error \(nsError.code)"
            failureMetadata["retryCount"] = "0"
            failureMetadata["count"] = "1"
            logger?.log(
                "caption_translation_provider_error",
                segmentID: request.turn.id,
                isFinal: !request.isDraft,
                textLength: request.turn.originalText.count,
                metadata: failureMetadata
            )
            logger?.log(
                "caption_translation_failed_count",
                segmentID: request.turn.id,
                isFinal: !request.isDraft,
                textLength: request.turn.originalText.count,
                metadata: failureMetadata
            )
            return CaptionTranslationUpdate(
                turnID: request.turn.id,
                key: request.key,
                result: .failed("\(nsError.domain) error \(nsError.code)"),
                request: request,
                resultReceivedAt: Date()
            )
        }
    }

    private static func performProviderTranslation(
        provider: TextTranslationProvider,
        segment: TranscriptSegment,
        options: TranslationOptions
    ) async throws -> TranslatedTranscript {
        let task = Task.detached {
            try await provider.translate(
                transcript: TranscriptDocument(segments: [segment]),
                options: options
            )
        }
        return try await task.value
    }

    private func translationKey(
        for turn: LiveCaptionTurn,
        isFinalTranslation: Bool,
        sourceText: String? = nil
    ) -> String {
        if isFinalTranslation {
            return finalTranslationKey(for: turn, sourceText: sourceText ?? turn.originalText)
        }
        return draftTranslationKey(for: turn)
    }

    private func finalTranslationKey(for turn: LiveCaptionTurn, sourceText: String) -> String {
        [
            "final",
            turn.sourceSegmentIDs.joined(separator: ","),
            normalizedTranslationSourceText(sourceText),
            turn.sourceLocale,
            turn.targetLocale
        ].joined(separator: "\u{1F}")
    }

    private func draftTranslationKey(for turn: LiveCaptionTurn) -> String {
        [
            turn.id,
            turn.sourceSegmentIDs.joined(separator: ","),
            turn.originalText,
            turn.sourceLocale,
            turn.targetLocale,
            "draft",
            turn.displayState.rawValue,
            turn.boundaryStrength.map(String.init(describing:)) ?? "",
            turn.boundaryReason?.rawValue ?? "",
            String(turn.translationRevision)
        ].joined(separator: "\u{1F}")
    }

    private func normalizedTranslationSourceText(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func translationSourceText(for turn: LiveCaptionTurn, in store: LiveCaptionStore, final: Bool) -> String {
        guard final else { return turn.originalText }
        let groups = LiveCaptionSpeakerGroup.groups(from: store.turns)
        guard let group = groups.first(where: { $0.turns.contains(where: { $0.id == turn.id }) }) else {
            return turn.originalText
        }
        var texts: [String] = []
        for candidate in group.turns {
            texts.append(candidate.originalText)
            if candidate.id == turn.id {
                break
            }
        }
        return texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func logCancelled(_ request: ActiveCaptionTranslationRequest, reason: String) {
        performanceEventLogger?.log(
            "caption_translation_cancelled",
            segmentID: request.turn.id,
            isFinal: !request.isDraft,
            textLength: request.turn.originalText.count,
            metadata: translationMetadata(for: request, extra: ["reason": reason])
        )
        logCount("caption_translation_cancelled_count", request: request, extra: ["reason": reason])
    }

    private func logStale(
        update: CaptionTranslationUpdate,
        request: ActiveCaptionTranslationRequest,
        current: LiveCaptionTurn
    ) {
        let reason: String
        if request.isDraft {
            reason = "draft_no_longer_current"
        } else if current.displayState != .sealed || current.boundaryStrength != .hard {
            reason = "final_no_longer_current"
        } else {
            reason = "translation_key_no_longer_current"
        }
        performanceEventLogger?.log(
            "caption_translation_stale",
            segmentID: update.turnID,
            isFinal: !request.isDraft,
            textLength: request.turn.originalText.count,
            metadata: translationMetadata(for: request, extra: ["reason": reason])
        )
        logCount("caption_translation_stale_count", request: request, extra: ["reason": reason])
    }

    private func logRebound(request: ActiveCaptionTranslationRequest, reboundTurnID: String, textLength: Int) {
        performanceEventLogger?.log(
            "caption_translation_rebound",
            segmentID: reboundTurnID,
            isFinal: true,
            textLength: textLength,
            metadata: translationMetadata(for: request, extra: ["reboundTurnID": reboundTurnID])
        )
    }

    private func logAttached(
        request: ActiveCaptionTranslationRequest,
        attachedTurnID: String? = nil,
        textLength: Int
    ) {
        performanceEventLogger?.log(
            "caption_translation_attached",
            segmentID: attachedTurnID ?? request.turn.id,
            isFinal: !request.isDraft,
            textLength: textLength,
            metadata: translationMetadata(for: request)
        )
        logCount("caption_translation_completed_count", request: request)
    }

    private func logExactAttached(
        request: ActiveCaptionTranslationRequest,
        current: LiveCaptionTurn,
        textLength: Int
    ) {
        performanceEventLogger?.log(
            "caption_translation_exact_attached",
            segmentID: current.id,
            isFinal: false,
            textLength: textLength,
            metadata: translationMetadata(
                for: request,
                extra: draftVisibilityMetadata(
                    request: request,
                    current: current,
                    decision: "exact_attach",
                    freshness: "fresh"
                )
            )
        )
    }

    private func logApproximateAttached(
        request: ActiveCaptionTranslationRequest,
        current: LiveCaptionTurn,
        textLength: Int,
        decision: ApproximateDraftAttachDecision
    ) {
        performanceEventLogger?.log(
            "caption_translation_approximate_attached",
            segmentID: current.id,
            isFinal: false,
            textLength: textLength,
            metadata: translationMetadata(
                for: request,
                extra: draftVisibilityMetadata(
                    request: request,
                    current: current,
                    decision: "approximate_attach",
                    freshness: "approximate",
                    similarity: decision.similarity
                )
            )
        )
    }

    private func logHiddenStale(
        update: CaptionTranslationUpdate,
        request: ActiveCaptionTranslationRequest,
        current: LiveCaptionTurn
    ) {
        performanceEventLogger?.log(
            "caption_translation_hidden_stale",
            segmentID: update.turnID,
            isFinal: false,
            textLength: request.turn.originalText.count,
            metadata: translationMetadata(
                for: request,
                extra: draftVisibilityMetadata(
                    request: request,
                    current: current,
                    decision: "hidden_stale",
                    freshness: "none",
                    rejectReason: approximateDraftAttachRejectReason(request: request, current: current)
                )
            )
        )
    }

    private func draftVisibilityMetadata(
        request: ActiveCaptionTranslationRequest,
        current: LiveCaptionTurn,
        decision: String,
        freshness: String,
        similarity: Double? = nil,
        rejectReason: String? = nil
    ) -> [String: String] {
        let sourceWords = wordCount(in: request.sourceText)
        let currentWords = wordCount(in: current.originalText)
        var metadata: [String: String] = [
            "translationFreshness": freshness,
            "currentTextLength": String(current.originalText.count),
            "sourceLagCharacters": String(max(0, current.originalText.count - request.sourceText.count)),
            "sourceLagWords": String(max(0, currentWords - sourceWords)),
            "sourceLagMilliseconds": String(milliseconds(from: request.turn.createdAt, to: current.createdAt)),
            "attachDecision": decision,
            "visibleTranslationAgeMilliseconds": String(milliseconds(from: request.turn.createdAt, to: now()))
        ]
        metadata["sourceSimilarity"] = String(format: "%.3f", similarity ?? draftSourceSimilarity(request.sourceText, current.originalText))
        if let rejectReason {
            metadata["attachRejectReason"] = rejectReason
        }
        return metadata
    }

    private func translationMetadata(
        for request: ActiveCaptionTranslationRequest,
        extra: [String: String] = [:]
    ) -> [String: String] {
        let turn = request.turn
        var metadata: [String: String] = [
            "turnID": turn.id,
            "sourceSegmentID": turn.sourceSegmentID,
            "sourceSegmentIDs": turn.sourceSegmentIDs.joined(separator: ","),
            "sourceLocale": turn.sourceLocale,
            "targetLocale": turn.targetLocale,
            "translationKind": request.isDraft ? "draft" : "final",
            "translationRequestID": request.id,
            "providerID": request.providerID,
            "translationRevision": String(request.revision),
            "translationKeyHash": stableHash(request.key),
            "sourceTextHash": stableHash(request.sourceText),
            "sourceTextLength": String(request.sourceText.count),
            "requestOrdinalForTurn": String(request.requestOrdinalForTurn),
            "debounceMilliseconds": String(request.configuration.draftDebounceNanoseconds / 1_000_000),
            "concurrencyLimit": String(request.configuration.maxConcurrentTranslationRequests)
        ]
        if let boundaryStrength = turn.boundaryStrength {
            metadata["boundaryStrength"] = String(describing: boundaryStrength)
        }
        if let boundaryReason = turn.boundaryReason {
            metadata["boundaryReason"] = boundaryReason.rawValue
        }
        if let queueDepth = request.queueDepth {
            metadata["queueDepth"] = String(queueDepth)
        }
        if let inFlightCount = request.inFlightCount {
            metadata["inFlightCount"] = String(inFlightCount)
        }
        for (key, value) in extra {
            metadata[key] = value
        }
        return metadata
    }

    private func logSkipped(
        turn: LiveCaptionTurn,
        key: String,
        isFinalTranslation: Bool,
        reason: String
    ) {
        let request = ActiveCaptionTranslationRequest(
            id: "caption-translation-skipped-\(UUID().uuidString)",
            turn: turn,
            key: key,
            isDraft: !isFinalTranslation,
            revision: turn.translationRevision,
            requestOrdinalForTurn: requestOrdinalsByTurnID[turn.id, default: 0],
            sourceText: turn.originalText,
            configuration: configuration
        )
        performanceEventLogger?.log(
            "caption_translation_skipped",
            segmentID: turn.id,
            isFinal: isFinalTranslation,
            textLength: turn.originalText.count,
            metadata: translationMetadata(for: request, extra: ["skipReason": reason])
        )
        logCount("caption_translation_skipped_count", request: request, extra: ["skipReason": reason])
    }

    private func logCount(
        _ event: String,
        request: ActiveCaptionTranslationRequest,
        extra: [String: String] = [:]
    ) {
        performanceEventLogger?.log(
            event,
            segmentID: request.turn.id,
            isFinal: !request.isDraft,
            textLength: request.turn.originalText.count,
            metadata: translationMetadata(for: request, extra: extra.merging(["count": "1"]) { current, _ in current })
        )
    }

    private func nextRequestOrdinal(forTurnID turnID: String) -> Int {
        let next = requestOrdinalsByTurnID[turnID, default: 0] + 1
        requestOrdinalsByTurnID[turnID] = next
        return next
    }

    private func currentTurnForFinalRequest(
        _ request: ActiveCaptionTranslationRequest,
        in store: LiveCaptionStore
    ) -> LiveCaptionTurn? {
        guard let target = request.attachmentTarget else {
            return store.turns.first(where: { $0.id == request.turn.id })
        }
        let targetIDs = Set(target.sourceSegmentIDs)
        if let original = store.turns.first(where: { $0.id == target.originalTurnID }),
           targetIDs.isSubset(of: Set(original.sourceSegmentIDs)),
           original.targetLocale == target.targetLocale {
            return original
        }
        return store.turns.first { turn in
            targetIDs.isSubset(of: Set(turn.sourceSegmentIDs))
                && turn.targetLocale == target.targetLocale
        }
    }

    private func isCurrentDraftUpdate(
        _ update: CaptionTranslationUpdate,
        current: LiveCaptionTurn
    ) -> Bool {
        guard let request = update.request else { return false }
        return request.isDraft
            && current.translationHealth == .pending
            && draftTranslationKey(for: current) == update.key
    }

    private func approximateDraftAttachDecision(
        request: ActiveCaptionTranslationRequest,
        current: LiveCaptionTurn
    ) -> ApproximateDraftAttachDecision? {
        guard approximateDraftAttachRejectReason(request: request, current: current) == nil else {
            return nil
        }
        return ApproximateDraftAttachDecision(similarity: draftSourceSimilarity(request.sourceText, current.originalText))
    }

    private func approximateDraftAttachRejectReason(
        request: ActiveCaptionTranslationRequest,
        current: LiveCaptionTurn
    ) -> String? {
        guard request.isDraft else { return "not_draft" }
        guard current.id == request.turn.id else { return "different_turn" }
        guard current.sourceLocale == request.turn.sourceLocale,
              current.targetLocale == request.turn.targetLocale
        else {
            return "locale_changed"
        }
        guard !(current.displayState == .sealed && current.boundaryStrength == .hard) else {
            return "hard_final"
        }
        let requestWordCount = wordCount(in: request.sourceText)
        guard request.sourceText.count >= configuration.minimumApproximateDraftCharacters
                || requestWordCount >= configuration.minimumApproximateDraftWords
        else {
            return "source_too_short"
        }
        guard nanoseconds(from: request.turn.createdAt, to: now()) <= configuration.maximumApproximateDraftAgeNanoseconds else {
            return "result_too_old"
        }
        let normalizedRequest = normalizedTranslationSourceText(request.sourceText)
        let normalizedCurrent = normalizedTranslationSourceText(current.originalText)
        if normalizedCurrent.hasPrefix(normalizedRequest) {
            return nil
        }
        let similarity = draftSourceSimilarity(normalizedRequest, normalizedCurrent)
        guard similarity >= configuration.approximateDraftSimilarityThreshold else {
            return "low_similarity"
        }
        return nil
    }

    private func draftSourceSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let lhsTokens = Set(normalizedTranslationSourceText(lhs).split(separator: " ").map(String.init))
        let rhsTokens = Set(normalizedTranslationSourceText(rhs).split(separator: " ").map(String.init))
        guard !lhsTokens.isEmpty, !rhsTokens.isEmpty else {
            return normalizedTranslationSourceText(lhs) == normalizedTranslationSourceText(rhs) ? 1 : 0
        }
        let intersection = lhsTokens.intersection(rhsTokens).count
        let union = lhsTokens.union(rhsTokens).count
        return Double(intersection) / Double(union)
    }

    private func markDraftRequestStarted(forTurnID turnID: String) {
        planner.markRequestStarted(forTurnID: turnID)
    }

    private func markDraftRequestFinished(forTurnID turnID: String) {
        planner.markRequestFinished(forTurnID: turnID)
    }

    private func markDraftTranslationVisible(forTurnID turnID: String) {
        planner.markTranslationVisible(forTurnID: turnID)
    }

    private func draftTriggerDecision(for turn: LiveCaptionTurn, sourceText: String) -> CaptionTranslationPlanningDecision {
        planner.decision(for: turn, sourceText: sourceText)
    }

    private func wordCount(in text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }

    private func nanoseconds(from start: Date, to end: Date) -> UInt64 {
        UInt64(max(0, end.timeIntervalSince(start)) * 1_000_000_000)
    }

    private func milliseconds(from start: Date, to end: Date) -> Int {
        max(0, Int((end.timeIntervalSince(start) * 1_000).rounded()))
    }

    private func persistFinalTranslation(
        _ text: String,
        request: ActiveCaptionTranslationRequest
    ) -> CaptionTranslationApplyOutcome {
        guard let target = request.attachmentTarget,
              let persistTranslation,
              persistTranslation(target, text, true)
        else {
            logStaleWithoutCurrent(request: request, reason: "source_segment_deleted")
            return .none
        }
        performanceEventLogger?.log(
            "caption_translation_persisted",
            segmentID: target.primarySourceSegmentID,
            isFinal: true,
            textLength: text.count,
            metadata: translationMetadata(for: request)
        )
        logCount("caption_translation_completed_count", request: request)
        return .persisted(segmentID: target.primarySourceSegmentID)
    }

    private func logStaleWithoutCurrent(request: ActiveCaptionTranslationRequest, reason: String) {
        performanceEventLogger?.log(
            "caption_translation_stale",
            segmentID: request.attachmentTarget?.primarySourceSegmentID ?? request.turn.id,
            isFinal: !request.isDraft,
            textLength: request.turn.originalText.count,
            metadata: translationMetadata(for: request, extra: ["reason": reason])
        )
        logCount("caption_translation_stale_count", request: request, extra: ["reason": reason])
    }
}

private func stableHash(_ value: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in value.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
    }
    return String(hash, radix: 16)
}

public struct CaptionTranslationAttachmentTarget: Equatable {
    public var originalTurnID: String
    public var primarySourceSegmentID: String
    public var sourceSegmentIDs: [String]
    public var sourceText: String
    public var speaker: TranscriptSpeaker?
    public var sourceLocale: String
    public var targetLocale: String
    public var createdAt: Date

    public init(
        originalTurnID: String,
        primarySourceSegmentID: String,
        sourceSegmentIDs: [String],
        sourceText: String,
        speaker: TranscriptSpeaker?,
        sourceLocale: String,
        targetLocale: String,
        createdAt: Date
    ) {
        self.originalTurnID = originalTurnID
        self.primarySourceSegmentID = primarySourceSegmentID
        self.sourceSegmentIDs = sourceSegmentIDs
        self.sourceText = sourceText
        self.speaker = speaker
        self.sourceLocale = sourceLocale
        self.targetLocale = targetLocale
        self.createdAt = createdAt
    }

    init(turn: LiveCaptionTurn, sourceText: String) {
        self.init(
            originalTurnID: turn.id,
            primarySourceSegmentID: turn.sourceSegmentID,
            sourceSegmentIDs: turn.sourceSegmentIDs,
            sourceText: sourceText,
            speaker: turn.speaker,
            sourceLocale: turn.sourceLocale,
            targetLocale: turn.targetLocale,
            createdAt: turn.createdAt
        )
    }
}

enum CaptionTranslationApplyOutcome: Equatable {
    case none
    case attached(turnID: String)
    case rebound(originalTurnID: String, reboundTurnID: String)
    case persisted(segmentID: String)

    var publishedVisibleText: Bool {
        switch self {
        case .attached, .rebound:
            return true
        case .none, .persisted:
            return false
        }
    }
}

struct ActiveCaptionTranslationRequest: Equatable {
    var id: String
    var turn: LiveCaptionTurn
    var key: String
    var isDraft: Bool
    var revision: Int
    var requestOrdinalForTurn: Int = 1
    var sourceText: String = ""
    var attachmentTarget: CaptionTranslationAttachmentTarget? = nil
    var providerID: String = ""
    var configuration: CaptionTranslationSchedulerConfiguration = CaptionTranslationSchedulerConfiguration()
    var queueDepth: Int?
    var inFlightCount: Int?
}

private struct ApproximateDraftAttachDecision: Equatable {
    var similarity: Double
}

private struct CaptionTranslationExecution {
    var request: ActiveCaptionTranslationRequest?
    var segment: TranscriptSegment?
    var options: TranslationOptions
    var provider: TextTranslationProvider?
    var update: CaptionTranslationUpdate?

    func metadata(queueDepth: Int, inFlightCount: Int) -> [String: String] {
        guard let request else { return [:] }
        var metadata = CaptionTranslationExecutionMetadata.metadata(for: request)
        metadata["queueDepth"] = String(queueDepth)
        metadata["inFlightCount"] = String(inFlightCount)
        return metadata
    }
}

enum CaptionTranslationExecutionMetadata {
    static func metadata(for request: ActiveCaptionTranslationRequest) -> [String: String] {
        let turn = request.turn
        var metadata: [String: String] = [
            "turnID": turn.id,
            "sourceSegmentID": turn.sourceSegmentID,
            "sourceSegmentIDs": turn.sourceSegmentIDs.joined(separator: ","),
            "sourceLocale": turn.sourceLocale,
            "targetLocale": turn.targetLocale,
            "translationKind": request.isDraft ? "draft" : "final",
            "translationRequestID": request.id,
            "providerID": request.providerID,
            "translationRevision": String(request.revision),
            "translationKeyHash": stableHash(request.key),
            "sourceTextHash": stableHash(request.sourceText),
            "sourceTextLength": String(request.sourceText.count),
            "requestOrdinalForTurn": String(request.requestOrdinalForTurn),
            "debounceMilliseconds": String(request.configuration.draftDebounceNanoseconds / 1_000_000),
            "concurrencyLimit": String(request.configuration.maxConcurrentTranslationRequests)
        ]
        if let boundaryStrength = turn.boundaryStrength {
            metadata["boundaryStrength"] = String(describing: boundaryStrength)
        }
        if let boundaryReason = turn.boundaryReason {
            metadata["boundaryReason"] = boundaryReason.rawValue
        }
        if let queueDepth = request.queueDepth {
            metadata["queueDepth"] = String(queueDepth)
        }
        if let inFlightCount = request.inFlightCount {
            metadata["inFlightCount"] = String(inFlightCount)
        }
        return metadata
    }
}

enum CaptionTranslationUpdateResult: Equatable {
    case completeWithoutText
    case draftText(String)
    case finalText(String)
    case failed(String)
}

struct CaptionTranslationUpdate: Equatable {
    var turnID: String
    var key: String
    var result: CaptionTranslationUpdateResult
    var request: ActiveCaptionTranslationRequest?
    var resultReceivedAt: Date? = nil
}

extension CaptionTranslationUpdate {
    var attachesVisibleText: Bool {
        switch result {
        case .draftText, .finalText:
            return true
        case .completeWithoutText, .failed:
            return false
        }
    }

    var visibleTextLength: Int? {
        switch result {
        case .draftText(let text), .finalText(let text):
            return text.count
        case .completeWithoutText, .failed:
            return nil
        }
    }
}
