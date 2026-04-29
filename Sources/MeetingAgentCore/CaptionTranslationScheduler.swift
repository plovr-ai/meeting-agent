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
        for turn in store.turns where turn.translationHealth == .pending {
            let options = TranslationOptions(sourceLocale: turn.sourceLocale, targetLocale: turn.targetLocale)
            if options.isSameLanguage {
                store.markTranslationCompleteWithoutText(forTurnID: turn.id)
                continue
            }

            guard turn.displayState == .sealed,
                  turn.boundaryStrength == .hard
            else {
                continue
            }
            guard let provider else {
                continue
            }

            let key = finalTranslationKey(for: turn)
            guard !requestedFinalTranslationKeys.contains(key) else {
                continue
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
                store.attachTranslation(translatedText, toTurnID: turn.id)
                store.markTranslationFinal(forTurnID: turn.id)
            } catch {
                let nsError = error as NSError
                store.markTranslationFailed(
                    forTurnID: turn.id,
                    message: "\(nsError.domain) error \(nsError.code)"
                )
            }
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
