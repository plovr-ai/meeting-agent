import Foundation

public final class CaptionTranslationScheduler {
    private let provider: TextTranslationProvider?
    private let performanceEventLogger: PerformanceEventLogger?
    private var requestedFinalTranslationKeys: Set<String> = []

    public init(provider: TextTranslationProvider?, performanceEventLogger: PerformanceEventLogger?) {
        self.provider = provider
        self.performanceEventLogger = performanceEventLogger
    }

    public func scheduleTranslations(in store: inout LiveCaptionStore) async {
        for update in await translationUpdates(for: store) {
            apply(update, to: &store)
        }
    }

    func translationUpdates(for store: LiveCaptionStore) async -> [CaptionTranslationUpdate] {
        var updates: [CaptionTranslationUpdate] = []
        for turn in store.turns where turn.translationHealth == .pending {
            if let update = await translationUpdate(for: turn) {
                updates.append(update)
            }
        }
        return updates
    }

    func apply(_ update: CaptionTranslationUpdate, to store: inout LiveCaptionStore) {
        guard let current = store.turns.first(where: { $0.id == update.turnID }),
              current.translationHealth == .pending,
              finalTranslationKey(for: current) == update.key
        else {
            return
        }

        switch update.result {
        case .completeWithoutText:
            store.markTranslationCompleteWithoutText(forTurnID: update.turnID)
        case .finalText(let text):
            store.attachTranslation(text, toTurnID: update.turnID)
            store.markTranslationFinal(forTurnID: update.turnID)
        case .failed(let message):
            store.markTranslationFailed(forTurnID: update.turnID, message: message)
        }
    }

    private func translationUpdate(for turn: LiveCaptionTurn) async -> CaptionTranslationUpdate? {
        let key = finalTranslationKey(for: turn)
        let options = TranslationOptions(sourceLocale: turn.sourceLocale, targetLocale: turn.targetLocale)
        if options.isSameLanguage {
            return CaptionTranslationUpdate(turnID: turn.id, key: key, result: .completeWithoutText)
        }

        guard turn.displayState == .sealed,
              turn.boundaryStrength == .hard
        else {
            return nil
        }
        guard let provider else {
            return nil
        }
        guard !requestedFinalTranslationKeys.contains(key) else {
            return nil
        }
        requestedFinalTranslationKeys.insert(key)

        let segment = TranscriptSegment(
            id: turn.sourceSegmentID,
            speaker: turn.speaker,
            text: turn.originalText,
            language: turn.sourceLocale,
            isFinal: true,
            createdAt: turn.createdAt
        )
        do {
            let translated = try await provider.translate(
                transcript: TranscriptDocument(segments: [segment]),
                options: options
            )
            let translatedText = translated.segments.first { $0.id == turn.sourceSegmentID }?.targetText ?? ""
            return CaptionTranslationUpdate(turnID: turn.id, key: key, result: .finalText(translatedText))
        } catch {
            let nsError = error as NSError
            return CaptionTranslationUpdate(
                turnID: turn.id,
                key: key,
                result: .failed("\(nsError.domain) error \(nsError.code)")
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
}

enum CaptionTranslationUpdateResult: Equatable {
    case completeWithoutText
    case finalText(String)
    case failed(String)
}

struct CaptionTranslationUpdate: Equatable {
    var turnID: String
    var key: String
    var result: CaptionTranslationUpdateResult
}
