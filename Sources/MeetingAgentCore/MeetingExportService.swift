import Foundation

public enum MeetingExportError: Error, Equatable, LocalizedError {
    case missingArtifact(String)

    public var errorDescription: String? {
        switch self {
        case .missingArtifact(let name):
            return "Missing \(name) artifact"
        }
    }
}

public enum SubtitleExportFormat: Equatable {
    case srt
    case vtt
}

public struct MeetingExportService {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func exportTranscript(for record: MeetingRecord, to destinationURL: URL) throws {
        guard let transcript = TranscriptFileWriter.renderedTranscript(
            textURL: record.transcriptURL,
            structuredURL: record.transcriptJSONURL
        ) else {
            throw MeetingExportError.missingArtifact("transcript")
        }
        try write(transcript, to: destinationURL)
    }

    public func exportSummary(for record: MeetingRecord, to destinationURL: URL) throws {
        try write(try summaryText(for: record), to: destinationURL)
    }

    public func exportMeetingData(for record: MeetingRecord, to destinationURL: URL) throws {
        try createDestinationDirectory(for: destinationURL)
        let data = try JSONEncoder.meetingAgent.encode(record)
        try data.write(to: destinationURL, options: .atomic)
    }

    public func exportSubtitles(
        for record: MeetingRecord,
        format: SubtitleExportFormat,
        to destinationURL: URL
    ) throws {
        let document = try transcriptDocument(for: record)
        let cues = subtitleCues(from: document.segments)
        guard !cues.isEmpty else {
            throw MeetingExportError.missingArtifact("timed transcript")
        }
        switch format {
        case .srt:
            try write(renderSRT(cues), to: destinationURL)
        case .vtt:
            try write(renderVTT(cues), to: destinationURL)
        }
    }

    public func exportReadinessReport(for record: MeetingRecord, to destinationURL: URL) throws {
        try write(readinessReport(for: record), to: destinationURL)
    }

    public func exportKnowledgePackage(
        for record: MeetingRecord,
        summary: MeetingSummary?,
        knowledge: MeetingKnowledge? = nil,
        to destinationURL: URL
    ) throws {
        let document = try transcriptDocument(for: record)
        let resolvedKnowledge: MeetingKnowledge
        if let knowledge {
            resolvedKnowledge = knowledge
        } else if let summary {
            resolvedKnowledge = MeetingKnowledgeExtractor.fromSummary(summary, segments: document.segments)
        } else {
            resolvedKnowledge = MeetingKnowledge(failureReason: "Knowledge extraction was not available.")
        }
        let package = MeetingKnowledgePackage(
            record: record,
            summary: summary,
            segments: document.segments,
            knowledge: resolvedKnowledge
        )

        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        try MeetingKnowledgePackageMarkdownRenderer.renderMeeting(package)
            .write(to: destinationURL.appendingPathComponent("meeting.md"), atomically: true, encoding: .utf8)
        try MeetingKnowledgePackageMarkdownRenderer.renderTranscript(package)
            .write(to: destinationURL.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        try MeetingKnowledgePackageMarkdownRenderer.renderKnowledge(package)
            .write(to: destinationURL.appendingPathComponent("knowledge.md"), atomically: true, encoding: .utf8)
    }

    public func summaryText(for record: MeetingRecord) throws -> String {
        guard let summaryURL = record.summaryURL,
              fileManager.fileExists(atPath: summaryURL.path)
        else {
            throw MeetingExportError.missingArtifact("summary")
        }

        let summary = try String(contentsOf: summaryURL, encoding: .utf8)
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MeetingExportError.missingArtifact("summary")
        }
        return summary
    }

    private func readinessReport(for record: MeetingRecord) -> String {
        let transcript = TranscriptFileWriter.renderedTranscript(
            textURL: record.transcriptURL,
            structuredURL: record.transcriptJSONURL
        )
        let diagnostics = diagnostics(for: record)
        let summaryAvailable = record.summaryURL.map { fileManager.fileExists(atPath: $0.path) } ?? false

        var lines: [String] = [
            "# Meeting Readiness Report",
            "",
            "## Meeting",
            "",
            "- Name: \(record.name)",
            "- ID: \(record.id.uuidString)",
            "- Started: \(format(record.startedAt))",
            "- Ended: \(record.endedAt.map(format) ?? "Not ended")",
            "- STT provider: \(record.transcriptionProviderID)",
            "- Language: \(record.speechLocaleIdentifier)",
            "- Transcription: \(transcriptionLabel(for: record.transcriptionStatus))",
            "- Failure reason: \(record.transcriptionFailureReason ?? "None")",
            "",
            "## Artifacts",
            "",
            "- Audio: \(artifactPath(record.audioURL))",
            "- Transcript: \(artifactPath(record.transcriptURL))",
            "- Structured transcript: \(artifactPath(record.transcriptJSONURL))",
            "- Summary: \(summaryAvailable ? artifactPath(record.summaryURL) : "Not generated")",
            "- Diagnostics: \(artifactPath(record.diagnosticsURL))",
            "",
            "## Capture Diagnostics",
            ""
        ]

        if let diagnostics {
            lines.append(contentsOf: [
                "- Status: \(diagnostics.status.rawValue)",
                "- Frames captured: \(diagnostics.framesCaptured)",
                "- Duration seconds: \(format(diagnostics.durationSeconds))",
                "- Average level: \(format(diagnostics.averageLevel))",
                "- Peak level: \(format(diagnostics.peakLevel))",
                "- Silent duration seconds: \(format(diagnostics.silentDurationSeconds))",
                "- Dropped frames: \(diagnostics.droppedFrameCount)",
                "- Startup replay frames: \(diagnostics.startupReplayFrameCount)",
                "- Startup replay duration seconds: \(format(diagnostics.startupReplayDurationSeconds))",
                "- Startup replay dropped frames: \(diagnostics.startupReplayDroppedFrameCount)",
                ""
            ])
        } else {
            lines.append(contentsOf: [
                "No diagnostics artifact is available.",
                ""
            ])
        }

        lines.append(contentsOf: [
            "## Transcript Excerpt",
            "",
            transcriptExcerpt(from: transcript),
            ""
        ])

        return lines.joined(separator: "\n")
    }

