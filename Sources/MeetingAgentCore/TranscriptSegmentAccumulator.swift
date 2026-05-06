import Foundation

public enum TranscriptSegmentUpdate: Equatable {
    case upsert(TranscriptSegment)
    case replaceAll([TranscriptSegment])
    case replaceWithPlainText(String)
    case translationPatch(segmentID: String, text: String, targetLocale: String, isFinal: Bool)
}

public enum TranscriptSegmentUpdateSource: String, Codable, Equatable {
    case final
    case realtime
}

public struct TranscriptSegmentAccumulationResult: Equatable {
    public let document: TranscriptDocument
    public let changedSegmentIDs: [String]
    public let plainTextReplacement: String?
    public let source: TranscriptSegmentUpdateSource

    public init(
        document: TranscriptDocument,
        changedSegmentIDs: [String],
        plainTextReplacement: String?,
        source: TranscriptSegmentUpdateSource = .final
    ) {
        self.document = document
        self.changedSegmentIDs = changedSegmentIDs
        self.plainTextReplacement = plainTextReplacement
        self.source = source
    }
}

public struct TranscriptSegmentAccumulator {
    private var document: TranscriptDocument

    public init(document: TranscriptDocument = TranscriptDocument()) {
        self.document = document
    }

    public var currentDocument: TranscriptDocument {
        document
    }

    @discardableResult
    public mutating func apply(_ update: TranscriptSegmentUpdate) -> TranscriptSegmentAccumulationResult {
        switch update {
        case .upsert(let segment):
            return applyUpsert(segment)
        case .replaceAll(let segments):
            document = TranscriptDocument(version: document.version, segments: segments)
            return TranscriptSegmentAccumulationResult(
                document: document,
                changedSegmentIDs: segments.map(\.id),
                plainTextReplacement: nil
            )
        case .replaceWithPlainText(let text):
            document = TranscriptDocument(version: document.version, segments: [])
            return TranscriptSegmentAccumulationResult(
                document: document,
                changedSegmentIDs: [],
                plainTextReplacement: text
            )
        case .translationPatch(let segmentID, let text, let targetLocale, let isFinal):
            return applyTranslationPatch(
                segmentID: segmentID,
                text: text,
                targetLocale: targetLocale,
                isFinal: isFinal
            )
        }
    }

    private mutating func applyTranslationPatch(
        segmentID: String,
        text: String,
        targetLocale: String,
        isFinal: Bool
    ) -> TranscriptSegmentAccumulationResult {
        let normalizedSegmentID = segmentID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTargetLocale = targetLocale.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = document.segments.firstIndex(where: { $0.id == normalizedSegmentID }) else {
            return TranscriptSegmentAccumulationResult(
                document: document,
                changedSegmentIDs: [],
                plainTextReplacement: nil
            )
        }
        let segment = document.segments[index]
        document.segments[index] = TranscriptSegment(
            id: segment.id,
            speaker: segment.speaker,
            startTimeSeconds: segment.startTimeSeconds,
            endTimeSeconds: segment.endTimeSeconds,
            text: segment.text,
            language: segment.language,
            sourceProvider: segment.sourceProvider,
            isFinal: segment.isFinal,
            speechFinal: segment.speechFinal,
            confidence: segment.confidence,
            createdAt: segment.createdAt,
            timingSource: segment.timingSource,
            translatedText: normalizedText,
            translationTargetLocale: normalizedTargetLocale,
            translationIsFinal: isFinal
        )
        return TranscriptSegmentAccumulationResult(
            document: document,
            changedSegmentIDs: [normalizedSegmentID],
            plainTextReplacement: nil
        )
    }

