import Foundation

public enum LivePipelineHealth: Codable, Equatable {
    case idle
    case pending
    case live
    case degraded(String)
    case failed(String)

    private enum CodingKeys: String, CodingKey {
        case state
        case message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let state = try container.decode(String.self, forKey: .state)
        let message = try container.decodeIfPresent(String.self, forKey: .message)
        switch state {
        case "idle":
            self = .idle
        case "pending":
            self = .pending
        case "live":
            self = .live
        case "degraded":
            self = .degraded(message ?? "")
        case "failed":
            self = .failed(message ?? "")
        default:
            self = .failed("Unknown health state: \(state)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .idle:
            try container.encode("idle", forKey: .state)
        case .pending:
            try container.encode("pending", forKey: .state)
        case .live:
            try container.encode("live", forKey: .state)
        case .degraded(let message):
            try container.encode("degraded", forKey: .state)
            try container.encode(message, forKey: .message)
        case .failed(let message):
            try container.encode("failed", forKey: .state)
            try container.encode(message, forKey: .message)
        }
    }
}

public enum LiveCaptionChunkState: String, Codable, Equatable {
    case draft
    case frozen
}

public enum LiveCaptionDisplayBlockState: String, Codable, Equatable {
    case draft
    case sealed
}

public enum LiveCaptionTranslationState: String, Codable, Equatable {
    case draft
    case pendingFinal
    case final
}

public enum LiveCaptionBoundaryStrength: String, Codable, Equatable {
    case soft
    case hard
}

public enum LiveCaptionFreezeReason: String, Codable, Equatable {
    case speechFinal
    case speakerChanged
    case maxLength
    case maxDuration
    case punctuation
    case manualStop

    public var boundaryStrength: LiveCaptionBoundaryStrength {
        switch self {
        case .speechFinal, .speakerChanged, .manualStop:
            return .hard
        case .maxLength, .maxDuration, .punctuation:
            return .soft
        }
    }
}

public struct MeetingKeyTerm: Codable, Equatable, Identifiable {
    public var id: String
    public var value: String
    public var translationHint: String?

    public init(id: String? = nil, value: String, translationHint: String? = nil) {
        self.value = value
        self.id = id ?? value
        self.translationHint = translationHint
    }
}

public struct MeetingObjective: Codable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var keywords: [String]

    public init(id: String, title: String, keywords: [String] = []) {
        self.id = id
        self.title = title
        self.keywords = keywords
    }
}

public struct MeetingGoal: Codable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var objectives: [MeetingObjective]
    public var requiredQuestions: [String]
    public var expectedDecisions: [String]
    public var keyTerms: [MeetingKeyTerm]

    public init(
        id: UUID = UUID(),
        title: String,
        objectives: [MeetingObjective],
        requiredQuestions: [String],
        expectedDecisions: [String],
        keyTerms: [MeetingKeyTerm]
    ) {
        self.id = id
        self.title = title
        self.objectives = objectives
        self.requiredQuestions = requiredQuestions
        self.expectedDecisions = expectedDecisions
        self.keyTerms = keyTerms
    }
}

public struct LiveCaptionTurn: Codable, Equatable, Identifiable {
    public var id: String
    public var sourceSegmentID: String
    public var sourceSegmentIDs: [String]
    public var speaker: TranscriptSpeaker
    public var originalText: String
    public var stableOriginalTextPrefix: String
    public var unstableOriginalTextTail: String
    public var translatedText: String?
    public var sourceLocale: String
    public var targetLocale: String
    public var isFinal: Bool
    public var captionHealth: LivePipelineHealth
    public var translationHealth: LivePipelineHealth
    public var createdAt: Date
    public var chunkState: LiveCaptionChunkState
    public var translationRevision: Int
    public var freezeReason: LiveCaptionFreezeReason?
    public var displayState: LiveCaptionDisplayBlockState
    public var translationState: LiveCaptionTranslationState
    public var boundaryReason: LiveCaptionFreezeReason?
    public var boundaryStrength: LiveCaptionBoundaryStrength?

