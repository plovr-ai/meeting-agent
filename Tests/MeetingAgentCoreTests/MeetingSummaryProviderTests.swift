import XCTest
@testable import MeetingAgentCore

final class MeetingSummaryProviderTests: XCTestCase {
    func testExtractiveProviderSeparatesSummarySectionsWithSourceIDs() async throws {
        let provider = ExtractiveMeetingSummaryProvider()
        let summary = try await provider.generateSummary(
            input: MeetingSummaryInput(
                meetingName: "Launch Review",
                startedAt: Date(timeIntervalSince1970: 1_777_000_000),
                endedAt: Date(timeIntervalSince1970: 1_777_000_600),
                language: "en-US",
                meetingGoal: nil,
                segments: [
                    TranscriptSegment(id: "segment-1", text: "We decided to launch on May 1.", language: "en-US"),
                    TranscriptSegment(id: "segment-2", text: "Alex will follow up with legal.", language: "en-US"),
                    TranscriptSegment(id: "segment-3", text: "Can support staff the launch?", language: "en-US"),
                    TranscriptSegment(id: "segment-4", text: "The main risk is legal review delay.", language: "en-US")
                ],
                generatedAt: Date(timeIntervalSince1970: 1_777_000_700)
            )
        )

        XCTAssertEqual(summary.status, .succeeded)
        XCTAssertEqual(summary.language, "en-US")
        XCTAssertEqual(summary.provider, "extractive-local")
        XCTAssertEqual(summary.sourceSegmentIDs, ["segment-1", "segment-2", "segment-3", "segment-4"])
        XCTAssertEqual(summary.decisions.first?.description, "We decided to launch on May 1.")
        XCTAssertEqual(summary.decisions.first?.sourceSegmentIDs, ["segment-1"])
        XCTAssertEqual(summary.actionItems.first?.description, "Alex will follow up with legal.")
        XCTAssertEqual(summary.actionItems.first?.sourceSegmentIDs, ["segment-2"])
        XCTAssertEqual(summary.openQuestions, ["Can support staff the launch?"])
        XCTAssertEqual(summary.risks, ["The main risk is legal review delay."])
        XCTAssertEqual(summary.followUps, ["Alex will follow up with legal."])
    }

    func testExtractiveProviderFailsForEmptyTranscript() async throws {
        let provider = ExtractiveMeetingSummaryProvider()

        let summary = try await provider.generateSummary(
            input: MeetingSummaryInput(
                meetingName: "Empty Meeting",
                startedAt: Date(timeIntervalSince1970: 1_777_000_000),
                endedAt: nil,
                language: "en-US",
                meetingGoal: nil,
                segments: [TranscriptSegment(id: "blank", text: "   ")],
                generatedAt: Date(timeIntervalSince1970: 1_777_000_100)
            )
        )

        XCTAssertEqual(summary.status, .failed)
        XCTAssertEqual(summary.failureReason, "No usable transcript segments were available for summary generation.")
        XCTAssertEqual(summary.sourceSegmentIDs, [])
    }

    func testOpenRouterProviderBuildsRequestAndParsesSummary() async throws {
        let client = RecordingOpenRouterChatClient(responseContent: """
        {
          "overview": "The team aligned on launch scope.",
          "keyTopics": ["Launch"],
          "decisions": [
            {
              "description": "Approved the launch date.",
              "participants": ["Alex"],
              "sourceSegmentIDs": ["segment-1"],
              "confidence": 0.82
            }
          ],
          "actionItems": [
            {
              "description": "Alex will follow up with legal.",
              "owner": "Alex",
              "dueDate": null,
              "sourceSegmentIDs": ["segment-2"],
              "confidence": 0.76
            }
          ],
          "openQuestions": ["Can support staff the launch?"],
          "risks": ["Legal review may delay launch."],
          "followUps": ["Alex will follow up with legal."]
        }
        """)
        let provider = OpenRouterMeetingSummaryProvider(
            configuration: OpenRouterChatConfiguration(apiKey: "test-key", model: "openai/gpt-4.1-mini"),
            client: client
        )

        let summary = try await provider.generateSummary(
            input: MeetingSummaryInput(
                meetingName: "Launch Review",
                startedAt: Date(timeIntervalSince1970: 1_777_000_000),
                endedAt: Date(timeIntervalSince1970: 1_777_000_600),
                language: "en-US",
                meetingGoal: nil,
                segments: [
                    TranscriptSegment(id: "segment-1", text: "We decided to launch on May 1.", language: "en-US"),
                    TranscriptSegment(id: "segment-2", text: "Alex will follow up with legal.", language: "en-US")
                ],
                generatedAt: Date(timeIntervalSince1970: 1_777_000_700)
            )
        )

        XCTAssertEqual(summary.status, .succeeded)
        XCTAssertEqual(summary.provider, "openrouter:openai/gpt-4.1-mini")
        XCTAssertEqual(summary.language, "en-US")
        XCTAssertEqual(summary.generatedAt, Date(timeIntervalSince1970: 1_777_000_700))
        XCTAssertEqual(summary.sourceSegmentIDs, ["segment-1", "segment-2"])
        XCTAssertEqual(summary.overview, "The team aligned on launch scope.")
        XCTAssertEqual(summary.decisions.first?.description, "Approved the launch date.")
        XCTAssertEqual(summary.decisions.first?.sourceSegmentIDs, ["segment-1"])
        XCTAssertEqual(summary.actionItems.first?.owner, "Alex")
        XCTAssertEqual(client.requests.first?.apiKey, "test-key")
        XCTAssertEqual(client.requests.first?.model, "openai/gpt-4.1-mini")
        XCTAssertEqual(client.requests.first?.responseFormat?.type, "json_object")
        XCTAssertEqual(client.requests.first?.messages.first?.role, "system")
        XCTAssertTrue(client.requests.first?.messages.last?.content.contains("segment-1") == true)
    }