    private mutating func applyUpsert(_ segment: TranscriptSegment) -> TranscriptSegmentAccumulationResult {
        let previousIDs = Set(document.segments.map(\.id))
        if let index = document.segments.firstIndex(where: { $0.id == segment.id }) {
            document.segments[index] = Self.segment(segment, preservingTranslationFrom: document.segments[index])
            document.segments.removeAll {
                $0.id != segment.id && Self.shouldReplaceExistingSegment($0, with: segment)
            }
        } else {
            if document.segments.contains(where: { Self.shouldKeepExistingSegment($0, insteadOf: segment) }) {
                return TranscriptSegmentAccumulationResult(
                    document: document,
                    changedSegmentIDs: [],
                    plainTextReplacement: nil
                )
            }
            document.segments.removeAll { Self.shouldReplaceExistingSegment($0, with: segment) }
            document.segments.append(segment)
        }
        document.segments = Self.trimmedCoveredInterimPrefixes(document.segments)
        document.segments = Self.prunedCoveredInterimSegments(document.segments)
        document.segments = Self.deduplicatedAdjacentOverlaps(
            document.segments,
            trimFinalPrefixes: !Self.isDeepgramFinalProtocolSegment(segment)
        )
        let newIDs = Set(document.segments.map(\.id))
        let changed = Array(previousIDs.symmetricDifference(newIDs).union([segment.id])).sorted()
        return TranscriptSegmentAccumulationResult(
            document: document,
            changedSegmentIDs: changed,
            plainTextReplacement: nil
        )
    }

    private static func shouldKeepExistingSegment(_ existing: TranscriptSegment, insteadOf incoming: TranscriptSegment) -> Bool {
        if existing.isFinal,
           !incoming.isFinal,
           finalSegmentCoversInterim(existing, incoming) {
            return true
        }
        return existing.isFinal
            && !incoming.isFinal
            && describesSameStreamingUtterance(existing, incoming)
    }

    private static func shouldReplaceExistingSegment(_ existing: TranscriptSegment, with incoming: TranscriptSegment) -> Bool {
        if incoming.isFinal,
           !existing.isFinal,
           finalSegmentCoversInterim(incoming, existing) {
            return true
        }
        if incoming.sourceProvider == SpeechTranscriptionConfiguration.defaultDeepgramTranscriptionProviderID,
           existing.sourceProvider == incoming.sourceProvider,
           incoming.isFinal,
           existing.isFinal,
           speakersAreCompatible(existing.speaker, incoming.speaker),
           segmentsOverlap(existing, incoming) {
            return true
        }
        guard describesSameStreamingUtterance(existing, incoming) else { return false }
        if incoming.isFinal && !existing.isFinal {
            return true
        }
        if !incoming.isFinal && !existing.isFinal {
            return true
        }
        return false
    }

    private static func describesSameStreamingUtterance(_ first: TranscriptSegment, _ second: TranscriptSegment) -> Bool {
        guard first.sourceProvider == second.sourceProvider,
              speakersAreCompatible(first.speaker, second.speaker),
              segmentsOverlap(first, second)
        else {
            return false
        }
        if first.sourceProvider == SpeechTranscriptionConfiguration.defaultDeepgramTranscriptionProviderID {
            return first.isFinal && second.isFinal
                || normalizedTextsOverlap(first.text, second.text)
        }
        return normalizedTextsOverlap(first.text, second.text)
    }

    private static func isDeepgramFinalProtocolSegment(_ segment: TranscriptSegment) -> Bool {
        segment.sourceProvider == SpeechTranscriptionConfiguration.defaultDeepgramTranscriptionProviderID
            && segment.isFinal
    }

    private static func finalSegmentCoversInterim(_ final: TranscriptSegment, _ interim: TranscriptSegment) -> Bool {
        guard final.sourceProvider == interim.sourceProvider,
              let finalStart = final.startTimeSeconds,
              let finalEnd = final.endTimeSeconds,
              let interimStart = interim.startTimeSeconds,
              let interimEnd = interim.endTimeSeconds
        else {
            return false
        }
        let tolerance = 0.25
        let coversTiming = finalStart <= interimStart + tolerance
            && finalEnd + tolerance >= interimEnd
        guard coversTiming else { return false }
        if final.sourceProvider == SpeechTranscriptionConfiguration.defaultDeepgramTranscriptionProviderID {
            return true
        }
        return speakersAreCompatible(final.speaker, interim.speaker)
            || normalizedTextsOverlap(final.text, interim.text)
    }

