import Foundation

struct ReplayTranslationBackfillPlanner {
    private let configuration: ReplayTranslationBackfillSchedulerConfiguration
    private let now: () -> Date
    private var statesByTurnID: [String: CaptionTranslationPlanningState] = [:]

    init(
        configuration: ReplayTranslationBackfillSchedulerConfiguration,
        now: @escaping () -> Date
    ) {
        self.configuration = configuration
        self.now = now
    }

    mutating func decision(
        for turn: LiveCaptionTurn,
        sourceText: String
    ) -> CaptionTranslationPlanningDecision {
        var state = statesByTurnID[turn.id, default: CaptionTranslationPlanningState()]
        let currentWordCount = wordCount(in: sourceText)
        let currentCharacterCount = sourceText.count
        let wordDelta = max(0, currentWordCount - state.lastRequestedWordCount)
        let characterDelta = max(0, currentCharacterCount - state.lastRequestedCharacterCount)
        let hasBoundary = hasSemanticBoundary(sourceText)
        let currentTime = now()
        var metadata: [String: String] = [
            "wordDelta": String(wordDelta),
            "characterDelta": String(characterDelta),
            "hasSemanticBoundary": String(hasBoundary),
            "minimumInitialDraftWordCount": String(configuration.minimumInitialDraftWordCount),
            "minimumInitialDraftCharacterCount": String(configuration.minimumInitialDraftCharacterCount),
            "minimumInitialDraftCJKCharacterCount": String(configuration.minimumInitialDraftCJKCharacterCount)
        ]

        if let lastRequestAt = state.lastRequestAt {
            metadata["millisecondsSinceLastDraftRequest"] = String(milliseconds(from: lastRequestAt, to: currentTime))
        }
        if let lastVisibleTranslationAt = state.lastVisibleTranslationAt {
            metadata["millisecondsSinceLastVisibleDraftTranslation"] = String(milliseconds(from: lastVisibleTranslationAt, to: currentTime))
        }

        guard !state.isInFlight else {
            return .skip(reason: "in_flight", metadata: metadata)
        }

        guard state.hasSentInitialRequest else {
            guard initialDraftIsReady(sourceText, wordCount: currentWordCount, characterCount: currentCharacterCount, hasBoundary: hasBoundary) else {
                return .skip(reason: fillerLike(sourceText) ? "filler" : "too_short_initial", metadata: metadata)
            }
            state.hasSentInitialRequest = true
            state.lastRequestedSourceText = sourceText
            state.lastRequestedWordCount = currentWordCount
            state.lastRequestedCharacterCount = currentCharacterCount
            state.lastRequestAt = currentTime
            statesByTurnID[turn.id] = state
            return .trigger(reason: hasBoundary ? "initial_boundary" : "initial", metadata: metadata)
        }

        if let lastRequestAt = state.lastRequestAt,
           nanoseconds(from: lastRequestAt, to: currentTime) < configuration.followUpDraftMinimumIntervalNanoseconds {
            return .skip(reason: "min_interval", metadata: metadata)
        }

        let exceededMaximumWait: Bool = {
            guard let lastVisibleTranslationAt = state.lastVisibleTranslationAt ?? state.lastRequestAt else {
                return false
            }
            return nanoseconds(from: lastVisibleTranslationAt, to: currentTime) >= configuration.followUpDraftMaximumWaitNanoseconds
        }()
        let reachedContentDelta = wordDelta >= configuration.minimumDraftWordDelta
            || characterDelta >= configuration.minimumDraftCharacterDelta

        guard hasBoundary || reachedContentDelta || exceededMaximumWait else {
            return .skip(reason: "not_stable_enough", metadata: metadata)
        }

        let reason: String
        if hasBoundary {
            reason = "semantic_boundary"
        } else if reachedContentDelta {
            reason = "content_delta"
        } else {
            reason = "max_wait"
        }
        state.lastRequestedSourceText = sourceText
        state.lastRequestedWordCount = currentWordCount
        state.lastRequestedCharacterCount = currentCharacterCount
        state.lastRequestAt = currentTime
        statesByTurnID[turn.id] = state
        return .trigger(reason: reason, metadata: metadata)
    }

    mutating func markRequestStarted(forTurnID turnID: String) {
        guard var state = statesByTurnID[turnID] else { return }
        state.isInFlight = true
        statesByTurnID[turnID] = state
    }

    mutating func markRequestFinished(forTurnID turnID: String) {
        guard var state = statesByTurnID[turnID] else { return }
        state.isInFlight = false
        statesByTurnID[turnID] = state
    }

    mutating func markTranslationVisible(forTurnID turnID: String) {
        guard var state = statesByTurnID[turnID] else { return }
        state.lastVisibleTranslationAt = now()
        statesByTurnID[turnID] = state
    }

    private func initialDraftIsReady(
        _ text: String,
        wordCount: Int,
        characterCount: Int,
        hasBoundary: Bool
    ) -> Bool {
        guard !fillerLike(text) else { return false }
        if containsCJKCharacter(text) {
            return characterCount >= configuration.minimumInitialDraftCJKCharacterCount
        }
        if wordCount >= configuration.minimumInitialDraftWordCount {
            return true
        }
        if characterCount >= configuration.minimumInitialDraftCharacterCount {
            return true
        }
        return hasBoundary && characterCount >= configuration.minimumBoundaryDraftCharacterCount
    }

    private func fillerLike(_ text: String) -> Bool {
        let normalized = text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
        guard !normalized.isEmpty else { return true }
        return configuration.fillerDraftPhrases.contains(normalized)
    }

    private func hasSemanticBoundary(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else {
            return false
        }
        return configuration.semanticBoundaryCharacters.contains(last)
    }

    private func containsCJKCharacter(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let value = Int(scalar.value)
            return (0x4E00...0x9FFF).contains(value)
                || (0x3040...0x30FF).contains(value)
                || (0xAC00...0xD7AF).contains(value)
        }
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
}

enum CaptionTranslationPlanningDecision: Equatable {
    case trigger(reason: String, metadata: [String: String])
    case skip(reason: String, metadata: [String: String])
}

private struct CaptionTranslationPlanningState: Equatable {
    var hasSentInitialRequest = false
    var lastRequestedSourceText = ""
    var lastRequestedWordCount = 0
    var lastRequestedCharacterCount = 0
    var lastRequestAt: Date?
    var lastVisibleTranslationAt: Date?
    var isInFlight = false
}
