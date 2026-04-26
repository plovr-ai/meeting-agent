import XCTest
@testable import MeetingAgentCore

final class RealtimeTranslationStoreTests: XCTestCase {
    func testStoreCoalescesDeltasIntoActiveTurn() {
        var store = LiveTranslationStore()

        store.appendDelta("你")
        store.appendDelta("好")

        XCTAssertEqual(store.turns.count, 1)
        XCTAssertEqual(store.turns[0].text, "你好")
        XCTAssertFalse(store.turns[0].isFinal)
    }

    func testStoreFinalizesActiveTurn() {
        var store = LiveTranslationStore()

        store.appendDelta("我们明天")
        store.finalize("我们明天确认。")

        XCTAssertEqual(store.turns.count, 1)
        XCTAssertEqual(store.turns[0].text, "我们明天确认。")
        XCTAssertTrue(store.turns[0].isFinal)
    }

    func testStoreCreatesNewTurnAfterFinal() {
        var store = LiveTranslationStore()

        store.appendDelta("第一句")
        store.finalize("第一句。")
        store.appendDelta("第二句")

        XCTAssertEqual(store.turns.map(\.text), ["第一句。", "第二句"])
        XCTAssertEqual(store.turns.map(\.isFinal), [true, false])
    }
}
