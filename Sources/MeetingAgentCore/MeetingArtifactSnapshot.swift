import Foundation

public struct MeetingArtifactSnapshot: Equatable {
    public let meetingID: UUID
    public let transcriptText: String
    public let transcriptSegments: [TranscriptSegment]
    public let summary: MeetingSummary?
    public let actualTranscriptionSourceText: String
    public let transcriptLatencyText: String
    public let transcriptQualityLabel: String
    public let transcriptQualityDetailText: String

    public init(
        meetingID: UUID,
        transcriptText: String,
        transcriptSegments: [TranscriptSegment],
        summary: MeetingSummary?,
        actualTranscriptionSourceText: String,
        transcriptLatencyText: String,
        transcriptQualityLabel: String,
        transcriptQualityDetailText: String
    ) {
        self.meetingID = meetingID
        self.transcriptText = transcriptText
        self.transcriptSegments = transcriptSegments
        self.summary = summary
        self.actualTranscriptionSourceText = actualTranscriptionSourceText
        self.transcriptLatencyText = transcriptLatencyText
        self.transcriptQualityLabel = transcriptQualityLabel
        self.transcriptQualityDetailText = transcriptQualityDetailText
    }

    public static func make(meeting: MeetingRecord, session: MeetingSessionState) -> MeetingArtifactSnapshot {
        let document = session.transcript.captionDocument.transcriptDocument
        let quality = session.transcript.consumptionView.quality
        let transcriptText = formattedTranscriptText(from: document)
            ?? "Transcript will appear here while recording."
        let providers = Array(Set(document.segments.map(\.sourceProvider))).sorted()

        return MeetingArtifactSnapshot(
            meetingID: meeting.id,
            transcriptText: transcriptText,
            transcriptSegments: document.segments,
            summary: session.summary.summary,
            actualTranscriptionSourceText: providers.isEmpty ? meeting.transcriptionProviderID : providers.joined(separator: ", "),
            transcriptLatencyText: Self.transcriptLatencyText(for: meeting),
            transcriptQualityLabel: Self.qualityLabel(for: quality.source),
            transcriptQualityDetailText: Self.qualityDetailText(for: quality)
        )
    }

    private static func qualityLabel(for source: TranscriptQualitySource) -> String {
        switch source {
        case .liveOnly:
            return "Live transcript"
        case .postProcessed:
            return "Post-processed transcript"
        case .fallbackLive:
            return "Fallback live transcript"
        case .refinementFailed:
            return "Refinement failed"
        }
    }

    private static func qualityDetailText(for quality: TranscriptConsumptionQuality) -> String {
        var parts = [
            "\(quality.finalTurnCount) final",
            "\(quality.draftTurnCount) draft",
            "\(quality.unknownSpeakerTurnCount) unknown speaker",
            "\(quality.emptyFinalTurnCount) empty final"
        ]
        if let reason = quality.fallbackReason {
            parts.append(reason)
        }
        return parts.joined(separator: " | ")
    }

    private static func formattedTranscriptText(from document: TranscriptDocument) -> String? {
        let rendered = TranscriptFormatter.render(document.segments)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return rendered.isEmpty ? nil : rendered
    }

    private static func transcriptLatencyText(for meeting: MeetingRecord) -> String {
        guard let event = latestTranscriptEvent(for: meeting),
              let audioTimeSeconds = event.audioTimeSeconds
        else {
            return "unavailable"
        }
        let expectedWallTime = meeting.startedAt.addingTimeInterval(audioTimeSeconds)
        return format(seconds: max(0, event.wallTime.timeIntervalSince(expectedWallTime)))
    }

    private static func latestTranscriptEvent(for meeting: MeetingRecord) -> PerformanceEvent? {
        performanceEvents(for: meeting)
            .last(where: { $0.event == "transcript_segment_written" && $0.audioTimeSeconds != nil })
            ?? performanceEvents(for: meeting)
                .last(where: { $0.event == "stt_segment_received" && $0.audioTimeSeconds != nil })
    }

    private static func performanceEvents(for meeting: MeetingRecord) -> [PerformanceEvent] {
        guard let url = meeting.performanceEventsURL,
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return content
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                try? decoder.decode(PerformanceEvent.self, from: Data(line.utf8))
            }
    }

    private static func format(seconds: TimeInterval) -> String {
        if seconds < 1 {
            return "\(Int((seconds * 1_000).rounded())) ms"
        }
        return String(format: "%.1f s", seconds)
    }
}