    private static func prunedCoveredInterimSegments(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        let finalSegments = segments.filter(\.isFinal)
        guard !finalSegments.isEmpty else { return segments }
        return segments.filter { segment in
            guard !segment.isFinal else { return true }
            return !finalSegmentsCoverInterim(finalSegments, segment)
        }
    }

    private static func trimmedCoveredInterimPrefixes(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var finalSegments: [TranscriptSegment] = []
        for segment in segments where segment.isFinal {
            finalSegments.append(segment)
        }
        guard !finalSegments.isEmpty else { return segments }
        var output: [TranscriptSegment] = []
        segmentLoop:
        for segment in segments {
            guard !segment.isFinal else {
                output.append(segment)
                continue
            }
            var current = segment
            for final in finalSegments {
                guard final.sourceProvider == current.sourceProvider,
                      let finalStart = final.startTimeSeconds,
                      let finalEnd = final.endTimeSeconds,
                      let interimStart = current.startTimeSeconds,
                      let interimEnd = current.endTimeSeconds
                else {
                    continue
                }
                let tolerance = 0.25
                guard finalStart <= interimStart + tolerance,
                      finalEnd > interimStart + tolerance,
                      finalEnd < interimEnd + tolerance
                else {
                    continue
                }
                let normalizedFirstTokens = normalizedTokens(final.text)
                let normalizedSecondTokens = normalizedTokens(current.text)
                let maxOverlap = min(normalizedFirstTokens.count, normalizedSecondTokens.count)
                var overlap = 0
                if maxOverlap > 0 {
                    for candidate in stride(from: maxOverlap, through: 1, by: -1) {
                        if Array(normalizedFirstTokens.suffix(candidate)) == Array(normalizedSecondTokens.prefix(candidate)) {
                            overlap = candidate
                            break
                        }
                    }
                }
                guard overlap >= 2,
                      speakersAreCompatible(final.speaker, current.speaker) || overlap >= 3
                else {
                    continue
                }
                var remaining = overlap
                var index = current.text.startIndex
                var insideWord = false
                var remainder = ""
                while index < current.text.endIndex {
                    let scalar = current.text[index].unicodeScalars.first
                    let isWord = scalar.map { CharacterSet.alphanumerics.contains($0) } ?? false
                    if isWord {
                        insideWord = true
                    } else if insideWord {
                        remaining -= 1
                        insideWord = false
                        if remaining == 0 {
                            remainder = String(current.text[index...])
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            break
                        }
                    }
                    index = current.text.index(after: index)
                }
                if remainder.isEmpty, insideWord {
                    remaining -= 1
                }
                let text = (remaining <= 0 ? remainder : current.text)
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.;:!?")))
                guard !text.isEmpty else { continue segmentLoop }
                current = TranscriptSegment(
                    id: current.id,
                    speaker: current.speaker,
                    startTimeSeconds: max(interimStart, min(finalEnd, interimEnd)),
                    endTimeSeconds: current.endTimeSeconds,
                    text: text,
                    language: current.language,
                    sourceProvider: current.sourceProvider,
                    isFinal: current.isFinal,
                    speechFinal: current.speechFinal,
                    confidence: current.confidence,
                    createdAt: current.createdAt,
                    timingSource: current.timingSource,
                    translatedText: current.translatedText,
                    translationTargetLocale: current.translationTargetLocale,
                    translationIsFinal: current.translationIsFinal
                )
            }
            output.append(current)
        }
        return output
    }

