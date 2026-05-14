import XCTest
@testable import MeetingAgentCore

final class MeetingDataRepositoriesTests: XCTestCase {
    func testFileTranscriptRepositoryLoadsAndSavesCaptionDocument() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-repositories-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let record = try store.createMeeting(name: "Meet", startedAt: Date()).record
        let repository = FileTranscriptRepository()
        let document = CaptionDocument(turns: [
            CaptionTurn(
                id: "turn-1",
                sections: [CaptionSection(text: "Persisted")],
                state: .final,
                source: CaptionTurnSource(providerID: "test")
            )
        ])

        try repository.saveCaptionDocument(document, for: record)
        let loaded = try repository.loadCaptionDocument(for: record)

        XCTAssertEqual(loaded.turns.map(\.text), ["Persisted"])
    }

    func testFileSummaryRepositoryReturnsNilWhenSummaryMissingAndLoadsWhenPresent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("summary-repositories-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let record = try store.createMeeting(name: "Meet", startedAt: Date()).record
        let repository = FileSummaryRepository()

        XCTAssertNil(try repository.loadSummary(for: record))

        let summary = MeetingSummary(
            overview: "Generated",
            keyTopics: [],
            decisions: [],
            actionItems: [],
            openQuestions: [],
            risks: [],
            followUps: [],
            language: "en-US",
            sourceSegmentIDs: ["turn-1"],
            generatedAt: Date(timeIntervalSince1970: 1),
            provider: "test",
            status: .succeeded,
            failureReason: nil
        )
        try repository.saveSummary(summary, for: record)

        XCTAssertEqual(try repository.loadSummary(for: record), summary)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(record.summaryMarkdownURL).path))
    }
}
