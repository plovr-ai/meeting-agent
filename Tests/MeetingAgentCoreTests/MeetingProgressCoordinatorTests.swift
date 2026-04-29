import XCTest
@testable import MeetingAgentCore

final class MeetingProgressCoordinatorTests: XCTestCase {
    func testAnalyzesOnlyFinalSegmentsAndPersistsSnapshot() async throws {
        let progressURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-progress-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: progressURL) }
        let analyzer = SpyProgressAnalyzer()
        var now = Date(timeIntervalSince1970: 100)
        let coordinator = MeetingProgressCoordinator(
            goal: sampleGoal(),
            analyzer: analyzer,
            progressURL: progressURL,
            minimumAnalysisInterval: 30,
            now: { now }
        )
        let partial = LiveCaptionTurn(sourceSegmentID: "partial", originalText: "partial", isFinal: false)
        let final = LiveCaptionTurn(sourceSegmentID: "final", originalText: "launch owner confirmed", isFinal: true)

        await coordinator.process(turns: [partial, final])

        XCTAssertEqual(analyzer.calls.map { $0.recentCaptions.map(\.sourceSegmentID) }, [["final"]])
        XCTAssertEqual(coordinator.state?.status, .onTrack)
        XCTAssertEqual(coordinator.analysisHealth, .live)
        XCTAssertTrue(FileManager.default.fileExists(atPath: progressURL.path))
        let saved = try JSONDecoder.meetingAgent.decode(MeetingProgressState.self, from: Data(contentsOf: progressURL))
        XCTAssertEqual(saved.schemaVersion, 1)
        XCTAssertEqual(saved.lastAnalyzedSegmentID, "final")

        now = Date(timeIntervalSince1970: 110)
        await coordinator.process(turns: [partial, final, LiveCaptionTurn(sourceSegmentID: "final-2", originalText: "deadline confirmed", isFinal: true)])

        XCTAssertEqual(analyzer.calls.count, 1)
    }

    func testAnalyzerFailurePreservesPreviousStateAndMarksHealthFailed() async {
        let progressURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-progress-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: progressURL) }
        let analyzer = SpyProgressAnalyzer()
        let coordinator = MeetingProgressCoordinator(
            goal: sampleGoal(),
            analyzer: analyzer,
            progressURL: progressURL,
            minimumAnalysisInterval: 0,
            now: { Date(timeIntervalSince1970: 100) }
        )
        await coordinator.process(turns: [LiveCaptionTurn(sourceSegmentID: "final", originalText: "launch owner confirmed", isFinal: true)])
        let previousState = coordinator.state
        analyzer.error = NSError(domain: "test", code: 1)

        await coordinator.process(turns: [LiveCaptionTurn(sourceSegmentID: "final-2", originalText: "more text", isFinal: true)])

        XCTAssertEqual(coordinator.state, previousState)
        XCTAssertEqual(coordinator.analysisHealth, .failed("test error 1"))
    }

    func testPassesAgendaTopicsToAgendaAwareAnalyzer() async {
        let progressURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-progress-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: progressURL) }
        let analyzer = AgendaAwareSpyProgressAnalyzer()
        let topics = [MeetingAgendaTopic(title: "Budget risk")]
        let coordinator = MeetingProgressCoordinator(
            goal: sampleGoal(),
            agendaTopics: topics,
            analyzer: analyzer,
            progressURL: progressURL,
            minimumAnalysisInterval: 0,
            now: { Date(timeIntervalSince1970: 100) }
        )

        await coordinator.process(turns: [LiveCaptionTurn(sourceSegmentID: "final", originalText: "launch owner confirmed", isFinal: true)])

        XCTAssertEqual(analyzer.agendaTopics, topics)
    }

    private func sampleGoal() -> MeetingGoal {
        MeetingGoal(
            id: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
            title: "Confirm launch plan",
            objectives: [
                MeetingObjective(id: "owner", title: "Confirm launch owner", keywords: ["launch owner"]),
                MeetingObjective(id: "deadline", title: "Confirm launch deadline", keywords: ["deadline"])
            ],
            requiredQuestions: ["Who owns launch?"],
            expectedDecisions: ["Launch owner"],
            keyTerms: []
        )
    }
}

private final class SpyProgressAnalyzer: MeetingProgressAnalyzing {
    struct Call {
        let recentCaptions: [LiveCaptionTurn]
    }

    var calls: [Call] = []
    var error: Error?

    func analyze(
        goal: MeetingGoal,
        recentCaptions: [LiveCaptionTurn],
        previousState: MeetingProgressState?
    ) async throws -> MeetingProgressState {
        calls.append(Call(recentCaptions: recentCaptions))
        if let error {
            throw error
        }
        return MeetingProgressState(
            meetingID: UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!,
            goal: goal,
            status: .onTrack,
            objectives: goal.objectives.map {
                MeetingObjectiveProgress(objectiveID: $0.id, title: $0.title, status: .confirmed, evidenceSegmentIDs: recentCaptions.map(\.sourceSegmentID))
            },
            confirmedItems: ["launch owner confirmed"],
            unresolvedItems: [],
            suggestedQuestions: [],
            health: MeetingProgressHealth(caption: .live, translation: .pending, analysis: .live),
            lastAnalyzedSegmentID: recentCaptions.last?.sourceSegmentID,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
    }
}

private final class AgendaAwareSpyProgressAnalyzer: AgendaAwareMeetingProgressAnalyzing {
    var agendaTopics: [MeetingAgendaTopic] = []

    func analyze(
        goal: MeetingGoal,
        recentCaptions: [LiveCaptionTurn],
        previousState: MeetingProgressState?
    ) async throws -> MeetingProgressState {
        try await analyze(goal: goal, agendaTopics: [], recentCaptions: recentCaptions, previousState: previousState)
    }

    func analyze(
        goal: MeetingGoal,
        agendaTopics: [MeetingAgendaTopic],
        recentCaptions: [LiveCaptionTurn],
        previousState: MeetingProgressState?
    ) async throws -> MeetingProgressState {
        self.agendaTopics = agendaTopics
        return MeetingProgressState(
            meetingID: UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!,
            goal: goal,
            status: .onTrack,
            objectives: [],
            confirmedItems: [],
            unresolvedItems: [],
            suggestedQuestions: [],
            health: MeetingProgressHealth(caption: .live, translation: .pending, analysis: .live),
            lastAnalyzedSegmentID: recentCaptions.last?.sourceSegmentID,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
    }
}