    private static func finalSegmentsCoverInterim(_ finalSegments: [TranscriptSegment], _ interim: TranscriptSegment) -> Bool {
        guard let interimStart = interim.startTimeSeconds,
              let interimEnd = interim.endTimeSeconds
        else {
            return false
        }
        let tolerance = 0.25
        let candidates = finalSegments
            .filter { final in
                guard final.sourceProvider == interim.sourceProvider,
                      let finalStart = final.startTimeSeconds,
                      let finalEnd = final.endTimeSeconds
                else {
                    return false
                }
                return finalStart <= interimEnd + tolerance
                    && finalEnd + tolerance >= interimStart
            }
            .sorted {
                ($0.startTimeSeconds ?? 0) < ($1.startTimeSeconds ?? 0)
            }
        guard let first = candidates.first,
              let firstStart = first.startTimeSeconds,
              firstStart <= interimStart + tolerance
        else {
            return false
        }
        var coveredEnd = first.endTimeSeconds ?? firstStart
        for final in candidates.dropFirst() {
            guard let finalStart = final.startTimeSeconds,
                  let finalEnd = final.endTimeSeconds,
                  finalStart <= coveredEnd + tolerance
            else {
                break
            }
            coveredEnd = max(coveredEnd, finalEnd)
        }
        guard coveredEnd + tolerance >= interimEnd else { return false }
        if candidates.allSatisfy({ $0.sourceProvider == SpeechTranscriptionConfiguration.defaultDeepgramTranscriptionProviderID }) {
            return true
        }
        let combinedFinalText = candidates.map(\.text).joined(separator: " ")
        return normalizedTextsOverlap(combinedFinalText, interim.text)
    }

    private static func deduplicatedAdjacentOverlaps(
        _ segments: [TranscriptSegment],
        trimFinalPrefixes: Bool = true
    ) -> [TranscriptSegment] {
        guard segments.count > 1 else { return segments }
        var segments = segments
        segments = trimmedInterimPrefixesCoveredByPreviousFinals(segments)
        segments = trimmedInterimSuffixesCoveredByFollowingFinals(segments)
        segments.removeAll { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard trimFinalPrefixes else { return segments }
        return trimmedFinalPrefixesCoveredByPreviousSegments(segments)
    }

    private static func trimmedInterimPrefixesCoveredByPreviousFinals(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var output: [TranscriptSegment] = []
        var previousFinal: TranscriptSegment?
        for segment in segments {
            var current = segment
            if !current.isFinal,
               let final = previousFinal,
               segmentsCanShareTextBoundary(final, current),
               let coveredTokenCount = coveredPrefixTokenCount(in: current.text, after: final.text),
               coveredTokenCount >= 2 {
                let text = removingPrefixTokenCount(coveredTokenCount, from: current.text)
                current = rewritten(
                    current,
                    text: text,
                    startTimeSeconds: adjustedStartTime(after: final, fallback: current.startTimeSeconds)
                )
            }
            output.append(current)
            if current.isFinal {
                previousFinal = current
            }
        }
        return output
    }

    private static func trimmedInterimSuffixesCoveredByFollowingFinals(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var output = segments
        var nextFinal: TranscriptSegment?
        for index in output.indices.reversed() {
            var current = output[index]
            if !current.isFinal,
               let final = nextFinal,
               segmentsCanShareTextBoundary(current, final),
               let overlap = suffixPrefixOverlap(current.text, final.text),
               overlap >= 2 {
                let text = removingSuffixTokenCount(overlap, from: current.text)
                current = rewritten(current, text: text, startTimeSeconds: current.startTimeSeconds)
                output[index] = current
            }
            if current.isFinal {
                nextFinal = current
            }
        }
        return output
    }

    private static func trimmedFinalPrefixesCoveredByPreviousSegments(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var output: [TranscriptSegment] = []
        for segment in segments {
            var current = segment
            if current.isFinal,
               let previous = output.last,
               previous.isFinal,
               segmentsCanShareTextBoundary(previous, current),
               let overlap = suffixPrefixOverlap(previous.text, current.text),
               overlap >= 2 {
                let text = removingPrefixTokenCount(overlap, from: current.text)
                if !text.isEmpty {
                    current = rewritten(current, text: text, startTimeSeconds: current.startTimeSeconds)
                }
            }
            if !current.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                output.append(current)
            }
        }
        return output
    }

