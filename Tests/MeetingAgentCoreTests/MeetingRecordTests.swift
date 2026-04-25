import XCTest
@testable import MeetingAgentCore

final class MeetingRecordTests: XCTestCase {
    func testMeetingRecordEncodesAndDecodes() throws {
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let startedAt = Date(timeIntervalSince1970: 1_777_000_000)
        let endedAt = Date(timeIntervalSince1970: 1_777_000_600)
        let record = MeetingRecord(
            id: id,
            name: "Google Meet",
            startedAt: startedAt,
            endedAt: endedAt,
            audioURL: URL(fileURLWithPath: "/tmp/audio.wav"),
            transcriptURL: URL(fileURLWithPath: "/tmp/transcript.txt"),
            transcriptJSONURL: URL(fileURLWithPath: "/tmp/transcript.json"),
            summaryURL: URL(fileURLWithPath: "/tmp/summary.md"),
            transcriptionStatus: .transcribed,
            transcriptionFailureReason: nil,
            speechProvider: .whisper,
            speechLocaleIdentifier: "zh-CN"
        )

        let data = try JSONEncoder.meetingAgent.encode(record)
        let decoded = try JSONDecoder.meetingAgent.decode(MeetingRecord.self, from: data)

        XCTAssertEqual(decoded, record)
    }

    func testNewMeetingDefaultsToNotStartedTranscription() {
        let record = MeetingRecord(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            name: "Google Meet",
            startedAt: Date(timeIntervalSince1970: 1_777_000_000),
            endedAt: nil,
            audioURL: URL(fileURLWithPath: "/tmp/audio.wav"),
            transcriptURL: URL(fileURLWithPath: "/tmp/transcript.txt")
        )

        XCTAssertEqual(record.transcriptionStatus, .notStarted)
        XCTAssertNil(record.transcriptionFailureReason)
        XCTAssertEqual(record.speechProvider, .whisper)
        XCTAssertEqual(record.speechLocaleIdentifier, "en-US")
    }

    func testActiveRecordHasNoEndTime() {
        let record = MeetingRecord(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            name: "zoom.us",
            startedAt: Date(timeIntervalSince1970: 1_777_000_000),
            endedAt: nil,
            audioURL: nil,
            transcriptURL: nil
        )

        XCTAssertNil(record.endedAt)
    }

    func testDecodesMetadataWithoutDiagnosticsURL() throws {
        let json = """
        {
          "audioURL" : "file:\\/\\/\\/tmp\\/audio.wav",
          "endedAt" : null,
          "id" : "11111111-1111-1111-1111-111111111111",
          "name" : "Google Meet",
          "startedAt" : "2026-04-25T10:00:00Z",
          "transcriptURL" : "file:\\/\\/\\/tmp\\/transcript.txt"
        }
        """

        let decoded = try JSONDecoder.meetingAgent.decode(MeetingRecord.self, from: Data(json.utf8))

        XCTAssertNil(decoded.diagnosticsURL)
        XCTAssertNil(decoded.transcriptJSONURL)
        XCTAssertEqual(decoded.transcriptionStatus, .notStarted)
        XCTAssertNil(decoded.transcriptionFailureReason)
        XCTAssertEqual(decoded.speechProvider, .whisper)
        XCTAssertEqual(decoded.speechLocaleIdentifier, "en-US")
    }

    func testDecodesMetadataWithoutSummaryURL() throws {
        let json = """
        {
          "audioURL" : "file:\\/\\/\\/tmp\\/audio.wav",
          "diagnosticsURL" : "file:\\/\\/\\/tmp\\/diagnostics.json",
          "endedAt" : null,
          "id" : "11111111-1111-1111-1111-111111111111",
          "name" : "Google Meet",
          "startedAt" : "2026-04-25T10:00:00Z",
          "transcriptJSONURL" : "file:\\/\\/\\/tmp\\/transcript.json",
          "transcriptURL" : "file:\\/\\/\\/tmp\\/transcript.txt"
        }
        """

        let decoded = try JSONDecoder.meetingAgent.decode(MeetingRecord.self, from: Data(json.utf8))

        XCTAssertNil(decoded.summaryURL)
    }
}
