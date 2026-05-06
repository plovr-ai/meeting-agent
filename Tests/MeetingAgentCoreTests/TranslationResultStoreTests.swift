import XCTest
@testable import MeetingAgentCore

final class TranslationResultStoreTests: XCTestCase {
    func testStableFinalOutranksLiveResultAndIndexesSourceSegments() {
        let lane = TranslationLaneID(speaker: .default, sourceLocale: "en-US", targetLocale: "zh-CN")
        var store = TranslationResultStore()

        store.attach(TranslationResult(
            id: "live",
            sourceID: "unit-1",
            laneID: lane,
            sourceText: "We confirm the owner",
            translatedText: "我们确认负责人",
            displayState: .liveFresh,
            createdAt: Date(timeIntervalSince1970: 2),
            sourceCreatedAt: Date(timeIntervalSince1970: 1)
        ))
        store.attach(TranslationResult(
            id: "final",
            sourceID: "block-1",
            laneID: lane,
            sourceText: "We confirm the owner.",
            translatedText: "我们确认负责人。",
            displayState: .stableFinal,
            createdAt: Date(timeIntervalSince1970: 3),
            sourceCreatedAt: Date(timeIntervalSince1970: 1),
            sourceSegmentIDs: ["segment-1"]
        ))

        XCTAssertEqual(store.visibleResult(for: lane)?.id, "final")
        XCTAssertEqual(store.resultsForSourceSegmentIDs(["segment-1"]).map(\.id), ["final"])
    }

    func testHydratesPersistedFinalResult() {
        let meetingID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let lane = TranslationLaneID(speaker: .default, sourceLocale: "en-US", targetLocale: "zh-CN")
        let record = TranslationResultPersistenceRecord(
            meetingID: meetingID,
            resultID: "final",
            sourceID: "block-1",
            laneID: lane,
            sourceSegmentIDs: ["segment-1", "segment-2"],
            sourceTextHash: "hash",
            sourceText: "Select settings and about then choose public preview.",
            translatedText: "选择设置和关于，然后选择公共预览。",
            displayState: .stableFinal,
            boundaryReason: .providerHardBoundary,
            providerID: "test",
            createdAt: Date(timeIntervalSince1970: 1),
            finalizedAt: Date(timeIntervalSince1970: 2)
        )

        var store = TranslationResultStore()
        store.hydrate(from: [record])

        XCTAssertEqual(store.visibleResult(for: lane)?.translatedText, "选择设置和关于，然后选择公共预览。")
        XCTAssertEqual(store.resultsForSourceSegmentIDs(["segment-2"]).first?.displayState, .stableFinal)
        XCTAssertEqual(store.stableResults().map(\.id), ["final"])
    }

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
