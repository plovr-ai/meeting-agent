import XCTest
@testable import MeetingAgentCore

final class TranslationResultStoreTests: XCTestCase {
    func testStableFinalOverridesLiveResult() {
        let lane = TranslationLaneID(speaker: .default, sourceLocale: "en-US", targetLocale: "zh-CN")
        var store = TranslationResultStore()
        store.attach(TranslationResult(
            id: "live-1",
            sourceID: "unit-1",
            laneID: lane,
            sourceText: "We approve",
            translatedText: "我们批准",
            displayState: .liveFresh,
            createdAt: Date(timeIntervalSince1970: 2),
            sourceCreatedAt: Date(timeIntervalSince1970: 1)
        ))
        store.attach(TranslationResult(
            id: "stable-1",
            sourceID: "block-1",
            laneID: lane,
            sourceText: "We approve the launch.",
            translatedText: "我们批准上线。",
            displayState: .stableFinal,
            createdAt: Date(timeIntervalSince1970: 4),
            sourceCreatedAt: Date(timeIntervalSince1970: 3)
        ))

        let projection = store.visibleResult(for: lane)

        XCTAssertEqual(projection?.translatedText, "我们批准上线。")
        XCTAssertEqual(projection?.displayState, .stableFinal)
    }

    func testHighRiskLiveResultDoesNotCarryForward() {
        let lane = TranslationLaneID(speaker: .default, sourceLocale: "en-US", targetLocale: "zh-CN")
        var store = TranslationResultStore()
        store.attach(TranslationResult(
            id: "live-1",
            sourceID: "unit-1",
            laneID: lane,
            sourceText: "Budget is 10 percent",
            translatedText: "预算是 10%",
            displayState: .liveFresh,
            createdAt: Date(timeIntervalSince1970: 2),
            sourceCreatedAt: Date(timeIntervalSince1970: 1),
            riskFlags: [.number]
        ))

        XCTAssertNil(store.carriedForwardResult(for: lane, currentRiskFlags: [.number]))
        XCTAssertNotNil(store.carriedForwardResult(for: lane, currentRiskFlags: []))
    }
}
