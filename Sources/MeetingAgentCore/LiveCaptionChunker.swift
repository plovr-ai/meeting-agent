import Foundation

public struct LiveCaptionChunkingPolicy: Equatable {
    public var maxCharacters: Int
    public var maxDurationSeconds: Double
    public var minPunctuationCharacters: Int
    public var readableCharacterLimit: Int
    public var shortFragmentCharacters: Int
    public var maxMergeGapSeconds: Double
    public var minSentenceBoundaryCharacters: Int

    public init(
        maxCharacters: Int = 240,
        maxDurationSeconds: Double = 10,
        minPunctuationCharacters: Int = 80,
        readableCharacterLimit: Int = 140,
        shortFragmentCharacters: Int = 24,
        maxMergeGapSeconds: Double = 1.25,
        minSentenceBoundaryCharacters: Int = 36
    ) {
        self.maxCharacters = maxCharacters
        self.maxDurationSeconds = maxDurationSeconds
        self.minPunctuationCharacters = minPunctuationCharacters
        self.readableCharacterLimit = readableCharacterLimit
        self.shortFragmentCharacters = shortFragmentCharacters
        self.maxMergeGapSeconds = maxMergeGapSeconds
        self.minSentenceBoundaryCharacters = minSentenceBoundaryCharacters
    }
}

public struct LiveCaptionChunkUpdate: Equatable {
    public let turn: LiveCaptionTurn

    public init(turn: LiveCaptionTurn) {
        self.turn = turn
    }
}

public struct LiveCaptionChunker: Equatable {
    private var openChunk: OpenChunk?
    private let policy: LiveCaptionChunkingPolicy
    private let sourceLocale: String
    private let targetLocale: String

    public init(
        sourceLocale: String,
        targetLocale: String,
        policy: LiveCaptionChunkingPolicy = LiveCaptionChunkingPolicy()
    ) {
        self.sourceLocale = sourceLocale
        self.targetLocale = targetLocale
        self.policy = policy
    }

    public mutating func append(_ segment: TranscriptSegment) -> [LiveCaptionChunkUpdate] {
        guard segment.isFinal else { return [] }
        var updates: [LiveCaptionChunkUpdate] = []

        if let openChunk, openChunk.turn.speaker != segment.speaker {
            updates.append(LiveCaptionChunkUpdate(turn: frozen(openChunk.turn, reason: .speakerChanged)))
            self.openChunk = nil
        }

        let chunk = mergedChunk(appending: segment)
        openChunk = chunk
        updates.append(LiveCaptionChunkUpdate(turn: chunk.turn))

        if let reason = freezeReason(for: chunk, latestSegment: segment) {
            let final = frozen(chunk.turn, reason: reason)
            openChunk = nil
            updates.append(LiveCaptionChunkUpdate(turn: final))
        }

        return updates
    }

    public mutating func flushOpenChunk(reason: LiveCaptionFreezeReason) -> [LiveCaptionChunkUpdate] {
        guard let openChunk else { return [] }
        self.openChunk = nil
        return [LiveCaptionChunkUpdate(turn: frozen(openChunk.turn, reason: reason))]
    }

