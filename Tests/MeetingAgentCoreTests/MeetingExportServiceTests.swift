import XCTest
@testable import MeetingAgentCore

final class MeetingExportServiceTests: XCTestCase {
    func testExportsRenderedStructuredTranscript() throws {
        let fixture = try MeetingExportFixture()
        defer { fixture.cleanup() }
        try fixture.writeStructuredTranscript([
            TranscriptSegment(speaker: TranscriptSpeaker(identifier: "a", label: "Allan"), text: "Hello"),
            TranscriptSegment(speaker: TranscriptSpeaker(identifier: "a", label: "Allan"), text: "Next step")
        ])
        let destination = fixture.root.appendingPathComponent("transcript-export.txt")

        try MeetingExportService().exportTranscript(for: fixture.record, to: destination)

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "Allan:\nHello\nNext step")
    }

    func testExportsSummaryMarkdownWhenPresent() throws {
        let fixture = try MeetingExportFixture()
        defer { fixture.cleanup() }
        try "# Summary\n\n- Decision made\n".write(to: fixture.record.summaryURL!, atomically: true, encoding: .utf8)
        let destination = fixture.root.appendingPathComponent("summary-export.md")

        try MeetingExportService().exportSummary(for: fixture.record, to: destination)

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "# Summary\n\n- Decision made\n")
    }

    func testSummaryExportFailsWhenSummaryMissing() throws {
        let fixture = try MeetingExportFixture()
        defer { fixture.cleanup() }

        XCTAssertThrowsError(try MeetingExportService().exportSummary(
            for: fixture.record,
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
        try fixture.writeStructuredTranscript([
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

        try MeetingExportService().exportSubtitles(for: fixture.record, format: .srt, to: destination)

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
        try fixture.writeStructuredTranscript([
            TranscriptSegment(speaker: TranscriptSpeaker(identifier: "a", label: "Allan"), text: "First line."),
            TranscriptSegment(speaker: TranscriptSpeaker(identifier: "a", label: "Allan"), text: "Second line.")
        ])
        let destination = fixture.root.appendingPathComponent("captions.vtt")

        try MeetingExportService().exportSubtitles(for: fixture.record, format: .vtt, to: destination)

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

        XCTAssertThrowsError(try MeetingExportService().exportSubtitles(
            for: fixture.record,
            format: .srt,
            to: fixture.root.appendingPathComponent("captions.srt")
        )) { error in
            XCTAssertEqual(error as? MeetingExportError, .missingArtifact("structured transcript"))
        }
    }

    func testExportsReadinessMarkdownReport() throws {
        let fixture = try MeetingExportFixture()
        defer { fixture.cleanup() }
        try "Plain transcript text for validation.".write(to: fixture.record.transcriptURL!, atomically: true, encoding: .utf8)
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

        try MeetingExportService().exportReadinessReport(for: fixture.record, to: destination)

        let markdown = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(markdown.contains("# Meeting Readiness Report"))
        XCTAssertTrue(markdown.contains("Google Meet"))
        XCTAssertTrue(markdown.contains("Transcribed"))
        XCTAssertTrue(markdown.contains("Plain transcript text for validation."))
        XCTAssertTrue(markdown.contains("recordingSaved"))
        XCTAssertTrue(markdown.contains("Startup replay frames: 0"))
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

    func writeStructuredTranscript(_ segments: [TranscriptSegment]) throws {
        let data = try JSONEncoder.meetingAgent.encode(TranscriptDocument(segments: segments))
        try data.write(to: record.transcriptJSONURL!, options: .atomic)
    }
}
