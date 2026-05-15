import XCTest
@testable import MeetingAgentCore

final class KarpathyWikiConnectorTests: XCTestCase {
    func testValidationFailsWhenRootMissing() async {
        let connector = KarpathyWikiConnector()
        let configuration = KnowledgeConnectorConfiguration(
            kind: .karpathyWiki,
            isEnabled: true,
            rootURL: nil,
            commandPath: nil,
            autoSyncEnabled: false,
            requireReviewBeforeSync: true
        )

        let validation = await connector.validate(configuration: configuration)

        XCTAssertEqual(validation.status, .unavailable)
        XCTAssertEqual(validation.message, "Karpathy Wiki root is not configured.")
    }

    func testSyncWritesPackageUnderRawMeetingsSlug() async throws {
        let fixture = try KarpathyWikiConnectorFixture()
        defer { fixture.cleanup() }
        let configuration = KnowledgeConnectorConfiguration(
            kind: .karpathyWiki,
            isEnabled: true,
            rootURL: fixture.wikiRoot,
            commandPath: nil,
            autoSyncEnabled: false,
            requireReviewBeforeSync: true
        )

        let result = try await KarpathyWikiConnector().sync(package: fixture.package, configuration: configuration)

        XCTAssertEqual(result.connectorID, "karpathy-wiki")
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertTrue(result.destinationDescription.hasSuffix("raw/meetings/2026-04-24-japan-gtm-sync"))
        XCTAssertEqual(result.filesWritten.map(\.lastPathComponent).sorted(), [
            "ingest.md",
            "knowledge.md",
            "meeting.md",
            "transcript.md"
        ])
        let packageURL = fixture.wikiRoot
            .appendingPathComponent("raw", isDirectory: true)
            .appendingPathComponent("meetings", isDirectory: true)
            .appendingPathComponent("2026-04-24-japan-gtm-sync", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: packageURL.appendingPathComponent("meeting.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: packageURL.appendingPathComponent("ingest.md").path))
    }

    func testSyncFailsWhenDestinationAlreadyExists() async throws {
        let fixture = try KarpathyWikiConnectorFixture()
        defer { fixture.cleanup() }
        let packageURL = fixture.wikiRoot
            .appendingPathComponent("raw", isDirectory: true)
            .appendingPathComponent("meetings", isDirectory: true)
            .appendingPathComponent("2026-04-24-japan-gtm-sync", isDirectory: true)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try "existing".write(to: packageURL.appendingPathComponent("meeting.md"), atomically: true, encoding: .utf8)
        let configuration = KnowledgeConnectorConfiguration(
            kind: .karpathyWiki,
            isEnabled: true,
            rootURL: fixture.wikiRoot,
            commandPath: nil,
            autoSyncEnabled: false,
            requireReviewBeforeSync: true
        )

        do {
            _ = try await KarpathyWikiConnector().sync(package: fixture.package, configuration: configuration)
            XCTFail("Expected sync to fail")
        } catch {
            XCTAssertEqual(error as? KnowledgeConnectorError, .destinationAlreadyExists(packageURL.path))
        }
    }
}

private struct KarpathyWikiConnectorFixture {
    let root: URL
    let wikiRoot: URL
    let package: MeetingKnowledgePackage

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("karpathy-wiki-connector-\(UUID().uuidString)", isDirectory: true)
        wikiRoot = root.appendingPathComponent("wiki", isDirectory: true)
        try FileManager.default.createDirectory(at: wikiRoot, withIntermediateDirectories: true)
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
        let segment = TranscriptSegment(
            id: "segment-1",
            speaker: TranscriptSpeaker(identifier: "a", label: "Alice"),
            startTimeSeconds: 12,
            text: "Let's start with Tokyo.",
            timingSource: .precise
        )
        package = MeetingKnowledgePackage(
            record: record,
            summary: nil,
            segments: [segment],
            knowledge: MeetingKnowledge()
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
