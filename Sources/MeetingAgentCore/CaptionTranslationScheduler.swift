import Foundation

@MainActor
public final class CaptionTranslationScheduler {
    private let provider: TextTranslationProvider?
    private let performanceEventLogger: PerformanceEventLogger?
    private let persistTranslation: ((LiveCaptionTurn, String, Bool) -> Void)?
    private var requestedFinalTranslationKeys: Set<String> = []
    private var activeRequestsByKey: [String: ActiveCaptionTranslationRequest] = [:]

    public init(
        provider: TextTranslationProvider?,
        performanceEventLogger: PerformanceEventLogger?,
        persistTranslation: ((LiveCaptionTurn, String, Bool) -> Void)? = nil
    ) {
        self.provider = provider
        self.performanceEventLogger = performanceEventLogger
        self.persistTranslation = persistTranslation
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
        var updates: [CaptionTranslationUpdate] = []
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
            if let update = await translationUpdate(for: turn, in: store, includingDrafts: includingDrafts) {
                updates.append(update)
            }
        }
        return updates
    }

    func apply(_ update: CaptionTranslationUpdate, to store: inout LiveCaptionStore) {
        guard let current = store.turns.first(where: { $0.id == update.turnID }) else {
            return
        }
        let currentKey = finalTranslationKey(for: current)
        guard current.translationHealth == .pending,
              currentKey == update.key
        else {
            if let request = update.request {
                logStale(update: update, request: request, current: current)
            }
            return
        }

        switch update.result {
        case .completeWithoutText:
            store.markTranslationCompleteWithoutText(forTurnID: update.turnID)
        case .draftText(let text):
            store.attachTranslation(text, toTurnID: update.turnID)
            persistTranslation?(current, text, false)
        case .finalText(let text):
            store.attachTranslation(text, toTurnID: update.turnID)
            store.markTranslationFinal(forTurnID: update.turnID)
            persistTranslation?(current, text, true)
        case .failed(let message):
            store.markTranslationFailed(forTurnID: update.turnID, message: message)
        }
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

    private func translationUpdate(
        for turn: LiveCaptionTurn,
        in store: LiveCaptionStore,
        includingDrafts: Bool
    ) async -> CaptionTranslationUpdate? {
        let key = finalTranslationKey(for: turn)
        let options = TranslationOptions(sourceLocale: turn.sourceLocale, targetLocale: turn.targetLocale)
        if options.isSameLanguage {
            return CaptionTranslationUpdate(turnID: turn.id, key: key, result: .completeWithoutText, request: nil)
        }

        let isFinalTranslation = turn.displayState == .sealed && turn.boundaryStrength == .hard
        guard isFinalTranslation || includingDrafts else {
            return nil
        }
        guard let provider else {
            return nil
        }
        guard !requestedFinalTranslationKeys.contains(key) else {
            return nil
        }
        requestedFinalTranslationKeys.insert(key)
        let requestID = "caption-translation-\(UUID().uuidString)"
        let request = ActiveCaptionTranslationRequest(
            id: requestID,
            turn: turn,
            key: key,
            isDraft: !isFinalTranslation,
            revision: turn.translationRevision
        )
        activeRequestsByKey[key] = request
        let metadata = translationMetadata(
            for: request
        )
        performanceEventLogger?.log(
            "caption_translation_scheduled",
            segmentID: turn.id,
            isFinal: isFinalTranslation,
            textLength: turn.originalText.count,
            metadata: metadata
        )

        let segment = TranscriptSegment(
            id: turn.sourceSegmentID,
            speaker: turn.speaker,
            text: translationSourceText(for: turn, in: store, final: isFinalTranslation),
            language: turn.sourceLocale,
            isFinal: isFinalTranslation,
            createdAt: turn.createdAt
        )
        do {
            performanceEventLogger?.log(
                "caption_translation_started",
                segmentID: turn.id,
                isFinal: true,
                textLength: turn.originalText.count,
                metadata: metadata
            )
            let translated = try await provider.translate(
                transcript: TranscriptDocument(segments: [segment]),
                options: options
            )
            let translatedText = translated.segments.first { $0.id == turn.sourceSegmentID }?.targetText ?? ""
            performanceEventLogger?.log(
                "caption_translation_finished",
                segmentID: turn.id,
                isFinal: true,
                textLength: translatedText.count,
                metadata: metadata
            )
            performanceEventLogger?.log(
                "caption_translation_attached",
                segmentID: turn.id,
                isFinal: true,
                textLength: translatedText.count,
                metadata: metadata
            )
            return CaptionTranslationUpdate(
                turnID: turn.id,
                key: key,
                result: isFinalTranslation ? .finalText(translatedText) : .draftText(translatedText),
                request: activeRequestsByKey.removeValue(forKey: key) ?? request
            )
        } catch {
            activeRequestsByKey.removeValue(forKey: key)
            let nsError = error as NSError
            return CaptionTranslationUpdate(
                turnID: turn.id,
                key: key,
                result: .failed("\(nsError.domain) error \(nsError.code)"),
                request: request
            )
        }
    }

    private func finalTranslationKey(for turn: LiveCaptionTurn) -> String {
        [
            turn.id,
            turn.sourceSegmentIDs.joined(separator: ","),
            turn.originalText,
            turn.sourceLocale,
            turn.targetLocale
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
            "translationRevision": String(request.revision),
            "translationKeyHash": String(request.key.hashValue)
        ]
        if let boundaryStrength = turn.boundaryStrength {
            metadata["boundaryStrength"] = String(describing: boundaryStrength)
        }
        if let boundaryReason = turn.boundaryReason {
            metadata["boundaryReason"] = boundaryReason.rawValue
        }
        for (key, value) in extra {
            metadata[key] = value
        }
        return metadata
    }
}

struct ActiveCaptionTranslationRequest: Equatable {
    var id: String
    var turn: LiveCaptionTurn
    var key: String
    var isDraft: Bool
    var revision: Int
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
}
