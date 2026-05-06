import XCTest
@testable import MeetingAgentCore

final class TranslationContextStoreTests: XCTestCase {
    func testContextIncludesRecentStableBlocksAndGlossary() {
        var store = TranslationContextStore(maxRecentBlocks: 2)
        let lane = TranslationLaneID(
            speaker: TranscriptSpeaker(identifier: "speaker-1", label: "Alice"),
            sourceLocale: "en-US",
            targetLocale: "zh-CN"
        )
        store.updateMeetingGoal("Confirm the launch owner")
        store.updateKeyTerms([MeetingKeyTerm(id: "ga", value: "GA", translationHint: "正式发布")])
        store.recordStableTranslation(sourceText: "We reviewed launch risk.", translatedText: "我们审查了上线风险。", laneID: lane)
        store.recordStableTranslation(sourceText: "Alice owns follow-up.", translatedText: "Alice 负责跟进。", laneID: lane)

        let context = store.context(for: lane)

        XCTAssertEqual(context.meetingGoalContext, "Confirm the launch owner")
        XCTAssertEqual(context.keyTerms.map(\.value), ["GA"])
        XCTAssertEqual(context.recentBlocks.count, 2)
        XCTAssertTrue(context.promptSummary.contains("We reviewed launch risk."))
        XCTAssertFalse(context.contextHash.isEmpty)
    }

    func testContextHashChangesWhenGlossaryChanges() {
        var store = TranslationContextStore(maxRecentBlocks: 2)
        let lane = TranslationLaneID(speaker: .default, sourceLocale: "en-US", targetLocale: "zh-CN")
        let original = store.context(for: lane).contextHash

        store.updateKeyTerms([MeetingKeyTerm(id: "api", value: "API", translationHint: "接口")])

        XCTAssertNotEqual(original, store.context(for: lane).contextHash)
    }

    func testStoreEqualityIgnoresClockAndRecentBlocksAreCapped() {
        let lane = TranslationLaneID(speaker: .default, sourceLocale: "en-US", targetLocale: "zh-CN")
        var first = TranslationContextStore(maxRecentBlocks: 1, now: { Date(timeIntervalSince1970: 1) })
        var second = TranslationContextStore(maxRecentBlocks: 1, now: { Date(timeIntervalSince1970: 1) })

        first.updateMeetingGoal(" Confirm launch ")
        second.updateMeetingGoal("Confirm launch")
        first.recordStableTranslation(sourceText: "First block", translatedText: "第一段", laneID: lane)
        first.recordStableTranslation(sourceText: "Second block", translatedText: "第二段", laneID: lane)
        second.recordStableTranslation(sourceText: "Second block", translatedText: "第二段", laneID: lane)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.context(for: lane).recentBlocks.map(\.sourceText), ["Second block"])
        XCTAssertEqual(first.context(for: lane), second.context(for: lane))
    }
}