    private func diagnostics(for record: MeetingRecord) -> CaptureDiagnostics? {
        guard let diagnosticsURL = record.diagnosticsURL,
              fileManager.fileExists(atPath: diagnosticsURL.path),
              let data = try? Data(contentsOf: diagnosticsURL)
        else {
            return nil
        }
        return try? JSONDecoder.meetingAgent.decode(CaptureDiagnostics.self, from: data)
    }

    private func transcriptDocument(for record: MeetingRecord) throws -> TranscriptDocument {
        guard let transcriptJSONURL = record.transcriptJSONURL,
              fileManager.fileExists(atPath: transcriptJSONURL.path)
        else {
            throw MeetingExportError.missingArtifact("structured transcript")
        }
        return try TranscriptFileWriter.readDocument(from: transcriptJSONURL)
    }

    private func subtitleCues(from segments: [TranscriptSegment]) -> [SubtitleCue] {
        var mapper = SpeakerLabelMapper(speakers: segments.map(\.speaker))
        var fallbackStart = 0.0
        return segments.compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let start = max(segment.startTimeSeconds ?? fallbackStart, 0)
            let end = max(segment.endTimeSeconds ?? start + 3, start + 0.5)
            fallbackStart = end + 0.25
            let speakerLabel = mapper.label(for: segment.speaker)
            return SubtitleCue(
                start: start,
                end: end,
                text: "\(speakerLabel): \(text)"
            )
        }
    }

    private func renderSRT(_ cues: [SubtitleCue]) -> String {
        cues.enumerated().map { index, cue in
            [
                "\(index + 1)",
                "\(subtitleTimestamp(cue.start, separator: ",")) --> \(subtitleTimestamp(cue.end, separator: ","))",
                cue.text
            ].joined(separator: "\n")
        }
        .joined(separator: "\n\n") + "\n"
    }

    private func renderVTT(_ cues: [SubtitleCue]) -> String {
        "WEBVTT\n\n" + cues.map { cue in
            [
                "\(subtitleTimestamp(cue.start, separator: ".")) --> \(subtitleTimestamp(cue.end, separator: "."))",
                cue.text
            ].joined(separator: "\n")
        }
        .joined(separator: "\n\n") + "\n"
    }

    private func subtitleTimestamp(_ seconds: Double, separator: String) -> String {
        let totalMilliseconds = max(Int((seconds * 1_000).rounded()), 0)
        let hours = totalMilliseconds / 3_600_000
        let minutes = (totalMilliseconds % 3_600_000) / 60_000
        let wholeSeconds = (totalMilliseconds % 60_000) / 1_000
        let milliseconds = totalMilliseconds % 1_000
        return String(format: "%02d:%02d:%02d%@%03d", hours, minutes, wholeSeconds, separator, milliseconds)
    }

    private func write(_ text: String, to destinationURL: URL) throws {
        try createDestinationDirectory(for: destinationURL)
        try text.write(to: destinationURL, atomically: true, encoding: .utf8)
    }

    private func createDestinationDirectory(for destinationURL: URL) throws {
        let directory = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func artifactPath(_ url: URL?) -> String {
        url?.path ?? "Not available"
    }

    private func transcriptExcerpt(from transcript: String?) -> String {
        guard let transcript,
              !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return "Transcript is not available."
        }

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 1_000 else { return trimmed }
        let endIndex = trimmed.index(trimmed.startIndex, offsetBy: 1_000)
        return String(trimmed[..<endIndex]) + "..."
    }

    private func transcriptionLabel(for status: TranscriptionStatus) -> String {
        switch status {
        case .notStarted:
            return "Not started"
        case .transcribing:
            return "Transcribing"
        case .transcribed:
            return "Transcribed"
        case .failed:
            return "Failed"
        case .retryRequested:
            return "Retry requested"
        }
    }

    private func format(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

private struct SubtitleCue: Equatable {
    let start: Double
    let end: Double
    let text: String
}
