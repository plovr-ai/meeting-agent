import Foundation

public struct RecordingOutput {
    public let directory: URL
    public let wavURL: URL
    public let transcriptURL: URL
    public let transcriptJSONURL: URL
    public let diagnosticsURL: URL

    public static func defaultOutput(
        forRequestedWavPath wavPath: String,
        timestamp: Date = Date(),
        timeZone: TimeZone = .current,
        fileManager: FileManager = .default
    ) throws -> RecordingOutput {
        let directory = URL(fileURLWithPath: fileManager.currentDirectoryPath).appendingPathComponent(".record", isDirectory: true)
        let wavName: String
        if wavPath.isEmpty {
            wavName = timestampedWavName(timestamp: timestamp, timeZone: timeZone)
        } else {
            let requestedURL = URL(fileURLWithPath: wavPath)
            wavName = requestedURL.lastPathComponent.isEmpty ? timestampedWavName(timestamp: timestamp, timeZone: timeZone) : requestedURL.lastPathComponent
        }
        let wavURL = directory.appendingPathComponent(wavName)
        let transcriptURL = wavURL.deletingPathExtension().appendingPathExtension("txt")
        let transcriptJSONURL = wavURL.deletingPathExtension().appendingPathExtension("json")
        let diagnosticsURL = directory.appendingPathComponent("diagnostics.json")

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        return RecordingOutput(
            directory: directory,
            wavURL: wavURL,
            transcriptURL: transcriptURL,
            transcriptJSONURL: transcriptJSONURL,
            diagnosticsURL: diagnosticsURL
        )
    }

    private static func timestampedWavName(timestamp: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(formatter.string(from: timestamp)).wav"
    }
}

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

    private func writeDocument(_ document: TranscriptDocument) throws {
        let data = try JSONEncoder.meetingAgent.encode(document)
        try data.write(to: structuredURL, options: .atomic)
    }

    private static func assignSpeakerLabels(to segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var mapper = SpeakerLabelMapper()
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
                confidence: segment.confidence,
                createdAt: segment.createdAt,
                timingSource: segment.timingSource
            )
        }
    }
}
