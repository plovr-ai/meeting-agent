import XCTest
@testable import MeetingAgentCore

final class MeetingRecordTests: XCTestCase {
    func testProcessWithMicrophoneSourcePreservesTargetAndKind() {
        let target = AudioCaptureTarget(processID: 42, displayName: "Zoom", bundleIdentifier: "us.zoom.xos")
        let source = AudioCaptureSource.processWithMicrophone(target, microphoneDisplayName: "Studio Mic")

        XCTAssertEqual(source.kind, .processWithMicrophone)
        XCTAssertEqual(source.displayName, "Zoom")
        XCTAssertEqual(source.processID, 42)
        XCTAssertEqual(source.processTarget, target)
        XCTAssertEqual(source.microphoneDisplayName, "Studio Mic")
    }

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
            microphoneAudioURL: URL(fileURLWithPath: "/tmp/audio-microphone.wav"),
            transcriptURL: URL(fileURLWithPath: "/tmp/transcript.txt"),
            transcriptJSONURL: URL(fileURLWithPath: "/tmp/transcript.json"),
            meetingProgressJSONURL: URL(fileURLWithPath: "/tmp/meeting-progress.json"),
            summaryURL: URL(fileURLWithPath: "/tmp/summary.md"),
            summaryJSONURL: URL(fileURLWithPath: "/tmp/summary.json"),
            summaryMarkdownURL: URL(fileURLWithPath: "/tmp/summary.md"),
            transcriptionStatus: .transcribed,
            transcriptionFailureReason: nil,
            transcriptRefinement: TranscriptRefinementMetadata(
                providerID: "deepgram-batch-transcribe",
                modelID: "nova-3",
                status: .refined,
                durationSeconds: 1.5,
                updatedAt: Date(timeIntervalSince1970: 1_777_000_601)
            ),
            speechProvider: .whisper,
            transcriptionProviderID: "deepgram-transcribe",
            speechLocaleIdentifier: "zh-CN",
            captureMode: .processWithMicrophone,
            meetingGoal: MeetingGoal(
                id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                title: "Confirm launch plan",
                objectives: [MeetingObjective(id: "owner", title: "Confirm launch owner")],
                requiredQuestions: ["Have we confirmed the deadline?"],
                expectedDecisions: [],
                keyTerms: [MeetingKeyTerm(value: "launch")]
            ),
            meetingGoals: [
                MeetingGoal(
                    id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                    title: "Confirm launch plan",
                    objectives: [MeetingObjective(id: "owner", title: "Confirm launch owner")],
                    requiredQuestions: ["Have we confirmed the deadline?"],
                    expectedDecisions: [],
                    keyTerms: [MeetingKeyTerm(value: "launch")]
                ),
                MeetingGoal(
                    id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                    title: "Align support plan",
                    objectives: [],
                    requiredQuestions: [],
                    expectedDecisions: [],
                    keyTerms: []
                )
            ],
            attendees: [
                MeetingAttendee(
                    id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
                    name: "Li Wei",
                    role: "Shanghai GM"
                )
            ],
            agendaTopics: [
                MeetingAgendaTopic(
                    id: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
                    title: "Launch risks"
                )
            ],
            scheduledStartAt: Date(timeIntervalSince1970: 1_776_999_600),
            scheduledEndAt: Date(timeIntervalSince1970: 1_777_000_500)
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

    func testBlankProviderAndLocaleFallBackToDefaults() {
        let record = MeetingRecord(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            name: "Google Meet",
            startedAt: Date(timeIntervalSince1970: 1_777_000_000),
            endedAt: nil,
            audioURL: nil,
            transcriptURL: nil,
            speechProvider: .local,
            transcriptionProviderID: "   ",
            speechLocaleIdentifier: "   "
        )

        XCTAssertEqual(record.transcriptionProviderID, "local")
        XCTAssertEqual(record.speechLocaleIdentifier, "en-US")
    }

    func testMeetingRecordInitializerDerivesMeetingGoalsFromLegacyGoal() {
        let goal = MeetingGoal(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            title: "Confirm launch plan",
            objectives: [],
            requiredQuestions: [],
            expectedDecisions: [],
            keyTerms: []
        )

        let record = MeetingRecord(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            name: "Google Meet",
            startedAt: Date(timeIntervalSince1970: 1_777_000_000),
            endedAt: nil,
            audioURL: nil,
            transcriptURL: nil,
            meetingGoal: goal
        )

        XCTAssertEqual(record.meetingGoal?.title, "Confirm launch plan")
        XCTAssertEqual(record.meetingGoals.map(\.title), ["Confirm launch plan"])
    }

    func testMeetingRecordInitializerDefaultsToNoGoals() {
        let record = MeetingRecord(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            name: "Google Meet",
            startedAt: Date(timeIntervalSince1970: 1_777_000_000),
            endedAt: nil,
            audioURL: nil,
            transcriptURL: nil
        )

        XCTAssertNil(record.meetingGoal)
        XCTAssertEqual(record.meetingGoals, [])
    }