    public init(
        id: String? = nil,
        sourceSegmentID: String,
        sourceSegmentIDs: [String]? = nil,
        speaker: TranscriptSpeaker = .default,
        originalText: String,
        stableOriginalTextPrefix: String? = nil,
        unstableOriginalTextTail: String? = nil,
        translatedText: String? = nil,
        sourceLocale: String = "en-US",
        targetLocale: String = "zh-CN",
        isFinal: Bool,
        captionHealth: LivePipelineHealth = .live,
        translationHealth: LivePipelineHealth = .pending,
        createdAt: Date = Date(),
        chunkState: LiveCaptionChunkState = .frozen,
        translationRevision: Int = 0,
        freezeReason: LiveCaptionFreezeReason? = nil,
        displayState: LiveCaptionDisplayBlockState? = nil,
        translationState: LiveCaptionTranslationState? = nil,
        boundaryReason: LiveCaptionFreezeReason? = nil,
        boundaryStrength: LiveCaptionBoundaryStrength? = nil
    ) {
        let resolvedDisplayState = displayState ?? (chunkState == .draft ? .draft : .sealed)
        let resolvedBoundaryReason = boundaryReason ?? freezeReason
        let resolvedBoundaryStrength = boundaryStrength ?? resolvedBoundaryReason?.boundaryStrength
        self.id = id ?? sourceSegmentID
        self.sourceSegmentID = sourceSegmentID
        self.sourceSegmentIDs = sourceSegmentIDs ?? [sourceSegmentID]
        self.speaker = speaker
        self.originalText = originalText
        let resolvedStablePrefix = stableOriginalTextPrefix ?? (isFinal ? originalText : "")
        self.stableOriginalTextPrefix = resolvedStablePrefix
        self.unstableOriginalTextTail = unstableOriginalTextTail ?? {
            if isFinal {
                return ""
            }
            return String(originalText.dropFirst(resolvedStablePrefix.count))
        }()
        self.translatedText = translatedText
        self.sourceLocale = sourceLocale
        self.targetLocale = targetLocale
        self.isFinal = isFinal
        self.captionHealth = captionHealth
        self.translationHealth = translationHealth
        self.createdAt = createdAt
        self.chunkState = chunkState
        self.translationRevision = translationRevision
        self.freezeReason = freezeReason
        self.displayState = resolvedDisplayState
        self.translationState = translationState ?? {
            if resolvedDisplayState == .draft {
                return .draft
            }
            return resolvedBoundaryStrength == .hard ? .final : .draft
        }()
        self.boundaryReason = resolvedBoundaryReason
        self.boundaryStrength = resolvedBoundaryStrength
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sourceSegmentID
        case sourceSegmentIDs
        case speaker
        case originalText
        case stableOriginalTextPrefix
        case unstableOriginalTextTail
        case translatedText
        case sourceLocale
        case targetLocale
        case isFinal
        case captionHealth
        case translationHealth
        case createdAt
        case chunkState
        case translationRevision
        case freezeReason
        case displayState
        case translationState
        case boundaryReason
        case boundaryStrength
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sourceSegmentID = try container.decode(String.self, forKey: .sourceSegmentID)
        sourceSegmentIDs = try container.decodeIfPresent([String].self, forKey: .sourceSegmentIDs) ?? [sourceSegmentID]
        speaker = try container.decode(TranscriptSpeaker.self, forKey: .speaker)
        originalText = try container.decode(String.self, forKey: .originalText)
        isFinal = try container.decode(Bool.self, forKey: .isFinal)
        let decodedStablePrefix = try container.decodeIfPresent(String.self, forKey: .stableOriginalTextPrefix)
        let resolvedStablePrefix = decodedStablePrefix ?? (isFinal ? originalText : "")
        stableOriginalTextPrefix = resolvedStablePrefix
        if let decodedUnstableTail = try container.decodeIfPresent(String.self, forKey: .unstableOriginalTextTail) {
            unstableOriginalTextTail = decodedUnstableTail
        } else if isFinal {
            unstableOriginalTextTail = ""
        } else {
            unstableOriginalTextTail = String(originalText.dropFirst(resolvedStablePrefix.count))
        }
        translatedText = try container.decodeIfPresent(String.self, forKey: .translatedText)
        sourceLocale = try container.decode(String.self, forKey: .sourceLocale)
        targetLocale = try container.decode(String.self, forKey: .targetLocale)
        captionHealth = try container.decode(LivePipelineHealth.self, forKey: .captionHealth)
        translationHealth = try container.decode(LivePipelineHealth.self, forKey: .translationHealth)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        chunkState = try container.decodeIfPresent(LiveCaptionChunkState.self, forKey: .chunkState) ?? .frozen
        translationRevision = try container.decodeIfPresent(Int.self, forKey: .translationRevision) ?? 0
        freezeReason = try container.decodeIfPresent(LiveCaptionFreezeReason.self, forKey: .freezeReason)
        let decodedDisplayState = try container.decodeIfPresent(LiveCaptionDisplayBlockState.self, forKey: .displayState)
        let decodedTranslationState = try container.decodeIfPresent(LiveCaptionTranslationState.self, forKey: .translationState)
        let decodedBoundaryReason = try container.decodeIfPresent(LiveCaptionFreezeReason.self, forKey: .boundaryReason) ?? freezeReason
        let decodedBoundaryStrength = try container.decodeIfPresent(LiveCaptionBoundaryStrength.self, forKey: .boundaryStrength) ?? decodedBoundaryReason?.boundaryStrength
        let resolvedDisplayState = decodedDisplayState ?? (chunkState == .draft ? .draft : .sealed)
        let resolvedTranslationState = decodedTranslationState ?? {
            if resolvedDisplayState == .draft {
                return .draft
            }
            return decodedBoundaryStrength == .hard ? .final : .draft
        }()
        displayState = resolvedDisplayState
        translationState = resolvedTranslationState
        boundaryReason = decodedBoundaryReason
        boundaryStrength = decodedBoundaryStrength
    }
}

public struct LiveCaptionSpeakerGroup: Equatable, Identifiable {
    public var id: String
    public var speaker: TranscriptSpeaker
    public var turns: [LiveCaptionTurn]
    public var startedAt: Date

    public init(id: String, speaker: TranscriptSpeaker, turns: [LiveCaptionTurn], startedAt: Date) {
        self.id = id
        self.speaker = speaker
        self.turns = turns
        self.startedAt = startedAt
    }