    func testOpenRouterProviderFailsWhenConfigurationIsMissing() async throws {
        let provider = OpenRouterMeetingSummaryProvider(
            configuration: .unavailable("OpenRouter API key is not configured"),
            client: RecordingOpenRouterChatClient(responseContent: "{}")
        )

        let summary = try await provider.generateSummary(
            input: MeetingSummaryInput(
                meetingName: "Launch Review",
                startedAt: Date(timeIntervalSince1970: 1_777_000_000),
                endedAt: nil,
                language: "en-US",
                meetingGoal: nil,
                segments: [TranscriptSegment(id: "segment-1", text: "We decided to launch on May 1.")],
                generatedAt: Date(timeIntervalSince1970: 1_777_000_100)
            )
        )

        XCTAssertEqual(summary.status, .failed)
        XCTAssertEqual(summary.provider, "openrouter")
        XCTAssertEqual(summary.failureReason, "OpenRouter API key is not configured")
        XCTAssertEqual(summary.sourceSegmentIDs, ["segment-1"])
    }

    func testSummaryWriterWritesJSONAndMarkdownTogether() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("summary-writer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let jsonURL = directory.appendingPathComponent("summary.json")
        let markdownURL = directory.appendingPathComponent("summary.md")
        let summary = MeetingSummary(
            overview: "The team aligned on launch scope.",
            keyTopics: ["Launch"],
            decisions: [
                MeetingDecision(
                    description: "Approved the launch date.",
                    participants: ["User A"],
                    sourceSegmentIDs: ["segment-1"],
                    confidence: 0.8
                )
            ],
            actionItems: [
                MeetingActionItem(
                    description: "Follow up with legal.",
                    owner: "User B",
                    dueDate: nil,
                    sourceSegmentIDs: ["segment-2"],
                    confidence: 0.7
                )
            ],
            openQuestions: ["Can support staff the launch?"],
            risks: ["Legal review may delay launch."],
            followUps: ["Schedule launch review."],
            language: "en-US",
            sourceSegmentIDs: ["segment-1", "segment-2"],
            generatedAt: Date(timeIntervalSince1970: 1_777_000_000),
            provider: "extractive-local",
            status: .succeeded,
            failureReason: nil
        )

        try MeetingSummaryWriter.write(summary, jsonURL: jsonURL, markdownURL: markdownURL)

        XCTAssertEqual(try MeetingSummaryWriter.read(from: jsonURL), summary)
        let markdown = try String(contentsOf: markdownURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("# Meeting Summary"))
        XCTAssertTrue(markdown.contains("The team aligned on launch scope."))
        XCTAssertTrue(markdown.contains("Approved the launch date."))
        XCTAssertTrue(markdown.contains("Follow up with legal."))
        XCTAssertTrue(markdown.contains("Can support staff the launch?"))
    }

    func testMarkdownRendererIncludesFailureReason() {
        let summary = MeetingSummary(
            overview: "",
            keyTopics: [],
            decisions: [],
            actionItems: [],
            openQuestions: [],
            risks: [],
            followUps: [],
            language: "en-US",
            sourceSegmentIDs: [],
            generatedAt: Date(timeIntervalSince1970: 1_777_000_000),
            provider: "extractive-local",
            status: .failed,
            failureReason: "No transcript was available."
        )

        let markdown = MeetingSummaryMarkdownRenderer.render(summary)

        XCTAssertTrue(markdown.contains("Status: failed"))
        XCTAssertTrue(markdown.contains("No transcript was available."))
    }
}

private final class RecordingOpenRouterChatClient: OpenRouterChatClient {
    struct Request: Equatable {
        let apiKey: String
        let model: String
        let messages: [OpenRouterChatMessage]
        let responseFormat: OpenRouterResponseFormat?
    }

    private(set) var requests: [Request] = []
    private let responseContent: String

    init(responseContent: String) {
        self.responseContent = responseContent
    }

    func complete(
        configuration: OpenRouterChatConfiguration,
        messages: [OpenRouterChatMessage],
        responseFormat: OpenRouterResponseFormat?
    ) async throws -> String {
        requests.append(Request(
            apiKey: configuration.apiKey,
            model: configuration.model,
            messages: messages,
            responseFormat: responseFormat
        ))
        return responseContent
    }
}