    private func mergedChunk(appending segment: TranscriptSegment) -> OpenChunk {
        if let openChunk {
            if openChunk.turn.sourceSegmentIDs == [segment.id] {
                let draft = LiveCaptionTurn(
                    id: openChunk.turn.id,
                    sourceSegmentID: segment.id,
                    sourceSegmentIDs: [segment.id],
                    speaker: segment.speaker,
                    originalText: segment.text,
                    translatedText: openChunk.turn.translatedText,
                    sourceLocale: segment.language ?? sourceLocale,
                    targetLocale: targetLocale,
                    isFinal: true,
                    captionHealth: .live,
                    translationHealth: .pending,
                    createdAt: segment.createdAt,
                    chunkState: .draft,
                    translationRevision: openChunk.turn.translationRevision + 1,
                    freezeReason: nil,
                    displayState: .draft,
                    translationState: .draft,
                    boundaryReason: nil,
                    boundaryStrength: nil
                )
                let startTimeSeconds: Double?
                switch (openChunk.startTimeSeconds, segment.startTimeSeconds) {
                case let (first?, second?):
                    startTimeSeconds = min(first, second)
                case let (first?, nil):
                    startTimeSeconds = first
                case let (nil, second?):
                    startTimeSeconds = second
                case (nil, nil):
                    startTimeSeconds = nil
                }
                let endTimeSeconds: Double?
                switch (openChunk.endTimeSeconds, segment.endTimeSeconds) {
                case let (first?, second?):
                    endTimeSeconds = max(first, second)
                case let (first?, nil):
                    endTimeSeconds = first
                case let (nil, second?):
                    endTimeSeconds = second
                case (nil, nil):
                    endTimeSeconds = nil
                }
                return OpenChunk(
                    turn: draft,
                    startTimeSeconds: startTimeSeconds,
                    endTimeSeconds: endTimeSeconds,
                    previousEndTimeSeconds: openChunk.previousEndTimeSeconds
                )
            }

            let previousEndTimeSeconds = openChunk.endTimeSeconds
            let draft = LiveCaptionTurn(
                id: openChunk.turn.id,
                sourceSegmentID: segment.id,
                sourceSegmentIDs: openChunk.turn.sourceSegmentIDs + [segment.id],
                speaker: segment.speaker,
                originalText: joined(openChunk.turn.originalText, segment.text),
                translatedText: openChunk.turn.translatedText,
                sourceLocale: segment.language ?? sourceLocale,
                targetLocale: targetLocale,
                isFinal: true,
                captionHealth: .live,
                translationHealth: .pending,
                createdAt: segment.createdAt,
                chunkState: .draft,
                translationRevision: openChunk.turn.translationRevision + 1,
                freezeReason: nil,
                displayState: .draft,
                translationState: .draft,
                boundaryReason: nil,
                boundaryStrength: nil
            )
            return OpenChunk(
                turn: draft,
                startTimeSeconds: [openChunk.startTimeSeconds, segment.startTimeSeconds].compactMap { $0 }.min(),
                endTimeSeconds: [openChunk.endTimeSeconds, segment.endTimeSeconds].compactMap { $0 }.max(),
                previousEndTimeSeconds: previousEndTimeSeconds
            )
        }

        let draft = LiveCaptionTurn(
            sourceSegmentID: segment.id,
            speaker: segment.speaker,
            originalText: segment.text,
            sourceLocale: segment.language ?? sourceLocale,
            targetLocale: targetLocale,
            isFinal: true,
            captionHealth: .live,
            translationHealth: .pending,
            createdAt: segment.createdAt,
            chunkState: .draft,
            translationRevision: 1,
            freezeReason: nil,
            displayState: .draft,
            translationState: .draft,
            boundaryReason: nil,
            boundaryStrength: nil
        )
        return OpenChunk(
            turn: draft,
            startTimeSeconds: segment.startTimeSeconds,
            endTimeSeconds: segment.endTimeSeconds,
            previousEndTimeSeconds: nil
        )
    }

    private func freezeReason(for chunk: OpenChunk, latestSegment: TranscriptSegment) -> LiveCaptionFreezeReason? {
        if latestSegment.speechFinal { return .speechFinal }
        if chunk.turn.originalText.count >= policy.maxCharacters { return .maxLength }
        if durationSeconds(for: chunk) >= policy.maxDurationSeconds,
           hasSentenceEndingPunctuation(chunk.turn.originalText) {
            return .maxDuration
        }
        if chunk.turn.originalText.count >= sentenceBoundaryCharacterLimit(for: chunk.turn.originalText),
           hasSentenceEndingPunctuation(chunk.turn.originalText),
           !shouldKeepMergingShortFragment(chunk, latestSegment: latestSegment) {
            return .punctuation
        }
        if chunk.turn.originalText.count >= policy.readableCharacterLimit,
           !shouldKeepMergingShortFragment(chunk, latestSegment: latestSegment) {
            return .maxLength
        }
        return nil
    }

    private func durationSeconds(for chunk: OpenChunk) -> Double {
        guard let start = chunk.startTimeSeconds,
              let end = chunk.endTimeSeconds
        else {
            return 0
        }
        return max(0, end - start)
    }

    private func shouldKeepMergingShortFragment(_ chunk: OpenChunk, latestSegment: TranscriptSegment) -> Bool {
        guard chunk.turn.sourceSegmentIDs.count > 1 else { return false }
        let latestText = latestSegment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard latestText.count <= policy.shortFragmentCharacters else {
            return false
        }
        guard let previousEnd = chunk.previousEndTimeSeconds,
              let latestStart = latestSegment.startTimeSeconds
        else {
            return false
        }
        return max(0, latestStart - previousEnd) <= policy.maxMergeGapSeconds
    }

