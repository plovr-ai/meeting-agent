import XCTest
@testable import MeetingAgentCore

final class TranslationExperienceModelsTests: XCTestCase {
    func testLaneIDNormalizesLocaleAndSpeaker() {
        let lane = TranslationLaneID(
            speaker: TranscriptSpeaker(identifier: " speaker-1 ", label: "Alice"),
            sourceLocale: "en_US",
            targetLocale: "zh_CN"
        )

        XCTAssertEqual(lane.speakerID, "speaker-1")
        XCTAssertEqual(lane.sourceLocale, "en-US")
        XCTAssertEqual(lane.targetLocale, "zh-CN")
    }

    func testDisplayPriorityPrefersStableFinal() {
        XCTAssertGreaterThan(TranslationDisplayState.stableFinal.priority, TranslationDisplayState.liveFresh.priority)
        XCTAssertGreaterThan(TranslationDisplayState.liveFresh.priority, TranslationDisplayState.liveLagging.priority)
        XCTAssertGreaterThan(TranslationDisplayState.liveLagging.priority, TranslationDisplayState.liveCarried.priority)
        XCTAssertGreaterThan(TranslationDisplayState.liveCarried.priority, TranslationDisplayState.pending.priority)
    }

    func testLiveUnitTrimsStablePrefixAndTail() {
        let unit = LiveTranslationUnit(
            id: "unit-1",
            laneID: TranslationLaneID(speaker: .default, sourceLocale: "en-US", targetLocale: "zh-CN"),
            stablePrefixText: "  We should confirm the owner  ",
            unstableTailText: " today ",
            sourceSegmentIDs: ["segment-1"],
            contextBefore: "Earlier: launch plan.",
            revision: 2,
            createdAt: Date(timeIntervalSince1970: 10),
            deadline: Date(timeIntervalSince1970: 14),
            riskFlags: [.commitment]
        )

        XCTAssertEqual(unit.stablePrefixText, "We should confirm the owner")
        XCTAssertEqual(unit.unstableTailText, "today")
        XCTAssertEqual(unit.riskFlags, [.commitment])
        XCTAssertFalse(unit.isEmpty)
    }

    func testStableBlockComputesHashesFromSourceAndContext() {
        let lane = TranslationLaneID(speaker: .default, sourceLocale: "en-US", targetLocale: "zh-CN")
        let block = StableTranslationBlock(
            id: "block-1",
            laneID: lane,
            sourceText: "We approved the launch date.",
            sourceSegmentIDs: ["segment-1"],
            previousBlockSummary: "Team discussed launch readiness.",
            meetingGoalContext: "Confirm launch readiness.",
            keyTerms: [MeetingKeyTerm(id: "launch", value: "launch", translationHint: "上线")],
            boundaryReason: .terminalPunctuation,
            createdAt: Date(timeIntervalSince1970: 20)
        )

        XCTAssertFalse(block.sourceTextHash.isEmpty)
        XCTAssertFalse(block.contextHash.isEmpty)
        XCTAssertNotEqual(block.sourceTextHash, block.contextHash)
    }
}