    private static func segmentsCanShareTextBoundary(_ first: TranscriptSegment, _ second: TranscriptSegment) -> Bool {
        guard first.sourceProvider == second.sourceProvider,
              speakersAreCompatible(first.speaker, second.speaker)
        else {
            return false
        }
        return segmentsAreNearby(first, second)
    }

    private static func segmentsAreNearby(_ first: TranscriptSegment, _ second: TranscriptSegment) -> Bool {
        guard let firstEnd = first.endTimeSeconds,
              let secondStart = second.startTimeSeconds
        else {
            return true
        }
        return secondStart <= firstEnd + 1.25
    }

    private static func coveredPrefixTokenCount(in text: String, after previousText: String) -> Int? {
        let previousTokens = normalizedTokens(previousText)
        let currentTokens = normalizedTokens(text)
        let maxOverlap = min(previousTokens.count, currentTokens.count)
        guard maxOverlap > 0 else { return nil }
        for candidate in stride(from: maxOverlap, through: 2, by: -1) {
            let suffix = Array(previousTokens.suffix(candidate))
            if let start = firstIndex(of: suffix, in: currentTokens),
               start <= 4 {
                return start + candidate
            }
        }
        return nil
    }

    private static func firstIndex(of needle: [String], in haystack: [String]) -> Int? {
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        for start in 0...(haystack.count - needle.count) {
            let end = start + needle.count
            if Array(haystack[start..<end]) == needle {
                return start
            }
        }
        return nil
    }

