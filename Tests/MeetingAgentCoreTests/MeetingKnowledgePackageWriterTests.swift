import XCTest
@testable import MeetingAgentCore

final class MeetingKnowledgePackageWriterTests: XCTestCase {
    func testWritesCanonicalPackageWithIngestFile() throws {
        let fixture = try MeetingKnowledgePackageWriterFixture()
        defer { fixture.cleanup() }
        let destination = fixture.root.appendingPathComponent("package", isDirectory: true)

        let result = try MeetingKnowledgePackageWriter().write(fixture.package, to: destination)

        XCTAssertEqual(result.filesWritten.map(\.lastPathComponent).sorted(), [
            "ingest.md",
            "knowledge.md",
            "meeting.md",
            "transcript.md"
        ])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path).sorted(), [
            "ingest.md",
            "knowledge.md",
            "meeting.md",
            "transcript.md"
        ])
        let ingest = try String(contentsOf: destination.appendingPathComponent("ingest.md"), encoding: .utf8)
        XCTAssertTrue(ingest.contains("# Ingest Meeting"))
        XCTAssertTrue(ingest.contains("Treat `transcript.md` as source evidence."))
        XCTAssertTrue(ingest.contains("Treat `knowledge.md` items as proposed deltas, not automatic truth."))
        XCTAssertTrue(ingest.contains("Preserve evidence links"))
    }

    func testWriterFailsWhenDestinationExistsAsFile() throws {
        let fixture = try MeetingKnowledgePackageWriterFixture()
        defer { fixture.cleanup() }
        let destination = fixture.root.appendingPathComponent("package")
        try "not a directory".write(to: destination, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try MeetingKnowledgePackageWriter().write(fixture.package, to: destination)) { error in
            XCTAssertEqual(error as? MeetingKnowledgePackageWriterError, .destinationIsFile(destination.path))
            XCTAssertEqual(
                (error as? LocalizedError)?.errorDescription,
                "Knowledge package destination is a file: \(destination.path)"
            )
        }
    }
}

private struct MeetingKnowledgePackageWriterFixture {
    let root: URL
    let package: MeetingKnowledgePackage

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-knowledge-package-writer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let record = MeetingRecord(
            id: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
            name: "Japan GTM Sync",
            startedAt: Date(timeIntervalSince1970: 1_777_000_000),
            endedAt: Date(timeIntervalSince1970: 1_777_000_600),
            audioURL: root.appendingPathComponent("audio.wav"),
            transcriptURL: nil,
            transcriptJSONURL: root.appendingPathComponent("transcript.json"),
            summaryURL: root.appendingPathComponent("summary.md"),
            diagnosticsURL: root.appendingPathComponent("diagnostics.json"),
            transcriptionStatus: .transcribed,
            transcriptionFailureReason: nil,
            speechProvider: .whisper,
            speechLocaleIdentifier: "en-US"
        )
        let summary = MeetingSummary(
            overview: "The team agreed to scope launch to Tokyo.",
            keyTopics: ["Japan GTM"],
            decisions: [],
            actionItems: [],
            openQuestions: [],
            risks: [],
            followUps: [],
            language: "en-US",
            sourceSegmentIDs: ["segment-1"],
            generatedAt: Date(timeIntervalSince1970: 1_777_000_700),
            provider: "test",
            status: .succeeded,
            failureReason: nil
        )
        let segment = TranscriptSegment(
            id: "segment-1",
            speaker: TranscriptSpeaker(identifier: "a", label: "Alice"),
            startTimeSeconds: 12,
            text: "Let's scope the launch to Tokyo.",
            timingSource: .precise
        )
        package = MeetingKnowledgePackage(
            record: record,
            summary: summary,
            segments: [segment],
            knowledge: MeetingKnowledge(
                decisions: [
                    MeetingKnowledgeItem(
                        id: "decision_001",
                        statement: "Launch starts with Tokyo.",
                        confidence: .high,
                        status: "Proposed",
                        evidence: [
                            MeetingKnowledgeEvidence(
                                segmentID: "segment-1",
                                speaker: "Alice",
                                timestamp: "00:00:12",
                                anchor: "t-00-00-12"
                            )
                        ]
                    )
                ]
            )
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
