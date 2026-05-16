import XCTest
@testable import MeetingAgentCore

final class MeetingArtifactSnapshotTests: XCTestCase {
    func testSnapshotReportsTranscriptLatencyFromLatestPerformanceEvent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-artifact-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let meetingID = UUID()
        let performanceEventsURL = root.appendingPathComponent("performance-events.jsonl")
        let startedAt = Date(timeIntervalSince1970: 100)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let events = [
            PerformanceEvent(
                event: "stt_segment_received",
                wallTime: startedAt.addingTimeInterval(2.25),
                audioTimeSeconds: 2
            ),
            PerformanceEvent(
                event: "transcript_segment_written",
                wallTime: startedAt.addingTimeInterval(4.5),
                audioTimeSeconds: 3
            )
        ]
        let payload = try events
            .map { try String(data: encoder.encode($0), encoding: .utf8).unwrapForTest() }
            .joined(separator: "\n")
        try payload.write(to: performanceEventsURL, atomically: true, encoding: .utf8)

        let record = MeetingRecord(
            id: meetingID,
            name: "Latency",
            startedAt: startedAt,
            endedAt: nil,
            audioURL: nil,
            transcriptURL: nil,
            performanceEventsURL: performanceEventsURL,
            transcriptionProviderID: "deepgram-transcribe"
        )
        let document = CaptionDocument(turns: [
            CaptionTurn(
                id: "turn-1",
                sections: [CaptionSection(text: "Latency covered")],
                state: .final,
                source: CaptionTurnSource(providerID: "deepgram-transcribe")
            )
        ])
        let session = MeetingSessionState(
            meetingID: meetingID,
            transcript: TranscriptState(
                meetingID: meetingID,
                captionDocument: document,
                source: .hydratedFromPersistence
            )
        )

        let snapshot = MeetingArtifactSnapshot.make(meeting: record, session: session)

        XCTAssertEqual(snapshot.transcriptText, "User A:\nLatency covered")
        XCTAssertEqual(snapshot.actualTranscriptionSourceText, "deepgram-transcribe")
        XCTAssertEqual(snapshot.transcriptLatencyText, "1.0 s")
        XCTAssertEqual(snapshot.transcriptQualityLabel, "Live transcript")
        XCTAssertEqual(snapshot.transcriptQualityDetailText, "1 final | 0 draft | 1 unknown speaker | 0 empty final")
    }

    func testSnapshotFormatsSubsecondTranscriptLatencyInMilliseconds() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-artifact-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let meetingID = UUID()
        let performanceEventsURL = root.appendingPathComponent("performance-events.jsonl")
        let startedAt = Date(timeIntervalSince1970: 100)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let event = PerformanceEvent(
            event: "stt_segment_received",
            wallTime: startedAt.addingTimeInterval(2.25),
            audioTimeSeconds: 2
        )
        try String(data: encoder.encode(event), encoding: .utf8)
            .unwrapForTest()
            .write(to: performanceEventsURL, atomically: true, encoding: .utf8)

        let record = MeetingRecord(
            id: meetingID,
            name: "Latency",
            startedAt: startedAt,
            endedAt: nil,
            audioURL: nil,
            transcriptURL: nil,
            performanceEventsURL: performanceEventsURL,
            transcriptionProviderID: "deepgram-transcribe"
        )

        let snapshot = MeetingArtifactSnapshot.make(meeting: record, session: MeetingSessionState(meetingID: meetingID))

        XCTAssertEqual(snapshot.transcriptLatencyText, "0 ms")
    }

    func testSnapshotReportsPostProcessedTranscriptQuality() throws {
        let meetingID = UUID()
        let record = MeetingRecord(
            id: meetingID,
            name: "Quality",
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: nil,
            audioURL: nil,
            transcriptURL: nil,
            transcriptionProviderID: "deepgram-transcribe"
        )
        let document = CaptionDocument(
            turns: [
                CaptionTurn(
                    id: "turn-1",
                    speakerID: "speaker-1",
                    speakerLabel: "Allan",
                    sections: [CaptionSection(text: "Refined text")],
                    state: .final,
                    source: CaptionTurnSource(providerID: "deepgram-batch-transcribe")
                )
            ],
            qualityMetadata: TranscriptQualityMetadata(
                source: .postProcessed,
                metrics: TranscriptQualityMetrics(finalTurnCount: 1),
                updatedAt: Date(timeIntervalSince1970: 200)
            )
        )
        let session = MeetingSessionState(
            meetingID: meetingID,
            transcript: TranscriptState(
                meetingID: meetingID,
                captionDocument: document,
                source: .hydratedFromPersistence
            )
        )

        let snapshot = MeetingArtifactSnapshot.make(meeting: record, session: session)

        XCTAssertEqual(snapshot.transcriptQualityLabel, "Post-processed transcript")
        XCTAssertEqual(snapshot.transcriptQualityDetailText, "1 final | 0 draft | 0 unknown speaker | 0 empty final")
    }
}

private extension Optional where Wrapped == String {
    func unwrapForTest(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        try XCTUnwrap(self, file: file, line: line)
    }
}
