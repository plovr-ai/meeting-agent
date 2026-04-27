import XCTest
@testable import MeetingAgentCore

final class GoalOrientedSummaryTests: XCTestCase {
    func testGeneratesSummaryFromTranscriptAndProgress() {
        let progress = MeetingProgressState(
            meetingID: UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!,
            goal: MeetingGoal(title: "Confirm launch plan", objectives: [], requiredQuestions: [], expectedDecisions: [], keyTerms: []),
            status: .onTrack,
            objectives: [],
            confirmedItems: ["Launch owner confirmed"],
            unresolvedItems: ["Launch deadline"],
            suggestedQuestions: [
                FollowUpQuestionSuggestion(chinese: "是否确认截止时间？", english: "Have we confirmed the deadline?", sourceObjectiveID: nil)
            ],
            health: MeetingProgressHealth(caption: .live, translation: .live, analysis: .live),
            lastAnalyzedSegmentID: "segment-1",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let transcript = TranscriptDocument(segments: [
            TranscriptSegment(id: "segment-1", text: "Alex owns the launch.", language: "en-US")
        ])

        let summary = GoalOrientedSummaryProvider().generate(
            transcript: transcript,
            progress: progress,
            generatedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(summary.provider, "goal-oriented-deterministic")
        XCTAssertTrue(summary.overview.contains("Confirm launch plan"))
        XCTAssertEqual(summary.keyTopics, ["Goal status: on track"])
        XCTAssertEqual(summary.followUps, ["Have we confirmed the deadline?"])
        XCTAssertEqual(summary.openQuestions, ["Launch deadline"])
        XCTAssertEqual(summary.sourceSegmentIDs, ["segment-1"])
    }

    func testHandlesMissingProgressSnapshot() {
        let summary = GoalOrientedSummaryProvider().generate(
            transcript: TranscriptDocument(segments: [TranscriptSegment(id: "segment-1", text: "hello")]),
            progress: nil,
            generatedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(summary.status, .succeeded)
        XCTAssertTrue(summary.overview.contains("No meeting progress snapshot"))
        XCTAssertEqual(summary.sourceSegmentIDs, ["segment-1"])
    }
}
