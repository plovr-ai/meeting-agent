import XCTest
@testable import MeetingAgentCore

final class MeetingKnowledgePackageTests: XCTestCase {
    func testRendererProducesMeetingMarkdownWithFrontmatterSummaryAndLinks() {
        let package = makePackage()

        let markdown = MeetingKnowledgePackageMarkdownRenderer.renderMeeting(package)

        XCTAssertTrue(markdown.contains("type: meeting"))
        XCTAssertTrue(markdown.contains("meeting_id: 77777777-7777-7777-7777-777777777777"))
        XCTAssertTrue(markdown.contains("title: Japan GTM Sync"))
        XCTAssertTrue(markdown.contains("language: en-US"))
        XCTAssertTrue(markdown.contains("- Alice"))
        XCTAssertTrue(markdown.contains("# Japan GTM Sync"))
        XCTAssertTrue(markdown.contains("## One-Line Summary\nThe team agreed to a Tokyo-only pilot."))
        XCTAssertTrue(markdown.contains("- Q3 Japan launch will start with a Tokyo-only pilot."))
        XCTAssertTrue(markdown.contains("- Ken will confirm legal timing."))
        XCTAssertTrue(markdown.contains("- [[transcript]]"))
        XCTAssertTrue(markdown.contains("- [[knowledge]]"))
    }