    private func sentenceBoundaryCharacterLimit(for text: String) -> Int {
        let configuredLimit = min(policy.minPunctuationCharacters, policy.minSentenceBoundaryCharacters)
        if containsCJKCharacter(text) {
            return max(12, configuredLimit / 2)
        }
        return configuredLimit
    }

    private func containsCJKCharacter(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let value = Int(scalar.value)
            return (0x4E00...0x9FFF).contains(value)
                || (0x3040...0x30FF).contains(value)
                || (0xAC00...0xD7AF).contains(value)
        }
    }

    private func frozen(_ turn: LiveCaptionTurn, reason: LiveCaptionFreezeReason) -> LiveCaptionTurn {
        let strength = reason.boundaryStrength
        return LiveCaptionTurn(
            id: turn.id,
            sourceSegmentID: turn.sourceSegmentID,
            sourceSegmentIDs: turn.sourceSegmentIDs,
            speaker: turn.speaker,
            originalText: turn.originalText,
            translatedText: turn.translatedText,
            sourceLocale: turn.sourceLocale,
            targetLocale: turn.targetLocale,
            isFinal: true,
            captionHealth: turn.captionHealth,
            translationHealth: .pending,
            createdAt: turn.createdAt,
            chunkState: .frozen,
            translationRevision: turn.translationRevision,
            freezeReason: reason,
            displayState: .sealed,
            translationState: strength == .hard ? .final : .draft,
            boundaryReason: reason,
            boundaryStrength: strength
        )
    }

    private func joined(_ first: String, _ second: String) -> String {
        let first = first.trimmingCharacters(in: .whitespacesAndNewlines)
        let second = second.trimmingCharacters(in: .whitespacesAndNewlines)
        if first.isEmpty { return second }
        if second.isEmpty { return first }
        if let overlap = suffixPrefixOverlap(first, second), overlap >= 2 {
            let trimmedSecond = removingPrefixTokenCount(overlap, from: second)
            if trimmedSecond.isEmpty { return first }
            return "\(first) \(trimmedSecond)"
        }
        return "\(first) \(second)"
    }

    private func suffixPrefixOverlap(_ first: String, _ second: String) -> Int? {
        let firstTokens = normalizedTokens(first)
        let secondTokens = normalizedTokens(second)
        let maxOverlap = min(firstTokens.count, secondTokens.count)
        guard maxOverlap > 0 else { return nil }
        for candidate in stride(from: maxOverlap, through: 1, by: -1) {
            if Array(firstTokens.suffix(candidate)) == Array(secondTokens.prefix(candidate)) {
                return candidate
            }
        }
        return nil
    }

    private func normalizedTokens(_ text: String) -> [String] {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private func removingPrefixTokenCount(_ count: Int, from text: String) -> String {
        guard count > 0 else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        var remaining = count
        var index = text.startIndex
        var insideToken = false
        while index < text.endIndex {
            let scalar = text[index].unicodeScalars.first
            let isToken = scalar.map { CharacterSet.alphanumerics.contains($0) } ?? false
            if isToken {
                insideToken = true
            } else if insideToken {
                remaining -= 1
                insideToken = false
                if remaining == 0 {
                    return trimmingLeadingBoundary(from: String(text[index...]))
                }
            }
            index = text.index(after: index)
        }
        if remaining <= 1, insideToken {
            return ""
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func trimmingLeadingBoundary(from text: String) -> String {
        let boundary = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.;:!?"))
        var start = text.startIndex
        while start < text.endIndex {
            let scalar = text[start].unicodeScalars.first
            guard scalar.map({ boundary.contains($0) }) == true else { break }
            start = text.index(after: start)
        }
        return String(text[start...])
    }

    private func hasSentenceEndingPunctuation(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return false }
        return [".", "!", "?", "。", "！", "？"].contains(String(last))
    }

    private struct OpenChunk: Equatable {
        var turn: LiveCaptionTurn
        var startTimeSeconds: Double?
        var endTimeSeconds: Double?
        var previousEndTimeSeconds: Double?
    }
}
