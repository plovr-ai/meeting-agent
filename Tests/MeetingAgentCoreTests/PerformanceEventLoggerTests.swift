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

    func testDurationMetadataRoundsElapsedMilliseconds() {
        let start = Date(timeIntervalSince1970: 1_000)
        let end = Date(timeIntervalSince1970: 1_000.124)

        let metadata = PerformanceEventLogger.durationMetadata(from: start, to: end)

        XCTAssertEqual(metadata["durationMilliseconds"], "124")
    }

    func testDeepgramRawResponseLogsWordTimingMetadataWhenResponseHasNoTopLevelTiming() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("performance-events-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("performance-events.jsonl")
        let logger = PerformanceEventLogger(url: url)
        let payload = Data(#"""
        {
          "type": "Results",
          "is_final": false,
          "speech_final": false,
          "channel": {
            "alternatives": [
              {
                "transcript": "hello world",
                "confidence": 0.99,
                "words": [
                  {"word": "hello", "start": 1.1, "end": 1.4, "confidence": 0.9},
                  {"word": "world", "start": 1.4, "end": 1.9, "confidence": 0.9}
                ]
              }
            ]
          }
        }
        """#.utf8)

        logger.logDeepgramRawResponse(
            payload,
            context: DeepgramRawResponseContext(providerID: "deepgram-transcribe-stream", transport: .webSocket)
        )

        let line = try XCTUnwrap(String(contentsOf: url, encoding: .utf8).split(separator: "\n").first)
        let event = try JSONDecoder.meetingAgent.decode(PerformanceEvent.self, from: Data(line.utf8))
        XCTAssertEqual(event.event, "deepgram_raw_response_received")
        XCTAssertEqual(event.audioTimeSeconds, 1.9)
        XCTAssertEqual(event.textLength, 11)
        XCTAssertEqual(event.metadata["firstWordStartSeconds"], "1.1")
        XCTAssertEqual(event.metadata["lastWordEndSeconds"], "1.9")
        XCTAssertEqual(event.metadata["wordCount"], "2")
        XCTAssertEqual(event.metadata["transport"], "webSocket")
    }
}