    func testRendererProducesTranscriptMarkdownWithStableAnchorsAndSpeakerLabels() {
        let package = makePackage()

        let markdown = MeetingKnowledgePackageMarkdownRenderer.renderTranscript(package)

        XCTAssertTrue(markdown.contains("type: transcript"))
        XCTAssertTrue(markdown.contains("# Transcript"))
        XCTAssertTrue(markdown.contains(#"<a id="t-00-00-12"></a>"#))
        XCTAssertTrue(markdown.contains("## 00:00:12 Alice"))
        XCTAssertTrue(markdown.contains("Let's start with Tokyo for Q3."))
        XCTAssertTrue(markdown.contains(#"<a id="segment-segment-2"></a>"#))
        XCTAssertTrue(markdown.contains("## segment-2 Ken"))
        XCTAssertTrue(markdown.contains("I will confirm legal timing."))
    }

    func testRendererProducesKnowledgeMarkdownWithRequiredSectionsFieldsAndEvidenceLinks() {
        let package = makePackage()

        let markdown = MeetingKnowledgePackageMarkdownRenderer.renderKnowledge(package)

        XCTAssertTrue(markdown.contains("type: meeting_knowledge"))
        XCTAssertTrue(markdown.contains("status: proposed"))
        XCTAssertTrue(markdown.contains("## Facts"))
        XCTAssertTrue(markdown.contains("### fact_001"))
        XCTAssertTrue(markdown.contains("**Statement:** The launch scope is Tokyo-only for Q3."))
        XCTAssertTrue(markdown.contains("**Related:** [[Japan GTM]], [[Tokyo]]"))
        XCTAssertTrue(markdown.contains("**Confidence:** High"))
        XCTAssertTrue(markdown.contains("**Status:** Proposed"))
        XCTAssertTrue(markdown.contains("**Evidence:** [[transcript#t-00-00-12|Alice 00:00:12]]"))
        XCTAssertTrue(markdown.contains("## Judgments\n\nNo proposed items."))
        XCTAssertTrue(markdown.contains("## Decisions"))
        XCTAssertTrue(markdown.contains("### decision_001"))
        XCTAssertTrue(markdown.contains("## Actions"))
        XCTAssertTrue(markdown.contains("**Owner:** [[Ken]]"))
        XCTAssertTrue(markdown.contains("**Due:** 2026-05-15"))
        XCTAssertTrue(markdown.contains("## Open Questions"))
        XCTAssertTrue(markdown.contains("No proposed items."))
        XCTAssertTrue(markdown.contains("## Entity Updates"))
    }

    func testSummaryExtractorSeedsKnowledgeItemsFromExistingSummary() {
        let segments = [
            TranscriptSegment(
                id: "segment-1",
                speaker: TranscriptSpeaker(identifier: "a", label: "Alice"),
                startTimeSeconds: 12,
                text: "Let's start with Tokyo for Q3."
            ),
            TranscriptSegment(
                id: "segment-2",
                speaker: TranscriptSpeaker(identifier: "b", label: "Ken"),
                startTimeSeconds: 48,
                text: "I will confirm legal timing."
            )
        ]
        let summary = MeetingSummary(
            overview: "The team agreed to a Tokyo-only pilot.",
            keyTopics: ["Japan GTM"],
            decisions: [
                MeetingDecision(
                    description: "Q3 Japan launch will start with a Tokyo-only pilot.",
                    participants: ["Alice", "Ken"],
                    sourceSegmentIDs: ["segment-1"],
                    confidence: 0.91
                )
            ],
            actionItems: [
                MeetingActionItem(
                    description: "Ken will confirm legal timing.",
                    owner: "Ken",
                    dueDate: "2026-05-15",
                    sourceSegmentIDs: ["segment-2"],
                    confidence: 0.84
                )
            ],
            openQuestions: ["Does enterprise pricing need local adjustment?"],
            risks: ["Nationwide launch may create support risk."],
            followUps: [],
            language: "en-US",
            sourceSegmentIDs: ["segment-1", "segment-2"],
            generatedAt: Date(timeIntervalSince1970: 1_777_000_000),
            provider: "test",
            status: .succeeded,
            failureReason: nil
        )

        let knowledge = MeetingKnowledgeExtractor.fromSummary(summary, segments: segments)

        XCTAssertEqual(knowledge.facts.first?.statement, "Japan GTM")
        XCTAssertEqual(knowledge.judgments.first?.statement, "Nationwide launch may create support risk.")
        XCTAssertEqual(knowledge.decisions.first?.statement, "Q3 Japan launch will start with a Tokyo-only pilot.")
        XCTAssertEqual(knowledge.decisions.first?.evidence.first?.anchor, "t-00-00-12")
        XCTAssertEqual(knowledge.actions.first?.owner, "Ken")
        XCTAssertEqual(knowledge.actions.first?.due, "2026-05-15")
        XCTAssertEqual(knowledge.openQuestions.first?.question, "Does enterprise pricing need local adjustment?")
    }

    private func makePackage() -> MeetingKnowledgePackage {
        let record = MeetingRecord(
            id: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
            name: "Japan GTM Sync",
            startedAt: Date(timeIntervalSince1970: 1_777_000_000),
            endedAt: Date(timeIntervalSince1970: 1_777_000_600),
            audioURL: nil,
            transcriptURL: nil,
            transcriptionStatus: .transcribed,
            speechProvider: .whisper,
            transcriptionProviderID: "whisper",
            speechLocaleIdentifier: "en-US",
            meetingGoal: MeetingGoal(
                title: "Align on Japan launch scope",
                objectives: [],
                requiredQuestions: [],
                expectedDecisions: [],
                keyTerms: []
            ),
            attendees: [
                MeetingAttendee(name: "Alice"),
                MeetingAttendee(name: "Ken")
            ]
        )
        let segments = [
            TranscriptSegment(
                id: "segment-1",
                speaker: TranscriptSpeaker(identifier: "a", label: "Alice"),
                startTimeSeconds: 12,
                text: "Let's start with Tokyo for Q3."
            ),
            TranscriptSegment(
                id: "segment-2",
                speaker: TranscriptSpeaker(identifier: "b", label: "Ken"),
                text: "I will confirm legal timing."
            )
        ]
        let summary = MeetingSummary(
            overview: "The team agreed to a Tokyo-only pilot.",
            keyTopics: ["Japan GTM"],
            decisions: [
                MeetingDecision(
                    description: "Q3 Japan launch will start with a Tokyo-only pilot.",
                    participants: ["Alice", "Ken"],
                    sourceSegmentIDs: ["segment-1"],
                    confidence: 0.91
                )
            ],
            actionItems: [
                MeetingActionItem(
                    description: "Ken will confirm legal timing.",
                    owner: "Ken",
                    dueDate: "2026-05-15",
                    sourceSegmentIDs: ["segment-2"],
                    confidence: 0.84
                )
            ],
            openQuestions: [],
            risks: [],
            followUps: [],
            language: "en-US",
            sourceSegmentIDs: ["segment-1", "segment-2"],
            generatedAt: Date(timeIntervalSince1970: 1_777_000_000),
            provider: "test",
            status: .succeeded,
            failureReason: nil
        )
        let knowledge = MeetingKnowledge(
            facts: [
                MeetingKnowledgeItem(
                    id: "fact_001",
                    statement: "The launch scope is Tokyo-only for Q3.",
                    related: ["Japan GTM", "Tokyo"],
                    confidence: .high,
                    status: "Proposed",
                    evidence: [
                        MeetingKnowledgeEvidence(segmentID: "segment-1", speaker: "Alice", timestamp: "00:00:12", anchor: "t-00-00-12")
                    ]
                )
            ],
            judgments: [],
            decisions: [
                MeetingKnowledgeItem(
                    id: "decision_001",
                    statement: "Q3 Japan launch will start with a Tokyo-only pilot.",
                    related: ["Japan GTM", "Tokyo"],
                    confidence: .high,
                    status: "Proposed",
                    evidence: [
                        MeetingKnowledgeEvidence(segmentID: "segment-1", speaker: "Alice", timestamp: "00:00:12", anchor: "t-00-00-12")
                    ]
                )
            ],
            actions: [
                MeetingKnowledgeItem(
                    id: "action_001",
                    statement: "Ken will confirm legal timing.",
                    owner: "Ken",
                    due: "2026-05-15",
                    related: ["Legal Review", "Japan GTM"],
                    confidence: .high,
                    status: "Open",
                    evidence: [
                        MeetingKnowledgeEvidence(segmentID: "segment-2", speaker: "Ken", timestamp: nil, anchor: "segment-segment-2")
                    ]
                )
            ],
            openQuestions: [],
            entityUpdates: []
        )

        return MeetingKnowledgePackage(record: record, summary: summary, segments: segments, knowledge: knowledge)
    }
}
