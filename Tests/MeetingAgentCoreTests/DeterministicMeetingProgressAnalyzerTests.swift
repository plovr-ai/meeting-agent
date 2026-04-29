import XCTest
@testable import MeetingAgentCore

final class DeterministicMeetingProgressAnalyzerTests: XCTestCase {
    func testMarksObjectivesConfirmedFromMatchingCaptions() async throws {
        let analyzer = DeterministicMeetingProgressAnalyzer(meetingID: UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!)
        let goal = MeetingGoal(
            id: UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!,
            title: "Confirm launch plan",
            objectives: [
                MeetingObjective(id: "owner", title: "Confirm launch owner", keywords: ["owner"]),
                MeetingObjective(id: "deadline", title: "Confirm launch deadline", keywords: ["deadline"])
            ],
            requiredQuestions: ["Have we confirmed the deadline?"],
            expectedDecisions: ["Launch owner and deadline"],
            keyTerms: [MeetingKeyTerm(value: "Project Atlas", translationHint: "阿特拉斯项目")]
        )

        let state = try await analyzer.analyze(
            goal: goal,
            recentCaptions: [
                LiveCaptionTurn(sourceSegmentID: "segment-1", originalText: "Alex is the launch owner.", isFinal: true)
            ],
            previousState: nil
        )

        XCTAssertEqual(state.objectives.first { $0.objectiveID == "owner" }?.status, .confirmed)
        XCTAssertEqual(state.objectives.first { $0.objectiveID == "deadline" }?.status, .unresolved)
        XCTAssertEqual(state.status, .partiallyCovered)
        XCTAssertEqual(state.unresolvedItems, ["Confirm launch deadline"])
        XCTAssertEqual(state.suggestedQuestions.count, 1)
        XCTAssertEqual(state.suggestedQuestions.first?.english, "Could we clarify launch deadline?")
        XCTAssertEqual(state.suggestedQuestions.first?.sourceObjectiveID, "deadline")
        XCTAssertFalse(state.suggestedQuestions.first?.chinese.isEmpty ?? true)
    }

    func testRecommendedQuestionsAreDecoupledFromRequiredQuestionsAndBoundedToTwo() async throws {
        let analyzer = DeterministicMeetingProgressAnalyzer()
        let goal = MeetingGoal(
            title: "Confirm launch plan",
            objectives: [
                MeetingObjective(id: "owner", title: "Confirm launch owner"),
                MeetingObjective(id: "deadline", title: "Confirm launch deadline"),
                MeetingObjective(id: "budget", title: "Confirm launch budget")
            ],
            requiredQuestions: ["This configured question should not be used"],
            expectedDecisions: [],
            keyTerms: []
        )

        let state = try await analyzer.analyze(
            goal: goal,
            recentCaptions: [LiveCaptionTurn(sourceSegmentID: "segment-1", originalText: "hello", isFinal: true)],
            previousState: nil
        )

        XCTAssertEqual(state.suggestedQuestions.map(\.english), [
            "Could we clarify launch owner?",
            "Could we clarify launch deadline?"
        ])
    }

    func testFallsBackToUncoveredAgendaTopicsWhenNoObjectivesExist() async throws {
        let analyzer = DeterministicMeetingProgressAnalyzer()
        let goal = MeetingGoal(
            title: "Weekly operating review",
            objectives: [],
            requiredQuestions: [],
            expectedDecisions: [],
            keyTerms: []
        )

        let state = try await analyzer.analyze(
            goal: goal,
            agendaTopics: [
                MeetingAgendaTopic(title: "Hiring plan"),
                MeetingAgendaTopic(title: "Budget risk"),
                MeetingAgendaTopic(title: "Launch readiness")
            ],
            recentCaptions: [LiveCaptionTurn(sourceSegmentID: "segment-1", originalText: "We already covered hiring plan.", isFinal: true)],
            previousState: nil
        )

        XCTAssertEqual(state.suggestedQuestions.map(\.english), [
            "Could we clarify Budget risk?",
            "Could we clarify Launch readiness?"
        ])
    }

    func testOmitsRecommendedQuestionsWithoutObjectiveOrTopicContext() async throws {
        let analyzer = DeterministicMeetingProgressAnalyzer()
        let goal = MeetingGoal(
            title: "Weekly sync",
            objectives: [],
            requiredQuestions: ["Should not be shown"],
            expectedDecisions: [],
            keyTerms: []
        )

        let state = try await analyzer.analyze(
            goal: goal,
            recentCaptions: [LiveCaptionTurn(sourceSegmentID: "segment-1", originalText: "hello", isFinal: true)],
            previousState: nil
        )

        XCTAssertEqual(state.suggestedQuestions, [])
    }
}