    public static func groups(from turns: [LiveCaptionTurn]) -> [LiveCaptionSpeakerGroup] {
        var groups: [LiveCaptionSpeakerGroup] = []
        for turn in turns {
            if let lastIndex = groups.indices.last,
               groups[lastIndex].speaker == turn.speaker {
                groups[lastIndex].turns.append(turn)
            } else {
                groups.append(LiveCaptionSpeakerGroup(id: turn.id, speaker: turn.speaker, turns: [turn], startedAt: turn.createdAt))
            }
        }
        return groups
    }
}

public enum LiveCaptionDisplayState: Equatable {
    case originalOnly(String)
    case translated(primaryText: String, sourceText: String)
    case pending(sourceText: String)
    case failed(sourceText: String, message: String)

    public init(turn: LiveCaptionTurn, secondLanguageEnabled: Bool) {
        let originalText = turn.originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let translatedText = turn.translatedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard secondLanguageEnabled else {
            self = .originalOnly(originalText)
            return
        }
        if !translatedText.isEmpty {
            self = .translated(primaryText: translatedText, sourceText: originalText)
            return
        }
        switch turn.translationHealth {
        case .failed(let message), .degraded(let message):
            self = .failed(sourceText: originalText, message: message)
        case .pending:
            self = .pending(sourceText: originalText)
        case .idle, .live:
            self = .originalOnly(originalText)
        }
    }

    public static func isSecondLanguageEnabled(
        sourceLocale: String,
        targetLocale: String,
        hasTranslatedText: Bool
    ) -> Bool {
        if hasTranslatedText {
            return true
        }
        let source = sourceLocale.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let target = targetLocale.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !source.isEmpty && !target.isEmpty && source != target
    }
}

public struct LiveCaptionStore: Equatable {
    public private(set) var turns: [LiveCaptionTurn] = []
    public private(set) var sourceLocale: String
    public private(set) var targetLocale: String

    public init(sourceLocale: String = "en-US", targetLocale: String = "zh-CN") {
        self.sourceLocale = sourceLocale
        self.targetLocale = targetLocale
    }