    func testMeetingRecordInitializerFallsBackFromBlankProviderAndLocale() {
        let record = MeetingRecord(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            name: "Google Meet",
            startedAt: Date(timeIntervalSince1970: 1_777_000_000),
            endedAt: nil,
            audioURL: nil,
            transcriptURL: nil,
            transcriptionProviderID: "   ",
            speechLocaleIdentifier: "   "
        )

        XCTAssertEqual(record.transcriptionProviderID, "whisper")
        XCTAssertEqual(record.speechLocaleIdentifier, "en-US")
    }

    func testMeetingAgendaUpdateDerivesMeetingGoalsFromLegacyGoal() {
        let goal = MeetingGoal(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            title: "Confirm launch plan",
            objectives: [],
            requiredQuestions: [],
            expectedDecisions: [],
            keyTerms: []
        )

        let update = MeetingAgendaUpdate(
            name: "Planning",
            attendees: [],
            agendaTopics: [],
            scheduledStartAt: nil,
            scheduledEndAt: nil,
            meetingGoal: goal
        )

        XCTAssertEqual(update.meetingGoal?.title, "Confirm launch plan")
        XCTAssertEqual(update.meetingGoals.map(\.title), ["Confirm launch plan"])
    }

    func testMeetingAgendaUpdateDefaultsToNoGoals() {
        let update = MeetingAgendaUpdate(
            name: "Planning",
            attendees: [],
            agendaTopics: [],
            scheduledStartAt: nil,
            scheduledEndAt: nil,
            meetingGoal: nil
        )

        XCTAssertNil(update.meetingGoal)
        XCTAssertEqual(update.meetingGoals, [])
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
        XCTAssertNil(decoded.microphoneAudioURL)
        XCTAssertEqual(decoded.captureMode, .process)
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

    func testDecodesLegacyMeetingGoalIntoMeetingGoals() throws {
        let json = """
        {
          "audioURL" : "file:\\/\\/\\/tmp\\/audio.wav",
          "endedAt" : null,
          "id" : "11111111-1111-1111-1111-111111111111",
          "meetingGoal" : {
            "expectedDecisions" : [],
            "id" : "22222222-2222-2222-2222-222222222222",
            "keyTerms" : [],
            "objectives" : [],
            "requiredQuestions" : [],
            "title" : "Confirm launch plan"
          },
          "name" : "Google Meet",
          "startedAt" : "2026-04-25T10:00:00Z",
          "transcriptJSONURL" : "file:\\/\\/\\/tmp\\/transcript.json",
          "transcriptURL" : "file:\\/\\/\\/tmp\\/transcript.txt"
        }
        """

        let decoded = try JSONDecoder.meetingAgent.decode(MeetingRecord.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.meetingGoals.map(\.title), ["Confirm launch plan"])
        XCTAssertEqual(decoded.meetingGoal?.title, "Confirm launch plan")
    }

    func testDecodesMeetingGoalsIntoLegacyFirstGoal() throws {
        let json = """
        {
          "audioURL" : "file:\\/\\/\\/tmp\\/audio.wav",
          "endedAt" : null,
          "id" : "11111111-1111-1111-1111-111111111111",
          "meetingGoals" : [
            {
              "expectedDecisions" : [],
              "id" : "22222222-2222-2222-2222-222222222222",
              "keyTerms" : [],
              "objectives" : [],
              "requiredQuestions" : [],
              "title" : "Align rollout"
            },
            {
              "expectedDecisions" : [],
              "id" : "33333333-3333-3333-3333-333333333333",
              "keyTerms" : [],
              "objectives" : [],
              "requiredQuestions" : [],
              "title" : "Confirm owner"
            }
          ],
          "name" : "Google Meet",
          "startedAt" : "2026-04-25T10:00:00Z",
          "transcriptJSONURL" : "file:\\/\\/\\/tmp\\/transcript.json",
          "transcriptURL" : "file:\\/\\/\\/tmp\\/transcript.txt"
        }
        """

        let decoded = try JSONDecoder.meetingAgent.decode(MeetingRecord.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.meetingGoals.map(\.title), ["Align rollout", "Confirm owner"])
        XCTAssertEqual(decoded.meetingGoal?.title, "Align rollout")
    }

    func testDecodesLegacyMetadataWithoutAgendaFields() throws {
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

        XCTAssertEqual(decoded.attendees, [])
        XCTAssertEqual(decoded.agendaTopics, [])
        XCTAssertEqual(decoded.meetingGoals, [])
        XCTAssertNil(decoded.scheduledStartAt)
        XCTAssertNil(decoded.scheduledEndAt)
    }
}
