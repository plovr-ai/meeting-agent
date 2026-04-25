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

    public func exportReadinessReport(for record: MeetingRecord, to destinationURL: URL) throws {
        try write(readinessReport(for: record), to: destinationURL)
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
            "- STT provider: \(record.speechProvider.rawValue)",
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
