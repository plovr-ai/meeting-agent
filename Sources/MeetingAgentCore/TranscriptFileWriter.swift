import Foundation

public final class TranscriptFileWriter {
    private let url: URL
    private let structuredURL: URL
    private var isClosed = false

    public init(url: URL, structuredURL: URL? = nil) throws {
        self.url = url
        self.structuredURL = structuredURL ?? url.deletingPathExtension().appendingPathExtension("json")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        if !FileManager.default.fileExists(atPath: self.structuredURL.path) {
            try writeDocument(TranscriptDocument())
        }
    }

    public func replace(with text: String) throws {
        guard !isClosed else { return }
        try writeDocument(TranscriptDocument())
        try (text + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    public func replace(with segments: [TranscriptSegment]) throws {
        guard !isClosed else { return }
        let labeledSegments = Self.assignSpeakerLabels(to: segments)
        try writeDocument(TranscriptDocument(segments: labeledSegments))
        try (TranscriptFormatter.render(labeledSegments) + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    public func append(_ segment: TranscriptSegment) throws {
        guard !isClosed else { return }
        var document = try Self.readDocument(from: structuredURL)
        document.segments.append(segment)
        try replace(with: document.segments)
    }

    public func upsert(_ segment: TranscriptSegment) throws {
        guard !isClosed else { return }
        var document = try Self.readDocument(from: structuredURL)
        if let index = document.segments.firstIndex(where: { $0.id == segment.id }) {
            document.segments[index] = Self.segment(segment, preservingTranslationFrom: document.segments[index])
            document.segments.removeAll {
                $0.id != segment.id && Self.shouldReplaceExistingSegment($0, with: segment)
            }
        } else {
            if document.segments.contains(where: { Self.shouldKeepExistingSegment($0, insteadOf: segment) }) {
                try replace(with: document.segments)
                return
            }
            document.segments.removeAll { Self.shouldReplaceExistingSegment($0, with: segment) }
            document.segments.append(segment)
        }
        document.segments = Self.trimmedCoveredInterimPrefixes(document.segments)
        document.segments = Self.prunedCoveredInterimSegments(document.segments)
        try replace(with: document.segments)
    }

    public func close() throws {
        isClosed = true
    }

    public static func readDocument(from url: URL) throws -> TranscriptDocument {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return TranscriptDocument()
        }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else {
            return TranscriptDocument()
        }
        return try JSONDecoder.meetingAgent.decode(TranscriptDocument.self, from: data)
    }

    public static func renderedTranscript(
        textURL: URL?,
        structuredURL: URL?
    ) -> String? {
        if let structuredURL,
           let document = try? readDocument(from: structuredURL),
           !document.segments.isEmpty {
            let text = TranscriptFormatter.render(document.segments)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }

        guard let textURL,
              let text = try? String(contentsOf: textURL, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return text
    }

    public static func updateSpeakerLabel(
        speakerID: String,
        label: String,
        textURL: URL?,
        structuredURL: URL?
    ) throws {
        guard let structuredURL else {
            throw MeetingExportError.missingArtifact("structured transcript")
        }
        let normalizedSpeakerID = speakerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSpeakerID.isEmpty, !normalizedLabel.isEmpty else {
            throw ProbeError.invalidArguments("Speaker ID and label are required")
        }
        let document = try readDocument(from: structuredURL)
        let updatedSegments = document.segments.map { segment in
            guard segment.speakerID == normalizedSpeakerID else { return segment }
            return TranscriptSegment(
                id: segment.id,
                speaker: TranscriptSpeaker(identifier: normalizedSpeakerID, label: normalizedLabel),
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
                translatedText: segment.translatedText,
                translationTargetLocale: segment.translationTargetLocale,
                translationIsFinal: segment.translationIsFinal
            )
        }
        let updatedDocument = TranscriptDocument(version: document.version, segments: updatedSegments)
        let data = try JSONEncoder.meetingAgent.encode(updatedDocument)
        try data.write(to: structuredURL, options: .atomic)
        if let textURL {
            try (TranscriptFormatter.render(updatedSegments) + "\n").write(to: textURL, atomically: true, encoding: .utf8)
        }
    }

    public static func updateSegmentText(
        segmentID: String,
        text: String,
        textURL: URL?,
        structuredURL: URL?
    ) throws {
        guard let structuredURL else {
            throw MeetingExportError.missingArtifact("structured transcript")
        }
        let normalizedSegmentID = segmentID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSegmentID.isEmpty, !normalizedText.isEmpty else {
            throw ProbeError.invalidArguments("Segment ID and text are required")
        }
        let document = try readDocument(from: structuredURL)
        var didUpdateSegment = false
        let updatedSegments = document.segments.map { segment in
            guard segment.id == normalizedSegmentID else { return segment }
            didUpdateSegment = true
            return TranscriptSegment(
                id: segment.id,
                speaker: segment.speaker,
                startTimeSeconds: segment.startTimeSeconds,
                endTimeSeconds: segment.endTimeSeconds,
                text: normalizedText,
                language: segment.language,
                sourceProvider: segment.sourceProvider,
                isFinal: segment.isFinal,
                speechFinal: segment.speechFinal,
                confidence: segment.confidence,
                createdAt: segment.createdAt,
                timingSource: segment.timingSource,
                translatedText: nil,
                translationTargetLocale: nil,
                translationIsFinal: nil
            )
        }
        guard didUpdateSegment else {
            throw ProbeError.invalidArguments("Transcript segment not found")
        }
        let updatedDocument = TranscriptDocument(version: document.version, segments: updatedSegments)
        let data = try JSONEncoder.meetingAgent.encode(updatedDocument)
        try data.write(to: structuredURL, options: .atomic)
        if let textURL {
            try (TranscriptFormatter.render(updatedSegments) + "\n").write(to: textURL, atomically: true, encoding: .utf8)
        }
    }

    public static func updateSegmentTranslation(
        segmentID: String,
        text: String,
        targetLocale: String,
        isFinal: Bool,
        textURL: URL?,
        structuredURL: URL?
    ) throws {
        guard let structuredURL else {
            throw MeetingExportError.missingArtifact("structured transcript")
        }
        let normalizedSegmentID = segmentID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTargetLocale = targetLocale.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSegmentID.isEmpty, !normalizedText.isEmpty, !normalizedTargetLocale.isEmpty else {
            throw ProbeError.invalidArguments("Segment ID, translated text, and target locale are required")
        }
        let document = try readDocument(from: structuredURL)
        var didUpdateSegment = false
        let updatedSegments = document.segments.map { segment in
            guard segment.id == normalizedSegmentID else { return segment }
            didUpdateSegment = true
            return TranscriptSegment(
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
        }
        guard didUpdateSegment else {
            throw ProbeError.invalidArguments("Transcript segment not found")
        }
        let updatedDocument = TranscriptDocument(version: document.version, segments: updatedSegments)
        let data = try JSONEncoder.meetingAgent.encode(updatedDocument)
        try data.write(to: structuredURL, options: .atomic)
        if let textURL {
            try (TranscriptFormatter.render(updatedSegments) + "\n").write(to: textURL, atomically: true, encoding: .utf8)
        }
    }

    private func writeDocument(_ document: TranscriptDocument) throws {
        let data = try JSONEncoder.meetingAgent.encode(document)
        try data.write(to: structuredURL, options: .atomic)
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
                let firstTokens = final.text
                    .lowercased()
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                var normalizedFirstTokens: [String] = []
                for token in firstTokens where !token.isEmpty {
                    normalizedFirstTokens.append(token)
                }
                let secondTokens = current.text
                    .lowercased()
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                var normalizedSecondTokens: [String] = []
                for token in secondTokens where !token.isEmpty {
                    normalizedSecondTokens.append(token)
                }
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
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func assignSpeakerLabels(to segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var mapper = SpeakerLabelMapper(speakers: segments.map(\.speaker))
        var generatedIDsBySpeaker: [TranscriptSpeaker: String] = [:]
        var nextSpeakerIndex = 1
        return segments.map { segment in
            let speaker = segment.speaker
            let label = mapper.label(for: speaker)
            let speakerID: String
            if let existingID = speaker.identifier {
                speakerID = existingID
            } else if let generatedID = generatedIDsBySpeaker[speaker] {
                speakerID = generatedID
            } else {
                speakerID = "speaker-\(nextSpeakerIndex)"
                generatedIDsBySpeaker[speaker] = speakerID
                nextSpeakerIndex += 1
            }
            return TranscriptSegment(
                id: segment.id,
                speaker: TranscriptSpeaker(identifier: speakerID, label: segment.speakerLabel ?? label),
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
                translatedText: segment.translatedText,
                translationTargetLocale: segment.translationTargetLocale,
                translationIsFinal: segment.translationIsFinal
            )
        }
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