    @discardableResult
    public mutating func append(_ segment: TranscriptSegment) -> LiveCaptionTurn {
        let turn = LiveCaptionTurn(
            sourceSegmentID: segment.id,
            speaker: segment.speaker,
            originalText: segment.text,
            sourceLocale: segment.language ?? sourceLocale,
            targetLocale: targetLocale,
            isFinal: segment.isFinal,
            captionHealth: .live,
            translationHealth: .pending,
            createdAt: segment.createdAt,
            chunkState: segment.isFinal ? .frozen : .draft,
            translationRevision: 1,
            displayState: segment.isFinal ? .sealed : .draft,
            translationState: .draft,
            boundaryReason: nil,
            boundaryStrength: nil
        )
        if let representedIndex = turns.firstIndex(where: { $0.sourceSegmentIDs.contains(segment.id) }),
           turns[representedIndex].sourceSegmentIDs.count > 1 {
            return turns[representedIndex]
        }
        if let index = turns.firstIndex(where: { $0.sourceSegmentID == segment.id }) {
            let previousTurn = turns[index]
            var updated = turn
            if previousTurn.originalText == turn.originalText {
                updated.translatedText = previousTurn.translatedText
                updated.translationHealth = previousTurn.translationHealth
                updated.translationRevision = previousTurn.translationRevision
            } else {
                if previousTurn.chunkState == .draft,
                   turn.chunkState == .draft,
                   let translatedText = previousTurn.translatedText,
                   !translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    updated.translatedText = translatedText
                }
                updated.translationRevision = previousTurn.translationRevision + 1
            }
            turns[index] = updated
            return updated
        }
        if let index = provisionalMergeTargetIndex(for: turn) {
            turns[index] = mergedProvisionalTurn(turns[index], appending: turn)
            return turns[index]
        }
        if let index = mergeTargetIndex(for: turn) {
            turns[index] = mergedTurn(turns[index], appending: turn)
            return turns[index]
        }
        turns.append(turn)
        return turn
    }

    @discardableResult
    public mutating func upsert(_ turn: LiveCaptionTurn) -> LiveCaptionTurn {
        if let index = turns.firstIndex(where: { $0.id == turn.id }) {
            let previous = turns[index]
            var updated = turn
            if !((previous.translatedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
               updated.translatedText == nil {
                updated.translatedText = previous.translatedText
            }
            turns[index] = updated
            return updated
        }
        turns.append(turn)
        return turn
    }

    public mutating func removeNonFinalTurnsNotIn(segmentIDs: Set<String>) {
        turns.removeAll { !$0.isFinal && !segmentIDs.contains($0.sourceSegmentID) }
    }

    public mutating func remove(turnID: String) {
        turns.removeAll { $0.id == turnID }
    }

    @discardableResult
    public mutating func removeSourceSegment(
        _ segmentID: String,
        remainingSegments: [TranscriptSegment]
    ) -> LiveCaptionTurn? {
        var matchingIndex: Int?
        for index in turns.indices where turns[index].sourceSegmentIDs.contains(segmentID) {
            matchingIndex = index
            break
        }
        guard let index = matchingIndex else {
            remove(turnID: segmentID)
            return nil
        }

        var segmentsByID: [String: TranscriptSegment] = [:]
        for segment in remainingSegments {
            segmentsByID[segment.id] = segment
        }

        var representedSegments: [TranscriptSegment] = []
        for sourceSegmentID in turns[index].sourceSegmentIDs where sourceSegmentID != segmentID {
            if let segment = segmentsByID[sourceSegmentID] {
                representedSegments.append(segment)
            }
        }
        guard !representedSegments.isEmpty else {
            turns.remove(at: index)
            return nil
        }
        turns[index] = rebuiltTurn(
            from: representedSegments,
            preservingID: turns[index].id,
            previous: turns[index]
        )
        return turns[index]
    }

    @discardableResult
    public mutating func replaceRepresentedSegment(
        _ previousSegment: TranscriptSegment,
        with segment: TranscriptSegment,
        applying turn: LiveCaptionTurn
    ) -> LiveCaptionTurn {
        var matchingIndex: Int?
        for index in turns.indices
            where turns[index].sourceSegmentIDs.contains(segment.id)
                && turns[index].sourceSegmentIDs.count > 1 {
            matchingIndex = index
            break
        }
        guard let index = matchingIndex else {
            if segment.isFinal {
                return upsert(turn)
            }
            return append(segment)
        }

        var updated = turns[index]
        let previousText = updated.originalText
        updated.sourceSegmentID = segment.id
        if !updated.sourceSegmentIDs.contains(segment.id) {
            updated.sourceSegmentIDs.append(segment.id)
        }
        updated.originalText = replacedTranscriptText(
            in: updated.originalText,
            previous: previousSegment.text,
            replacement: segment.text
        )
        updated.sourceLocale = turn.sourceLocale
        updated.targetLocale = turn.targetLocale
        updated.isFinal = turn.isFinal
        updated.resetStableDisplayMetadata()
        updated.captionHealth = turn.captionHealth
        updated.translationHealth = turn.translationHealth
        updated.chunkState = turn.chunkState
        if previousText != updated.originalText {
            updated.translationRevision += 1
        }
        updated.freezeReason = turn.freezeReason
        updated.displayState = turn.displayState
        updated.translationState = turn.translationState
        updated.boundaryReason = turn.boundaryReason
        updated.boundaryStrength = turn.boundaryStrength
        turns[index] = updated
        return updated
    }

    private func mergeTargetIndex(for turn: LiveCaptionTurn) -> Int? {
        guard turn.isFinal,
              let lastIndex = turns.indices.last,
              turns[lastIndex].isFinal,
              turns[lastIndex].speaker == turn.speaker
        else {
            return nil
        }
        return lastIndex
    }

    private func provisionalMergeTargetIndex(for turn: LiveCaptionTurn) -> Int? {
        guard !turn.isFinal,
              let lastIndex = turns.indices.last,
              turns[lastIndex].speaker == turn.speaker,
              !turns[lastIndex].sourceSegmentIDs.contains(turn.sourceSegmentID),
              transcriptTextOverlapsOrContains(turns[lastIndex].originalText, turn.originalText)
        else {
            return nil
        }
        return lastIndex
    }

    private func mergedTurn(_ existing: LiveCaptionTurn, appending turn: LiveCaptionTurn) -> LiveCaptionTurn {
        var merged = existing
        merged.sourceSegmentID = turn.sourceSegmentID
        merged.sourceSegmentIDs.append(contentsOf: turn.sourceSegmentIDs)
        merged.originalText = joinedTranscriptText(existing.originalText, turn.originalText)
        merged.sourceLocale = turn.sourceLocale
        merged.targetLocale = turn.targetLocale
        merged.isFinal = turn.isFinal
        merged.resetStableDisplayMetadata()
        merged.captionHealth = turn.captionHealth
        merged.translationHealth = .pending
        merged.displayState = turn.displayState
        merged.translationState = turn.translationState
        merged.boundaryReason = turn.boundaryReason
        merged.boundaryStrength = turn.boundaryStrength
        return merged
    }

    private func mergedProvisionalTurn(_ existing: LiveCaptionTurn, appending turn: LiveCaptionTurn) -> LiveCaptionTurn {
        var merged = existing
        merged.sourceSegmentIDs.append(contentsOf: turn.sourceSegmentIDs.filter { !merged.sourceSegmentIDs.contains($0) })
        merged.originalText = joinedTranscriptText(existing.originalText, turn.originalText)
        merged.sourceLocale = turn.sourceLocale
        merged.targetLocale = turn.targetLocale
        merged.isFinal = false
        merged.resetStableDisplayMetadata()
        merged.captionHealth = turn.captionHealth
        merged.translationHealth = .pending
        merged.chunkState = .draft
        merged.translationRevision += 1
        merged.freezeReason = nil
        merged.displayState = .draft
        merged.translationState = .draft
        merged.boundaryReason = nil
        merged.boundaryStrength = nil
        return merged
    }

    private func joinedTranscriptText(_ first: String, _ second: String) -> String {
        let trimmedFirst = first.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecond = second.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedFirst.isEmpty {
            return trimmedSecond
        }
        if trimmedSecond.isEmpty {
            return trimmedFirst
        }
        if tokenSequence(normalizedTokens(trimmedFirst), contains: normalizedTokens(trimmedSecond)) {
            return trimmedFirst
        }
        if tokenSequence(normalizedTokens(trimmedSecond), contains: normalizedTokens(trimmedFirst)) {
            return trimmedSecond
        }
        let overlap = suffixPrefixOverlapCount(trimmedFirst, trimmedSecond)
        if overlap > 0 {
            let secondRemainder = droppingFirstWords(overlap, from: trimmedSecond)
            if secondRemainder.isEmpty {
                return trimmedFirst
            }
            return "\(trimmedFirst) \(secondRemainder)"
        }
        return "\(trimmedFirst) \(trimmedSecond)"
    }

    private func rebuiltTurn(
        from segments: [TranscriptSegment],
        preservingID id: String,
        previous: LiveCaptionTurn
    ) -> LiveCaptionTurn {
        var originalText = ""
        var sourceSegmentIDs: [String] = []
        var allSegmentsFinal = true
        for segment in segments {
            originalText = joinedTranscriptText(originalText, segment.text)
            sourceSegmentIDs.append(segment.id)
            if !segment.isFinal {
                allSegmentsFinal = false
            }
        }
        let lastSegment = segments[segments.count - 1]
        let boundaryReason: LiveCaptionFreezeReason? = lastSegment.speechFinal ? .speechFinal : nil
        let boundaryStrength = boundaryReason?.boundaryStrength
        let isSealed = boundaryStrength != nil
        let textChanged = originalText != previous.originalText
        return LiveCaptionTurn(
            id: id,
            sourceSegmentID: lastSegment.id,
            sourceSegmentIDs: sourceSegmentIDs,
            speaker: lastSegment.speaker,
            originalText: originalText,
            translatedText: textChanged ? nil : previous.translatedText,
            sourceLocale: lastSegment.language ?? sourceLocale,
            targetLocale: targetLocale,
            isFinal: allSegmentsFinal,
            captionHealth: .live,
            translationHealth: textChanged ? .pending : previous.translationHealth,
            createdAt: previous.createdAt,
            chunkState: isSealed ? .frozen : .draft,
            translationRevision: textChanged ? previous.translationRevision + 1 : previous.translationRevision,
            freezeReason: boundaryReason,
            displayState: isSealed ? .sealed : .draft,
            translationState: boundaryStrength == .hard ? .final : .draft,
            boundaryReason: boundaryReason,
            boundaryStrength: boundaryStrength
        )
    }

    private func replacedTranscriptText(in text: String, previous: String, replacement: String) -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrevious = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedText.isEmpty {
            return trimmedReplacement
        }
        if trimmedPrevious.isEmpty {
            return joinedTranscriptText(trimmedText, trimmedReplacement)
        }
        if let range = trimmedText.range(of: trimmedPrevious) {
            return String(trimmedText.replacingCharacters(in: range, with: trimmedReplacement))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return joinedTranscriptText(trimmedText, trimmedReplacement)
    }

    private func transcriptTextOverlapsOrContains(_ first: String, _ second: String) -> Bool {
        let firstTokens = normalizedTokens(first)
        let secondTokens = normalizedTokens(second)
        guard !firstTokens.isEmpty, !secondTokens.isEmpty else {
            return false
        }
        return tokenSequence(firstTokens, contains: secondTokens)
            || tokenSequence(secondTokens, contains: firstTokens)
            || suffixPrefixOverlapCount(first, second) > 0
    }

    private func suffixPrefixOverlapCount(_ first: String, _ second: String) -> Int {
        let firstTokens = normalizedTokens(first)
        let secondTokens = normalizedTokens(second)
        let maxOverlap = min(firstTokens.count, secondTokens.count)
        guard maxOverlap > 0 else {
            return 0
        }
        for overlap in stride(from: maxOverlap, through: 1, by: -1) {
            if Array(firstTokens.suffix(overlap)) == Array(secondTokens.prefix(overlap)) {
                return overlap
            }
        }
        return 0
    }

    private func tokenSequence(_ haystack: [String], contains needle: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else {
            return false
        }
        if needle.count == haystack.count {
            return haystack == needle
        }
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<(start + needle.count)]) == needle {
                return true
            }
        }
        return false
    }

    private func normalizedTokens(_ text: String) -> [String] {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private func droppingFirstWords(_ count: Int, from text: String) -> String {
        guard count > 0 else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        var remaining = count
        var index = text.startIndex
        var insideWord = false
        while index < text.endIndex {
            let scalar = text[index].unicodeScalars.first
            let isWord = scalar.map { CharacterSet.alphanumerics.contains($0) } ?? false
            if isWord {
                insideWord = true
            } else if insideWord {
                remaining -= 1
                insideWord = false
                if remaining == 0 {
                    return String(text[index...]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            index = text.index(after: index)
        }
        if insideWord {
            remaining -= 1
        }
        return remaining <= 0 ? "" : text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public mutating func attachTranslation(_ text: String, toTurnID turnID: String) {
        guard let index = turns.firstIndex(where: { $0.id == turnID }) else { return }
        turns[index].translatedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        turns[index].translationHealth = .live
    }

    public mutating func markTranslationPending(forTurnID turnID: String) {
        guard let index = turns.firstIndex(where: { $0.id == turnID }) else { return }
        turns[index].translationHealth = .pending
    }

    public mutating func appendTranslation(_ text: String, toTurnID turnID: String) {
        guard let index = turns.firstIndex(where: { $0.id == turnID }) else { return }
        turns[index].translatedText = joinedTranscriptText(turns[index].translatedText ?? "", text)
        turns[index].translationHealth = .live
    }

    public mutating func markTranslationCompleteWithoutText(forTurnID turnID: String) {
        guard let index = turns.firstIndex(where: { $0.id == turnID }) else { return }
        turns[index].translatedText = nil
        turns[index].translationHealth = .live
    }

    public mutating func markTranslationFailed(forTurnID turnID: String, message: String) {
        guard let index = turns.firstIndex(where: { $0.id == turnID }) else { return }
        turns[index].translationHealth = .failed(message)
    }

    public mutating func markTranslationFinal(forTurnID turnID: String) {
        guard let index = turns.firstIndex(where: { $0.id == turnID }) else { return }
        turns[index].translationState = .final
    }

    public mutating func reset(sourceLocale: String, targetLocale: String) {
        self.sourceLocale = sourceLocale
        self.targetLocale = targetLocale
        turns.removeAll()
    }
}

private extension LiveCaptionTurn {
    mutating func resetStableDisplayMetadata() {
        if isFinal {
            stableOriginalTextPrefix = originalText
            unstableOriginalTextTail = ""
        } else {
            stableOriginalTextPrefix = ""
            unstableOriginalTextTail = originalText
        }
    }
}

public struct LiveCaptionTranslationAdapter {
    private let provider: TextTranslationProvider

    public init(provider: TextTranslationProvider) {
        self.provider = provider
    }

    public func translate(turn: LiveCaptionTurn, in store: inout LiveCaptionStore) async throws {
        guard turn.isFinal else { return }
        let options = TranslationOptions(sourceLocale: turn.sourceLocale, targetLocale: turn.targetLocale)
        if options.isSameLanguage {
            store.markTranslationCompleteWithoutText(forTurnID: turn.id)
            return
        }
        let segment = TranscriptSegment(
            id: turn.sourceSegmentID,
            speaker: turn.speaker,
            text: turn.originalText,
            language: turn.sourceLocale,
            isFinal: turn.isFinal,
            createdAt: turn.createdAt
        )
        do {
            let translated = try await provider.translate(
                transcript: TranscriptDocument(segments: [segment]),
                options: options
            )
            let translatedText = translated.segments.first { $0.id == turn.sourceSegmentID }?.targetText ?? ""
            store.attachTranslation(translatedText, toTurnID: turn.id)
        } catch {
            let nsError = error as NSError
            store.markTranslationFailed(forTurnID: turn.id, message: "\(nsError.domain) error \(nsError.code)")
            throw error
        }
    }
}

public enum MeetingProgressStatus: String, Codable, Equatable {
    case notStarted
    case onTrack
    case partiallyCovered
    case blocked

    public var displayText: String {
        switch self {
        case .notStarted:
            return "not started"
        case .onTrack:
            return "on track"
        case .partiallyCovered:
            return "partially covered"
        case .blocked:
            return "blocked"
        }
    }
}

public enum MeetingObjectiveProgressStatus: String, Codable, Equatable {
    case pending
    case confirmed
    case unresolved
}

public struct MeetingObjectiveProgress: Codable, Equatable {
    public var objectiveID: String
    public var title: String
    public var status: MeetingObjectiveProgressStatus
    public var evidenceSegmentIDs: [String]

    public init(
        objectiveID: String,
        title: String,
        status: MeetingObjectiveProgressStatus,
        evidenceSegmentIDs: [String]
    ) {
        self.objectiveID = objectiveID
        self.title = title
        self.status = status
        self.evidenceSegmentIDs = evidenceSegmentIDs
    }
}

public struct FollowUpQuestionSuggestion: Codable, Equatable, Identifiable {
    public var id: String
    public var chinese: String
    public var english: String
    public var sourceObjectiveID: String?

    public init(id: String? = nil, chinese: String, english: String, sourceObjectiveID: String?) {
        self.english = english
        self.chinese = chinese
        self.sourceObjectiveID = sourceObjectiveID
        self.id = id ?? english
    }
}

public struct MeetingProgressHealth: Codable, Equatable {
    public var caption: LivePipelineHealth
    public var translation: LivePipelineHealth
    public var analysis: LivePipelineHealth

    public init(caption: LivePipelineHealth, translation: LivePipelineHealth, analysis: LivePipelineHealth) {
        self.caption = caption
        self.translation = translation
        self.analysis = analysis
    }
}

public struct MeetingProgressState: Codable, Equatable {
    public var schemaVersion: Int
    public var meetingID: UUID
    public var goal: MeetingGoal
    public var status: MeetingProgressStatus
    public var objectives: [MeetingObjectiveProgress]
    public var confirmedItems: [String]
    public var unresolvedItems: [String]
    public var suggestedQuestions: [FollowUpQuestionSuggestion]
    public var health: MeetingProgressHealth
    public var lastAnalyzedSegmentID: String?
    public var updatedAt: Date

    public init(
        schemaVersion: Int = 1,
        meetingID: UUID,
        goal: MeetingGoal,
        status: MeetingProgressStatus,
        objectives: [MeetingObjectiveProgress],
        confirmedItems: [String],
        unresolvedItems: [String],
        suggestedQuestions: [FollowUpQuestionSuggestion],
        health: MeetingProgressHealth,
        lastAnalyzedSegmentID: String?,
        updatedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.meetingID = meetingID
        self.goal = goal
        self.status = status
        self.objectives = objectives
        self.confirmedItems = confirmedItems
        self.unresolvedItems = unresolvedItems
        self.suggestedQuestions = suggestedQuestions
        self.health = health
        self.lastAnalyzedSegmentID = lastAnalyzedSegmentID
        self.updatedAt = updatedAt
    }
}

public protocol MeetingProgressAnalyzing {
    func analyze(
        goal: MeetingGoal,
        recentCaptions: [LiveCaptionTurn],
        previousState: MeetingProgressState?
    ) async throws -> MeetingProgressState
}

public protocol AgendaAwareMeetingProgressAnalyzing: MeetingProgressAnalyzing {
    func analyze(
        goal: MeetingGoal,
        agendaTopics: [MeetingAgendaTopic],
        recentCaptions: [LiveCaptionTurn],
        previousState: MeetingProgressState?
    ) async throws -> MeetingProgressState
}

public final class DeterministicMeetingProgressAnalyzer: AgendaAwareMeetingProgressAnalyzing {
    private let meetingID: UUID
    private let now: () -> Date

    public init(meetingID: UUID = UUID(), now: @escaping () -> Date = Date.init) {
        self.meetingID = meetingID
        self.now = now
    }

    public func analyze(
        goal: MeetingGoal,
        recentCaptions: [LiveCaptionTurn],
        previousState: MeetingProgressState?
    ) async throws -> MeetingProgressState {
        try await analyze(
            goal: goal,
            agendaTopics: [],
            recentCaptions: recentCaptions,
            previousState: previousState
        )
    }

    public func analyze(
        goal: MeetingGoal,
        agendaTopics: [MeetingAgendaTopic],
        recentCaptions: [LiveCaptionTurn],
        previousState: MeetingProgressState?
    ) async throws -> MeetingProgressState {
        let text = recentCaptions.map(\.originalText).joined(separator: " ").lowercased()
        let objectiveProgress = goal.objectives.map { objective in
            let terms = ([objective.title] + objective.keywords).map { $0.lowercased() }
            let matched = terms.contains { !text.isEmpty && text.contains($0) }
            return MeetingObjectiveProgress(
                objectiveID: objective.id,
                title: objective.title,
                status: matched ? .confirmed : .unresolved,
                evidenceSegmentIDs: matched ? recentCaptions.map(\.sourceSegmentID) : []
            )
        }
        let confirmed = objectiveProgress.filter { $0.status == .confirmed }.map(\.title)
        let unresolved = objectiveProgress.filter { $0.status == .unresolved }.map(\.title)
        let status: MeetingProgressStatus
        if objectiveProgress.isEmpty {
            status = .onTrack
        } else if confirmed.isEmpty {
            status = .notStarted
        } else if unresolved.isEmpty {
            status = .onTrack
        } else {
            status = .partiallyCovered
        }
        let questions = Self.recommendedQuestions(
            from: objectiveProgress,
            agendaTopics: agendaTopics,
            transcriptText: text
        )
        return MeetingProgressState(
            meetingID: previousState?.meetingID ?? meetingID,
            goal: goal,
            status: status,
            objectives: objectiveProgress,
            confirmedItems: confirmed,
            unresolvedItems: unresolved,
            suggestedQuestions: Array(questions),
            health: MeetingProgressHealth(caption: .live, translation: .pending, analysis: .live),
            lastAnalyzedSegmentID: recentCaptions.last?.sourceSegmentID ?? previousState?.lastAnalyzedSegmentID,
            updatedAt: now()
        )
    }

    private static func recommendedQuestions(
        from objectiveProgress: [MeetingObjectiveProgress],
        agendaTopics: [MeetingAgendaTopic],
        transcriptText: String
    ) -> [FollowUpQuestionSuggestion] {
        let unresolvedObjectiveQuestions = objectiveProgress
            .filter { $0.status != .confirmed }
            .compactMap { progress -> FollowUpQuestionSuggestion? in
                let title = normalized(progress.title)
                guard !title.isEmpty else { return nil }
                return FollowUpQuestionSuggestion(
                    chinese: chinesePrompt(for: title),
                    english: englishPrompt(for: title),
                    sourceObjectiveID: progress.objectiveID
                )
            }
        if !unresolvedObjectiveQuestions.isEmpty {
            return Array(unresolvedObjectiveQuestions.prefix(2))
        }

        let topicQuestions = agendaTopics.compactMap { topic -> FollowUpQuestionSuggestion? in
            let title = normalized(topic.title)
            guard !title.isEmpty,
                  !transcriptText.contains(title.lowercased())
            else {
                return nil
            }
            return FollowUpQuestionSuggestion(
                chinese: chinesePrompt(for: title),
                english: englishPrompt(for: title),
                sourceObjectiveID: nil
            )
        }
        return Array(topicQuestions.prefix(2))
    }

    private static func normalized(_ value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func englishPrompt(for topic: String) -> String {
        "Could we clarify \(questionSubject(for: topic))?"
    }

    private static func chinesePrompt(for topic: String) -> String {
        "可以进一步确认\(questionSubject(for: topic))吗？"
    }

    private static func questionSubject(for topic: String) -> String {
        let prefixes = ["Confirm ", "Decide ", "Review ", "Align on ", "Clarify "]
        for prefix in prefixes where topic.range(
            of: prefix,
            options: [.caseInsensitive, .anchored]
        ) != nil {
            return String(topic.dropFirst(prefix.count))
        }
        return topic
    }
}

public final class MeetingProgressCoordinator {
    private let goal: MeetingGoal
    private let agendaTopics: [MeetingAgendaTopic]
    private let analyzer: MeetingProgressAnalyzing
    private let progressURL: URL
    private let minimumAnalysisInterval: TimeInterval
    private let now: () -> Date
    private var lastAnalyzedAt: Date?

    public private(set) var state: MeetingProgressState?
    public private(set) var analysisHealth: LivePipelineHealth = .idle

    public init(
        goal: MeetingGoal,
        agendaTopics: [MeetingAgendaTopic] = [],
        analyzer: MeetingProgressAnalyzing,
        progressURL: URL,
        minimumAnalysisInterval: TimeInterval = 30,
        now: @escaping () -> Date = Date.init
    ) {
        self.goal = goal
        self.agendaTopics = agendaTopics
        self.analyzer = analyzer
        self.progressURL = progressURL
        self.minimumAnalysisInterval = minimumAnalysisInterval
        self.now = now
    }

    public func process(turns: [LiveCaptionTurn]) async {
        let finalTurns = turns.filter(\.isFinal)
        let newTurns = turnsAfterLastAnalyzed(in: finalTurns)
        guard !newTurns.isEmpty else { return }
        let currentTime = now()
        if let lastAnalyzedAt, currentTime.timeIntervalSince(lastAnalyzedAt) < minimumAnalysisInterval {
            return
        }
        analysisHealth = .pending
        do {
            let nextState: MeetingProgressState
            if let agendaAwareAnalyzer = analyzer as? AgendaAwareMeetingProgressAnalyzing {
                nextState = try await agendaAwareAnalyzer.analyze(
                    goal: goal,
                    agendaTopics: agendaTopics,
                    recentCaptions: newTurns,
                    previousState: state
                )
            } else {
                nextState = try await analyzer.analyze(
                    goal: goal,
                    recentCaptions: newTurns,
                    previousState: state
                )
            }
            state = nextState
            lastAnalyzedAt = currentTime
            analysisHealth = .live
            try persist(nextState)
        } catch {
            let nsError = error as NSError
            analysisHealth = .failed("\(nsError.domain) error \(nsError.code)")
        }
    }

    private func turnsAfterLastAnalyzed(in turns: [LiveCaptionTurn]) -> [LiveCaptionTurn] {
        guard let lastAnalyzedSegmentID = state?.lastAnalyzedSegmentID,
              let index = turns.lastIndex(where: { $0.sourceSegmentID == lastAnalyzedSegmentID })
        else {
            return turns
        }
        return Array(turns.dropFirst(index + 1))
    }

    private func persist(_ state: MeetingProgressState) throws {
        let directory = progressURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.meetingAgent.encode(state)
        try data.write(to: progressURL, options: .atomic)
    }
}

public final class TranscriptFixtureReplay {
    private let segments: [TranscriptSegment]
    private let failureAfterSegmentID: String?

    public private(set) var failureHealth: LivePipelineHealth = .idle

    public init(segments: [TranscriptSegment], failureAfterSegmentID: String? = nil) {
        self.segments = segments
        self.failureAfterSegmentID = failureAfterSegmentID
    }

    public func run(_ handle: (TranscriptSegment) async -> Void) async {
        for segment in segments where segment.isFinal {
            await handle(segment)
            if segment.id == failureAfterSegmentID {
                failureHealth = .failed("Replay stopped after \(segment.id)")
                return
            }
        }
        failureHealth = .live
    }
}

public struct GoalOrientedSummaryProvider {
    public init() {}

    public func generate(
        transcript: TranscriptDocument,
        progress: MeetingProgressState?,
        generatedAt: Date = Date()
    ) -> MeetingSummary {
        let sourceSegmentIDs = transcript.segments.map(\.id)
        guard let progress else {
            return MeetingSummary(
                autoGeneratedTitle: MeetingSummaryTitleGenerator.title(
                    meetingName: "",
                    keyTopics: [],
                    overview: "No meeting progress snapshot was available",
                    segments: transcript.segments
                ),
                overview: "No meeting progress snapshot was available. Summary is based on transcript only.",
                keyTopics: [],
                decisions: [],
                actionItems: [],
                openQuestions: [],
                risks: [],
                followUps: [],
                language: transcript.segments.compactMap(\.language).first,
                sourceSegmentIDs: sourceSegmentIDs,
                generatedAt: generatedAt,
                provider: "goal-oriented-deterministic",
                status: .succeeded,
                failureReason: nil
            )
        }
        return MeetingSummary(
            autoGeneratedTitle: MeetingSummaryTitleGenerator.title(
                meetingName: progress.goal.title,
                keyTopics: [progress.goal.title],
                overview: progress.goal.title,
                segments: transcript.segments
            ),
            overview: "Goal: \(progress.goal.title). Current status: \(progress.status.displayText).",
            keyTopics: ["Goal status: \(progress.status.displayText)"],
            decisions: progress.confirmedItems.map {
                MeetingDecision(description: $0, participants: [], sourceSegmentIDs: sourceSegmentIDs, confidence: 0.8)
            },
            actionItems: [],
            openQuestions: progress.unresolvedItems,
            risks: [],
            followUps: progress.suggestedQuestions.map(\.english),
            language: transcript.segments.compactMap(\.language).first,
            sourceSegmentIDs: sourceSegmentIDs,
            generatedAt: generatedAt,
            provider: "goal-oriented-deterministic",
            status: .succeeded,
            failureReason: nil
        )
    }
}
