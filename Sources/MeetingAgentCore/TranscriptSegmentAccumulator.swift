import Foundation

public enum TranscriptSegmentUpdate: Equatable {
    case upsert(TranscriptSegment)
    case replaceAll([TranscriptSegment])
    case replaceWithPlainText(String)
}

public struct TranscriptSegmentAccumulationResult: Equatable {
    public let document: TranscriptDocument
    public let changedSegmentIDs: [String]
    public let plainTextReplacement: String?
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
        }
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
              segmentsOverlap(first, second),
              normalizedTextsOverlap(first.text, second.text)
        else {
            return false
        }
        return true
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
        let result = accumulator.apply(update)
        if let text = result.plainTextReplacement {
            try? writer.replace(with: text)
        } else {
            try? writer.replace(with: result.document.segments)
        }
    }
}
