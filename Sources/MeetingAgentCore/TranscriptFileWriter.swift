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
            document.segments[index] = segment
        } else {
            document.segments.append(segment)
        }
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
                timingSource: segment.timingSource
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
                timingSource: segment.timingSource
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
                timingSource: segment.timingSource
            )
        }
    }
}
