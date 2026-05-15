import XCTest
@testable import MeetingAgentCore

final class MeetingExportServiceTests: XCTestCase {
    func testExportsRenderedStructuredTranscript() throws {
        let fixture = try MeetingExportFixture()
        defer { fixture.cleanup() }
        let session = fixture.session(segments: [
            TranscriptSegment(speaker: TranscriptSpeaker(identifier: "a", label: "Allan"), text: "Hello"),
            TranscriptSegment(speaker: TranscriptSpeaker(identifier: "a", label: "Allan"), text: "Next step")
        ])
        let destination = fixture.root.appendingPathComponent("transcript-export.txt")

        try MeetingExportService().exportTranscript(for: fixture.record, session: session, to: destination)

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "Allan:\nHello Next step")
    }

    func testExportsSummaryMarkdownWhenPresent() throws {
        let fixture = try MeetingExportFixture()
        defer { fixture.cleanup() }
        let summary = fixture.summary(overview: "Decision made")
        let destination = fixture.root.appendingPathComponent("summary-export.md")

        try MeetingExportService().exportSummary(summary, to: destination)

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), MeetingSummaryMarkdownRenderer.render(summary))
    }

    func testSummaryExportFailsWhenSummaryMissing() throws {
        let fixture = try MeetingExportFixture()
        defer { fixture.cleanup() }

        XCTAssertThrowsError(try MeetingExportService().exportSummary(
            nil,
            to: fixture.root.appendingPathComponent("summary-export.md")
        )) { error in
            XCTAssertEqual(error as? MeetingExportError, .missingArtifact("summary"))
        }
    }

    func testExportsMeetingDataJSON() throws {
        let fixture = try MeetingExportFixture()
        defer { fixture.cleanup() }
        let destination = fixture.root.appendingPathComponent("meeting.json")

        try MeetingExportService().exportMeetingData(for: fixture.record, to: destination)

        let data = try Data(contentsOf: destination)
        let decoded = try JSONDecoder.meetingAgent.decode(MeetingRecord.self, from: data)
        XCTAssertEqual(decoded.id, fixture.record.id)
        XCTAssertEqual(decoded.summaryURL?.lastPathComponent, "summary.md")
    }

    func testExportsStructuredTranscriptAsSRT() throws {
        let fixture = try MeetingExportFixture()
        defer { fixture.cleanup() }
        let session = fixture.session(segments: [
            TranscriptSegment(
                speaker: TranscriptSpeaker(identifier: "a", label: "Allan"),
                startTimeSeconds: 1.25,
                endTimeSeconds: 4.5,
                text: "Confirm the launch owner.",
                timingSource: .precise
            ),
            TranscriptSegment(
                speaker: TranscriptSpeaker(identifier: "b", label: "Bianca"),
                startTimeSeconds: 5,
                endTimeSeconds: 7,
                text: "Alex owns it.",
                timingSource: .precise
            )
        ])
        let destination = fixture.root.appendingPathComponent("captions.srt")

        try MeetingExportService().exportSubtitles(for: fixture.record, session: session, format: .srt, to: destination)

        XCTAssertEqual(
            try String(contentsOf: destination, encoding: .utf8),
            """
            1
            00:00:01,250 --> 00:00:04,500
            Allan: Confirm the launch owner.

            2
            00:00:05,000 --> 00:00:07,000
            Bianca: Alex owns it.

            """
        )
    }

    func testExportsStructuredTranscriptAsVTTWithApproximateFallbackTiming() throws {
        let fixture = try MeetingExportFixture()
        defer { fixture.cleanup() }
        let session = fixture.session(segments: [
            TranscriptSegment(speaker: TranscriptSpeaker(identifier: "a", label: "Allan"), text: "First line."),
            TranscriptSegment(speaker: TranscriptSpeaker(identifier: "a", label: "Allan"), text: "Second line.")
        ])
        let destination = fixture.root.appendingPathComponent("captions.vtt")

        try MeetingExportService().exportSubtitles(for: fixture.record, session: session, format: .vtt, to: destination)

        XCTAssertEqual(
            try String(contentsOf: destination, encoding: .utf8),
            """
            WEBVTT

            00:00:00.000 --> 00:00:03.000
            Allan: First line.

            00:00:03.250 --> 00:00:06.250
            Allan: Second line.

            """
        )
    }

    func testSubtitleExportFailsWhenStructuredTranscriptMissing() throws {
        let fixture = try MeetingExportFixture()
        defer { fixture.cleanup() }
        let session = fixture.session(segments: [])

        XCTAssertThrowsError(try MeetingExportService().exportSubtitles(
            for: fixture.record,
            session: session,
            format: .srt,
            to: fixture.root.appendingPathComponent("captions.srt")
        )) { error in
            XCTAssertEqual(error as? MeetingExportError, .missingArtifact("timed transcript"))
        }
    }

    func testExportsReadinessMarkdownReport() throws {
        let fixture = try MeetingExportFixture()
        defer { fixture.cleanup() }
        let session = fixture.session(segments: [
            TranscriptSegment(text: "Structured transcript text for validation.")
        ])
        try CaptureDiagnostics(
            framesCaptured: 44_100,
            durationSeconds: 1,
            lastFrameAt: Date(timeIntervalSince1970: 1_777_000_001),
            sampleRate: 44_100,
            channelCount: 2,
            averageLevel: 0.2,
            peakLevel: 0.8,
            silentDurationSeconds: 0,
            bufferBacklog: 0,
            droppedFrameCount: 0,
            targetProcessID: 42,
            targetDisplayName: "Google Chrome",
            endedReason: .saved,
            status: .recordingSaved
        ).write(to: fixture.record.diagnosticsURL!)
        let destination = fixture.root.appendingPathComponent("readiness.md")

        try MeetingExportService().exportReadinessReport(for: fixture.record, session: session, to: destination)

        let markdown = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(markdown.contains("# Meeting Readiness Report"))
        XCTAssertTrue(markdown.contains("Google Meet"))
        XCTAssertTrue(markdown.contains("Transcribed"))
        XCTAssertTrue(markdown.contains("Structured transcript text for validation."))
        XCTAssertTrue(markdown.contains("recordingSaved"))
        XCTAssertTrue(markdown.contains("Startup replay frames: 0"))
    }

    func testExportsKnowledgePackageMarkdownFiles() throws {
        let fixture = try MeetingExportFixture()
        defer { fixture.cleanup() }
        let segments = [
            TranscriptSegment(
                id: "segment-1",
                speaker: TranscriptSpeaker(identifier: "a", label: "Alice"),
                startTimeSeconds: 12,
                text: "Let's start with Tokyo for Q3."
            ),
            TranscriptSegment(
                id: "segment-2",
                speaker: TranscriptSpeaker(identifier: "b", label: "Ken"),
                startTimeSeconds: 48,
                text: "I will confirm legal timing."
            )
        ]
        let summary = MeetingSummary(
            overview: "The team agreed to a Tokyo-only pilot.",
            keyTopics: ["Japan GTM"],
            decisions: [
                MeetingDecision(
                    description: "Q3 Japan launch will start with a Tokyo-only pilot.",
                    participants: ["Alice", "Ken"],
                    sourceSegmentIDs: ["segment-1"],
                    confidence: 0.9
                )
            ],
            actionItems: [
                MeetingActionItem(
                    description: "Ken will confirm legal timing.",
                    owner: "Ken",
                    dueDate: nil,
                    sourceSegmentIDs: ["segment-2"],
                    confidence: 0.8
                )
            ],
            openQuestions: [],
            risks: [],
            followUps: [],
            language: "en-US",
            sourceSegmentIDs: ["segment-1", "segment-2"],
            generatedAt: Date(timeIntervalSince1970: 1_777_000_700),
            provider: "test",
            status: .succeeded,
            failureReason: nil
        )
        let session = fixture.session(segments: segments, summary: summary)
        let destination = fixture.root.appendingPathComponent("knowledge-package", isDirectory: true)

        try MeetingExportService().exportKnowledgePackage(for: fixture.record, session: session, to: destination)

        let files = try FileManager.default.contentsOfDirectory(atPath: destination.path).sorted()
        XCTAssertEqual(files, ["knowledge.md", "meeting.md", "transcript.md"])
        let meeting = try String(contentsOf: destination.appendingPathComponent("meeting.md"), encoding: .utf8)
        let transcript = try String(contentsOf: destination.appendingPathComponent("transcript.md"), encoding: .utf8)
        let knowledge = try String(contentsOf: destination.appendingPathComponent("knowledge.md"), encoding: .utf8)
        XCTAssertTrue(meeting.contains("# Google Meet"))
        XCTAssertTrue(transcript.contains(#"<a id="t-00-00-12"></a>"#))
        XCTAssertTrue(knowledge.contains("### decision_001"))
        XCTAssertTrue(knowledge.contains("[[transcript#t-00-00-12|Alice 00:00:12]]"))
    }

    func testKnowledgePackageExportUsesEmptySessionTranscriptWhenNoSegmentsExist() throws {
        let fixture = try MeetingExportFixture()
        defer { fixture.cleanup() }

        let session = fixture.session(segments: [])
        let destination = fixture.root.appendingPathComponent("knowledge-package", isDirectory: true)
        try MeetingExportService().exportKnowledgePackage(
            for: fixture.record,
            session: session,
            to: destination
        )

        let transcript = try String(contentsOf: destination.appendingPathComponent("transcript.md"), encoding: .utf8)
        XCTAssertTrue(transcript.contains("Transcript is not available."))
    }

    func testExportsKnowledgePackageWithFailureNote() throws {
        let fixture = try MeetingExportFixture()
        defer { fixture.cleanup() }
        let session = fixture.session(segments: [
            TranscriptSegment(id: "segment-1", text: "Transcript exists.")
        ])
        let destination = fixture.root.appendingPathComponent("knowledge-package", isDirectory: true)

        try MeetingExportService().exportKnowledgePackage(
            for: fixture.record,
            session: session,
            knowledge: MeetingKnowledge(failureReason: "OpenRouter API key is not configured"),
            to: destination
        )

        let knowledge = try String(contentsOf: destination.appendingPathComponent("knowledge.md"), encoding: .utf8)
        XCTAssertTrue(knowledge.contains("## Extraction Status"))
        XCTAssertTrue(knowledge.contains("Knowledge extraction failed: OpenRouter API key is not configured"))
    }
}

private struct MeetingExportFixture {
    let root: URL
    let record: MeetingRecord

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        record = MeetingRecord(
            id: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
            name: "Google Meet",
            startedAt: Date(timeIntervalSince1970: 1_777_000_000),
            endedAt: Date(timeIntervalSince1970: 1_777_000_600),
            audioURL: root.appendingPathComponent("audio.wav"),
            transcriptURL: root.appendingPathComponent("transcript.txt"),
            transcriptJSONURL: root.appendingPathComponent("transcript.json"),
            summaryURL: root.appendingPathComponent("summary.md"),
            diagnosticsURL: root.appendingPathComponent("diagnostics.json"),
            transcriptionStatus: .transcribed,
            transcriptionFailureReason: nil,
            speechProvider: .whisper,
            speechLocaleIdentifier: "zh-CN"
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func session(segments: [TranscriptSegment], summary: MeetingSummary? = nil) -> MeetingSessionState {
        MeetingSessionState(
            meetingID: record.id,
            transcript: TranscriptState(
                meetingID: record.id,
                captionDocument: captionDocument(from: segments),
                source: .hydratedFromPersistence
            ),
            summary: summary.map(SummaryState.loaded) ?? .missing
        )
    }

    func summary(overview: String) -> MeetingSummary {
        MeetingSummary(
            overview: overview,
            keyTopics: [],
            decisions: [],
            actionItems: [],
            openQuestions: [],
            risks: [],
            followUps: [],
            language: "en-US",
            sourceSegmentIDs: [],
            generatedAt: Date(timeIntervalSince1970: 1_777_000_700),
            provider: "test",
            status: .succeeded,
            failureReason: nil
        )
    }

    private func captionDocument(from segments: [TranscriptSegment]) -> CaptionDocument {
        let turns = segments.map { segment in
            CaptionTurn(
                id: segment.id,
                speakerID: segment.speakerID,
                speakerLabel: segment.speakerLabel,
                startTimeSeconds: segment.startTimeSeconds,
                endTimeSeconds: segment.endTimeSeconds,
                sections: [
                    CaptionSection(
                        id: "\(segment.id)-section",
                        text: segment.text,
                        utteranceIDs: [segment.id],
                        startTimeSeconds: segment.startTimeSeconds,
                        endTimeSeconds: segment.endTimeSeconds
                    )
                ],
                state: segment.isFinal ? .final : .draft,
                source: CaptionTurnSource(
                    providerID: segment.sourceProvider,
                    utteranceIDs: [segment.id]
                ),
                createdAt: segment.createdAt,
                updatedAt: segment.createdAt
            )
        }
        return CaptionDocument(
            turns: turns,
            provider: CaptionProviderInfo(
                id: segments.first?.sourceProvider ?? "test",
                locale: segments.compactMap(\.language).first
            )
        )
    }
}
