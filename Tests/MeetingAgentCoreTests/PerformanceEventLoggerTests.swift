import XCTest
@testable import MeetingAgentCore

final class PerformanceEventLoggerTests: XCTestCase {
    func testAppendsJSONLinesWithoutThrowing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("performance-events-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("performance-events.jsonl")
        var now = Date(timeIntervalSince1970: 1_000)
        let logger = PerformanceEventLogger(url: url) { now }

        logger.log(
            "recording_started",
            audioTimeSeconds: 1.5,
            segmentID: "segment-1",
            isFinal: true,
            textLength: 5,
            metadata: ["provider": "deepgram-transcribe"]
        )
        now = Date(timeIntervalSince1970: 1_001)
        logger.log("recording_stopped")

        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(lines.count, 2)

        let first = try JSONDecoder.meetingAgent.decode(PerformanceEvent.self, from: Data(lines[0].utf8))
        let second = try JSONDecoder.meetingAgent.decode(PerformanceEvent.self, from: Data(lines[1].utf8))
        XCTAssertEqual(first.event, "recording_started")
        XCTAssertEqual(first.audioTimeSeconds, 1.5)
        XCTAssertEqual(first.segmentID, "segment-1")
        XCTAssertEqual(first.isFinal, true)
        XCTAssertEqual(first.textLength, 5)
        XCTAssertEqual(first.metadata["provider"], "deepgram-transcribe")
        XCTAssertEqual(second.event, "recording_stopped")
    }
}