    private static func suffixPrefixOverlap(_ first: String, _ second: String) -> Int? {
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

    private static func removingPrefixTokenCount(_ count: Int, from text: String) -> String {
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

    private static func removingSuffixTokenCount(_ count: Int, from text: String) -> String {
        guard count > 0 else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        var remaining = count
        var index = text.endIndex
        var insideToken = false
        while index > text.startIndex {
            index = text.index(before: index)
            let scalar = text[index].unicodeScalars.first
            let isToken = scalar.map { CharacterSet.alphanumerics.contains($0) } ?? false
            if isToken {
                insideToken = true
            } else if insideToken {
                remaining -= 1
                insideToken = false
                if remaining == 0 {
                    return trimmingTrailingBoundary(from: String(text[..<text.index(after: index)]))
                }
            }
        }
        if remaining <= 1, insideToken {
            return ""
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trimmingLeadingBoundary(from text: String) -> String {
        let boundary = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.;:!?"))
        var start = text.startIndex
        while start < text.endIndex {
            let scalar = text[start].unicodeScalars.first
            guard scalar.map({ boundary.contains($0) }) == true else { break }
            start = text.index(after: start)
        }
        return String(text[start...])
    }

    private static func trimmingTrailingBoundary(from text: String) -> String {
        let boundary = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.;:!?"))
        var end = text.endIndex
        while end > text.startIndex {
            let previous = text.index(before: end)
            let scalar = text[previous].unicodeScalars.first
            guard scalar.map({ boundary.contains($0) }) == true else { break }
            end = previous
        }
        return String(text[..<end])
    }

    private static func adjustedStartTime(after previous: TranscriptSegment, fallback: Double?) -> Double? {
        guard let previousEnd = previous.endTimeSeconds else { return fallback }
        guard let fallback else { return previousEnd }
        return max(previousEnd, fallback)
    }

    private static func rewritten(
        _ segment: TranscriptSegment,
        text: String,
        startTimeSeconds: Double?
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: segment.id,
            speaker: segment.speaker,
            startTimeSeconds: startTimeSeconds,
            endTimeSeconds: segment.endTimeSeconds,
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            language: segment.language,
            sourceProvider: segment.sourceProvider,
            isFinal: segment.isFinal,
            speechFinal: segment.speechFinal,
            confidence: segment.confidence,
            createdAt: segment.createdAt,
            timingSource: segment.timingSource,
            translatedText: segment.translatedText,
            translationTargetLocale: segment.translationTargetLocale,
            translationIsFinal: segment.translationIsFinal
        )
    }

    private static func speakersAreCompatible(_ first: TranscriptSpeaker, _ second: TranscriptSpeaker) -> Bool {
        guard let firstID = first.identifier,
              let secondID = second.identifier
        else {
            return true
        }
        return firstID == secondID
    }

    private static func segmentsOverlap(_ first: TranscriptSegment, _ second: TranscriptSegment) -> Bool {
        guard let firstStart = first.startTimeSeconds,
              let firstEnd = first.endTimeSeconds,
              let secondStart = second.startTimeSeconds,
              let secondEnd = second.endTimeSeconds
        else {
            return false
        }
        let overlap = min(firstEnd, secondEnd) - max(firstStart, secondStart)
        guard overlap > 0 else { return false }
        let shorterDuration = min(firstEnd - firstStart, secondEnd - secondStart)
        return shorterDuration <= 0 || overlap / shorterDuration >= 0.5
    }

    private static func normalizedTextsOverlap(_ first: String, _ second: String) -> Bool {
        let first = normalizedTranscriptComparisonText(first)
        let second = normalizedTranscriptComparisonText(second)
        guard !first.isEmpty, !second.isEmpty else { return false }
        if first.contains(second) || second.contains(first) {
            return true
        }
        return false
    }

    private static func normalizedTranscriptComparisonText(_ text: String) -> String {
        normalizedTokens(text).joined(separator: " ")
    }

    private static func normalizedTokens(_ text: String) -> [String] {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func segment(
        _ incoming: TranscriptSegment,
        preservingTranslationFrom existing: TranscriptSegment
    ) -> TranscriptSegment {
        guard incoming.text == existing.text,
              incoming.translatedText == nil,
              incoming.translationTargetLocale == nil,
              incoming.translationIsFinal == nil
        else {
            return incoming
        }
        return TranscriptSegment(
            id: incoming.id,
            speaker: incoming.speaker,
            startTimeSeconds: incoming.startTimeSeconds,
            endTimeSeconds: incoming.endTimeSeconds,
            text: incoming.text,
            language: incoming.language,
            sourceProvider: incoming.sourceProvider,
            isFinal: incoming.isFinal,
            speechFinal: incoming.speechFinal,
            confidence: incoming.confidence,
            createdAt: incoming.createdAt,
            timingSource: incoming.timingSource,
            translatedText: existing.translatedText,
            translationTargetLocale: existing.translationTargetLocale,
            translationIsFinal: existing.translationIsFinal
        )
    }
}

public final class FileBackedTranscriptUpdateSink: TranscriptUpdateSink {
    private let writer: TranscriptFileWriter
    private var accumulator: TranscriptSegmentAccumulator

    public init(
        transcriptURL: URL,
        initialDocument: TranscriptDocument = TranscriptDocument()
    ) throws {
        self.writer = try TranscriptFileWriter(url: transcriptURL)
        self.accumulator = TranscriptSegmentAccumulator(document: initialDocument)
    }

    public func receive(_ update: TranscriptSegmentUpdate) {
        try? persist(update)
    }

    public func persist(_ update: TranscriptSegmentUpdate) throws {
        let result = accumulator.apply(update)
        if let text = result.plainTextReplacement {
            try writer.replace(with: text)
        } else {
            try writer.replace(with: result.document.segments)
        }
    }
}
