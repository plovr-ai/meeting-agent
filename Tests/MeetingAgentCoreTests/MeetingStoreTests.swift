import XCTest
@testable import MeetingAgentCore

final class MeetingStoreTests: XCTestCase {
    func testCreatesMeetingDirectoryAndMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let id = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

        let created = try store.createMeeting(
            id: id,
            name: "Google Chrome",
            startedAt: Date(timeIntervalSince1970: 1_777_000_000)
        )

        XCTAssertEqual(created.record.name, "Google Chrome")
        XCTAssertEqual(created.record.audioURL?.lastPathComponent, "audio.wav")
        XCTAssertNil(created.record.transcriptURL)
        XCTAssertEqual(created.record.transcriptJSONURL?.lastPathComponent, "transcript.json")
        XCTAssertEqual(created.record.summaryURL?.lastPathComponent, "summary.md")
        XCTAssertEqual(created.record.summaryJSONURL?.lastPathComponent, "summary.json")
        XCTAssertEqual(created.record.summaryMarkdownURL?.lastPathComponent, "summary.md")
        XCTAssertEqual(created.record.diagnosticsURL?.lastPathComponent, "diagnostics.json")
        XCTAssertEqual(created.record.meetingProgressJSONURL?.lastPathComponent, "meeting-progress.json")
        XCTAssertEqual(created.record.performanceEventsURL?.lastPathComponent, "performance-events.jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.metadataURL.path))
    }

    func testLoadsMeetingsSortedByStartTimeDescending() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)

        _ = try store.createMeeting(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            name: "Older",
            startedAt: Date(timeIntervalSince1970: 100)
        )
        _ = try store.createMeeting(
            id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            name: "Newer",
            startedAt: Date(timeIntervalSince1970: 200)
        )

        let meetings = try store.loadMeetings()

        XCTAssertEqual(meetings.map(\.name), ["Newer", "Older"])
    }

    func testLoadMeetingsSkipsDirectoriesWithoutMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let orphan = store.meetingsDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)

        let meetings = try store.loadMeetings()

        XCTAssertTrue(meetings.isEmpty)
    }

    func testUpdatesMeetingMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        var created = try store.createMeeting(
            id: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!,
            name: "Teams",
            startedAt: Date(timeIntervalSince1970: 100)
        )
        created.record.endedAt = Date(timeIntervalSince1970: 300)

        try store.save(created.record)
        let loaded = try store.loadMeetings()

        XCTAssertEqual(loaded.first?.endedAt, Date(timeIntervalSince1970: 300))
    }

    func testPersistsMeetingGoalInMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        var created = try store.createMeeting(
            id: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
            name: "Teams",
            startedAt: Date(timeIntervalSince1970: 100)
        )
        created.record.meetingGoal = MeetingGoal(
            title: "Confirm launch plan",
            objectives: [MeetingObjective(id: "owner", title: "Confirm launch owner")],
            requiredQuestions: ["Have we confirmed the deadline?"],
            expectedDecisions: [],
            keyTerms: [MeetingKeyTerm(value: "launch")]
        )

        try store.save(created.record)
        let loaded = try store.loadMeetings()

        XCTAssertEqual(loaded.first?.meetingGoal?.title, "Confirm launch plan")
        XCTAssertEqual(loaded.first?.meetingGoal?.objectives.first?.title, "Confirm launch owner")
        XCTAssertEqual(loaded.first?.meetingGoal?.keyTerms.first?.value, "launch")
    }

    func testLoadsLegacyMeetingMetadataWithDefaultSummaryURLs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let id = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
        let directory = store.meetingsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let metadata = """
        {
          "audioURL" : "\(directory.appendingPathComponent("audio.wav").absoluteString)",
          "endedAt" : "2026-04-25T10:10:00Z",
          "id" : "\(id.uuidString)",
          "name" : "Legacy Meeting",
          "startedAt" : "2026-04-25T10:00:00Z",
          "transcriptJSONURL" : "\(directory.appendingPathComponent("transcript.json").absoluteString)",
          "transcriptURL" : "\(directory.appendingPathComponent("transcript.txt").absoluteString)"
        }
        """
        try metadata.write(to: directory.appendingPathComponent("metadata.json"), atomically: true, encoding: .utf8)

        let loaded = try store.loadMeetings()

        XCTAssertEqual(loaded.first?.summaryJSONURL?.lastPathComponent, "summary.json")
        XCTAssertEqual(loaded.first?.summaryMarkdownURL?.lastPathComponent, "summary.md")
        XCTAssertEqual(loaded.first?.summaryJSONURL?.deletingLastPathComponent().lastPathComponent, id.uuidString)
        XCTAssertEqual(loaded.first?.summaryMarkdownURL?.deletingLastPathComponent().lastPathComponent, id.uuidString)
    }

    func testLoadMeetingsBackfillsTranscriptionProviderIDFromStructuredTranscript() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let created = try store.createMeeting(
            id: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!,
            name: "Deepgram Meeting",
            startedAt: Date(timeIntervalSince1970: 100)
        )
        let legacyMetadata = try String(contentsOf: created.metadataURL, encoding: .utf8)
            .replacingOccurrences(of: #"  "transcriptionProviderID" : "whisper","#, with: "")
        try legacyMetadata.write(to: created.metadataURL, atomically: true, encoding: .utf8)
        try FileTranscriptRepository().saveCaptionDocument(
            CaptionDocument(
                turns: [
                    CaptionTurn(
                        sections: [CaptionSection(text: "hello")],
                        state: .final,
                        source: CaptionTurnSource(providerID: "deepgram-transcribe")
                    )
                ],
                provider: CaptionProviderInfo(id: "deepgram-transcribe")
            ),
            for: created.record
        )

        let loaded = try store.loadMeetings()
        let saved = try JSONDecoder.meetingAgent.decode(MeetingRecord.self, from: Data(contentsOf: created.metadataURL))

        XCTAssertEqual(loaded.first?.transcriptionProviderID, "deepgram-transcribe")
        XCTAssertEqual(saved.transcriptionProviderID, "deepgram-transcribe")
    }

    func testLoadsLegacyMeetingMetadataWithDefaultMeetingProgressURL() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let id = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let directory = store.meetingsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let metadata = """
        {
          "audioURL" : "\(directory.appendingPathComponent("audio.wav").absoluteString)",
          "endedAt" : null,
          "id" : "\(id.uuidString)",
          "name" : "Legacy Meeting",
          "startedAt" : "2026-04-25T10:00:00Z",
          "transcriptJSONURL" : "\(directory.appendingPathComponent("transcript.json").absoluteString)",
          "transcriptURL" : "\(directory.appendingPathComponent("transcript.txt").absoluteString)"
        }
        """
        try metadata.write(to: directory.appendingPathComponent("metadata.json"), atomically: true, encoding: .utf8)

        let loaded = try store.loadMeetings()
        let saved = try JSONDecoder.meetingAgent.decode(MeetingRecord.self, from: Data(contentsOf: directory.appendingPathComponent("metadata.json")))

        XCTAssertEqual(loaded.first?.meetingProgressJSONURL?.lastPathComponent, "meeting-progress.json")
        XCTAssertEqual(saved.meetingProgressJSONURL?.lastPathComponent, "meeting-progress.json")
        XCTAssertEqual(loaded.first?.performanceEventsURL?.lastPathComponent, "performance-events.jsonl")
        XCTAssertEqual(saved.performanceEventsURL?.lastPathComponent, "performance-events.jsonl")
    }
}
