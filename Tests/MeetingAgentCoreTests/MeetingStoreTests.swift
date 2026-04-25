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
        XCTAssertEqual(created.record.transcriptURL?.lastPathComponent, "transcript.txt")
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
}
