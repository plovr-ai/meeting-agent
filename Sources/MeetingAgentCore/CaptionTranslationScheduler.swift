import Foundation

public struct CaptionTranslationSchedulerConfiguration: Equatable {
    public var draftDebounceNanoseconds: UInt64
    public var maxConcurrentTranslationRequests: Int

    public init(
        draftDebounceNanoseconds: UInt64 = 200_000_000,
        maxConcurrentTranslationRequests: Int = 2
    ) {
        self.draftDebounceNanoseconds = draftDebounceNanoseconds
        self.maxConcurrentTranslationRequests = max(1, maxConcurrentTranslationRequests)
    }
}

@MainActor
public final class CaptionTranslationScheduler {
    private let provider: TextTranslationProvider?
    private let performanceEventLogger: PerformanceEventLogger?
    private let persistTranslation: ((LiveCaptionTurn, String, Bool) -> Void)?
    private let configuration: CaptionTranslationSchedulerConfiguration
    private var requestedFinalTranslationKeys: Set<String> = []
    private var activeRequestsByKey: [String: ActiveCaptionTranslationRequest] = [:]
    private var pendingDraftTokensByTurnID: [String: UUID] = [:]
    private var requestOrdinalsByTurnID: [String: Int] = [:]

    public init(
        provider: TextTranslationProvider?,
        performanceEventLogger: PerformanceEventLogger?,
        persistTranslation: ((LiveCaptionTurn, String, Bool) -> Void)? = nil,
        configuration: CaptionTranslationSchedulerConfiguration = CaptionTranslationSchedulerConfiguration()
    ) {
        self.provider = provider
        self.performanceEventLogger = performanceEventLogger
        self.persistTranslation = persistTranslation
        self.configuration = configuration
    }

    public func scheduleTranslations(in store: inout LiveCaptionStore) async {
        for update in await translationUpdates(for: store) {
            apply(update, to: &store)
        }
    }

    func translationUpdates(for store: LiveCaptionStore) async -> [CaptionTranslationUpdate] {
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
    func apply(_ update: CaptionTranslationUpdate, to store: inout LiveCaptionStore) -> Bool {
        guard let current = store.turns.first(where: { $0.id == update.turnID }) else {
            return false
        }
        let currentIsFinalTranslation = update.request.map { !$0.isDraft }
            ?? (current.displayState == .sealed && current.boundaryStrength == .hard)
        let currentKey = translationKey(for: current, isFinalTranslation: currentIsFinalTranslation)
        guard current.translationHealth == .pending,
              currentKey == update.key
        else {
            if let request = update.request {
                logStale(update: update, request: request, current: current)
            }
            return false
        }

        switch update.result {
        case .completeWithoutText:
            store.markTranslationCompleteWithoutText(forTurnID: update.turnID)
            return false
        case .draftText(let text):
            store.attachTranslation(text, toTurnID: update.turnID)
            if let request = update.request {
                logAttached(request: request, textLength: text.count)
            }
            persistTranslation?(current, text, false)
            return true
        case .finalText(let text):
            store.attachTranslation(text, toTurnID: update.turnID)
            store.markTranslationFinal(forTurnID: update.turnID)
            if let request = update.request {
                logAttached(request: request, textLength: text.count)
            }
            persistTranslation?(current, text, true)
            return true
        case .failed(let message):
            store.markTranslationFailed(forTurnID: update.turnID, message: message)
            return false
        }
    }

    func discardStale(_ update: CaptionTranslationUpdate, against store: LiveCaptionStore) {
        guard let request = update.request,
              let current = store.turns.first(where: { $0.id == update.turnID })
        else {
            return
        }
        let currentIsFinalTranslation = !request.isDraft
        let currentKey = translationKey(for: current, isFinalTranslation: currentIsFinalTranslation)
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
        }
    }

    private func translationExecution(
        for turn: LiveCaptionTurn,
        in store: LiveCaptionStore,
        includingDrafts: Bool
    ) async -> CaptionTranslationExecution? {
        let isFinalTranslation = turn.displayState == .sealed && turn.boundaryStrength == .hard
        let key = translationKey(for: turn, isFinalTranslation: isFinalTranslation)
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
        guard !requestedFinalTranslationKeys.contains(key) else {
            logSkipped(turn: turn, key: key, isFinalTranslation: isFinalTranslation, reason: "duplicate_key")
            return nil
        }
        requestedFinalTranslationKeys.insert(key)
        let requestID = "caption-translation-\(UUID().uuidString)"
        let sourceText = translationSourceText(for: turn, in: store, final: isFinalTranslation)
        let requestOrdinal = nextRequestOrdinal(forTurnID: turn.id)
        let request = ActiveCaptionTranslationRequest(
            id: requestID,
            turn: turn,
            key: key,
            isDraft: !isFinalTranslation,
            revision: turn.translationRevision,
            requestOrdinalForTurn: requestOrdinal,
            sourceText: sourceText,
            providerID: provider.descriptor.id,
            configuration: configuration
        )
        activeRequestsByKey[key] = request
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
            guard pendingDraftTokensByTurnID[turn.id] == token,
                  activeRequestsByKey[key] != nil
            else {
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
        let metadata = translationMetadata(for: request)
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

    private func translationKey(for turn: LiveCaptionTurn, isFinalTranslation: Bool) -> String {
        [
            turn.id,
            turn.sourceSegmentIDs.joined(separator: ","),
            turn.originalText,
            turn.sourceLocale,
            turn.targetLocale,
            isFinalTranslation ? "final" : "draft",
            turn.displayState.rawValue,
            turn.boundaryStrength.map(String.init(describing:)) ?? "",
            turn.boundaryReason?.rawValue ?? "",
            String(turn.translationRevision)
        ].joined(separator: "\u{1F}")
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

    private func logAttached(request: ActiveCaptionTranslationRequest, textLength: Int) {
        performanceEventLogger?.log(
            "caption_translation_attached",
            segmentID: request.turn.id,
            isFinal: !request.isDraft,
            textLength: textLength,
            metadata: translationMetadata(for: request)
        )
        logCount("caption_translation_completed_count", request: request)
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
}

private func stableHash(_ value: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in value.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
    }
    return String(hash, radix: 16)
}

struct ActiveCaptionTranslationRequest: Equatable {
    var id: String
    var turn: LiveCaptionTurn
    var key: String
    var isDraft: Bool
    var revision: Int
    var requestOrdinalForTurn: Int = 1
    var sourceText: String = ""
    var providerID: String = ""
    var configuration: CaptionTranslationSchedulerConfiguration = CaptionTranslationSchedulerConfiguration()
    var queueDepth: Int?
    var inFlightCount: Int?
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
