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
            meetingProgressJSONURL: URL(fileURLWithPath: "/tmp/meeting-progress.json"),
            summaryURL: URL(fileURLWithPath: "/tmp/summary.md"),
            summaryJSONURL: URL(fileURLWithPath: "/tmp/summary.json"),
            summaryMarkdownURL: URL(fileURLWithPath: "/tmp/summary.md"),
            transcriptionStatus: .transcribed,
            transcriptionFailureReason: nil,
            speechProvider: .whisper,
            transcriptionProviderID: "deepgram-transcribe",
            speechLocaleIdentifier: "zh-CN",
            meetingGoal: MeetingGoal(
                id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                title: "Confirm launch plan",
                objectives: [MeetingObjective(id: "owner", title: "Confirm launch owner")],
                requiredQuestions: ["Have we confirmed the deadline?"],
                expectedDecisions: [],
                keyTerms: [MeetingKeyTerm(value: "launch")]
            )
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
        XCTAssertEqual(record.transcriptionProviderID, "whisper")
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
        XCTAssertEqual(decoded.transcriptionProviderID, "whisper")
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
        XCTAssertNil(decoded.summaryJSONURL)
        XCTAssertNil(decoded.summaryMarkdownURL)
    }

    func testDecodesMetadataWithoutMeetingProgressURL() throws {
        let json = """
        {
          "audioURL" : "file:\\/\\/\\/tmp\\/audio.wav",
          "endedAt" : null,
          "id" : "11111111-1111-1111-1111-111111111111",
          "name" : "Google Meet",
          "startedAt" : "2026-04-25T10:00:00Z",
          "transcriptJSONURL" : "file:\\/\\/\\/tmp\\/transcript.json",
          "transcriptURL" : "file:\\/\\/\\/tmp\\/transcript.txt"
        }
        """

        let decoded = try JSONDecoder.meetingAgent.decode(MeetingRecord.self, from: Data(json.utf8))

        XCTAssertNil(decoded.meetingProgressJSONURL)
    }

    func testDecodesMetadataWithoutMeetingGoal() throws {
        let json = """
        {
          "audioURL" : "file:\\/\\/\\/tmp\\/audio.wav",
          "endedAt" : null,
          "id" : "11111111-1111-1111-1111-111111111111",
          "name" : "Google Meet",
          "startedAt" : "2026-04-25T10:00:00Z",
          "transcriptJSONURL" : "file:\\/\\/\\/tmp\\/transcript.json",
          "transcriptURL" : "file:\\/\\/\\/tmp\\/transcript.txt"
        }
        """

        let decoded = try JSONDecoder.meetingAgent.decode(MeetingRecord.self, from: Data(json.utf8))

        XCTAssertNil(decoded.meetingGoal)
    }
}
