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

    func testSamePriorityVisibleResultPrefersLatestAndStoreEquatable() {
        let lane = TranslationLaneID(speaker: .default, sourceLocale: "en-US", targetLocale: "zh-CN")
        var store = TranslationResultStore()
        let older = TranslationResult(
            id: "live-1",
            sourceID: "unit-1",
            laneID: lane,
            sourceText: "We approve",
            translatedText: "旧翻译",
            displayState: .liveFresh,
            createdAt: Date(timeIntervalSince1970: 1),
            sourceCreatedAt: Date(timeIntervalSince1970: 1)
        )
        let newer = TranslationResult(
            id: "live-2",
            sourceID: "unit-2",
            laneID: lane,
            sourceText: "We approve",
            translatedText: "新翻译",
            displayState: .liveFresh,
            createdAt: Date(timeIntervalSince1970: 2),
            sourceCreatedAt: Date(timeIntervalSince1970: 1)
        )

        store.attach(older)
        store.attach(newer)

        XCTAssertEqual(store.visibleResult(for: lane)?.translatedText, "新翻译")
        XCTAssertNotEqual(store, TranslationResultStore())
    }

    func testLaggingLiveResultCanCarryForwardWhenCurrentTextIsLowRisk() {
        let lane = TranslationLaneID(speaker: .default, sourceLocale: "en-US", targetLocale: "zh-CN")
        var store = TranslationResultStore()
        store.attach(TranslationResult(
            id: "live-lagging",
            sourceID: "unit-1",
            laneID: lane,
            sourceText: "We confirm",
            translatedText: "我们确认",
            displayState: .liveLagging,
            createdAt: Date(timeIntervalSince1970: 1),
            sourceCreatedAt: Date(timeIntervalSince1970: 1)
        ))

        XCTAssertEqual(store.carriedForwardResult(for: lane, currentRiskFlags: [])?.displayState, .liveCarried)
    }
}
