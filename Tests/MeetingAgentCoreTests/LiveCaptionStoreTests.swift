import XCTest
@testable import MeetingAgentCore

final class LiveCaptionStoreTests: XCTestCase {
    func testAppendFinalSegmentCreatesStableTurn() {
        var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        let segment = TranscriptSegment(
            id: "segment-1",
            speaker: TranscriptSpeaker(identifier: "alex", label: "Alex"),
            text: "We need to confirm the launch owner.",
            language: "en-US",
            isFinal: true,
            createdAt: Date(timeIntervalSince1970: 100)
        )

        let turn = store.append(segment)

        XCTAssertEqual(turn.id, "segment-1")
        XCTAssertEqual(turn.sourceSegmentID, "segment-1")
        XCTAssertEqual(turn.speaker.label, "Alex")
        XCTAssertEqual(turn.originalText, "We need to confirm the launch owner.")
        XCTAssertEqual(turn.sourceLocale, "en-US")
        XCTAssertEqual(turn.targetLocale, "zh-CN")
        XCTAssertTrue(turn.isFinal)
        XCTAssertEqual(turn.captionHealth, .live)
        XCTAssertEqual(turn.translationHealth, .pending)
        XCTAssertEqual(store.turns, [turn])
    }

    func testAppendingDuplicateSegmentUpdatesExistingTurn() {
        var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        _ = store.append(TranscriptSegment(id: "segment-1", text: "old", language: "en-US"))

        let updated = store.append(TranscriptSegment(id: "segment-1", text: "new", language: "en-US"))

        XCTAssertEqual(store.turns.count, 1)
        XCTAssertEqual(updated.originalText, "new")
        XCTAssertEqual(store.turns.first?.originalText, "new")
    }

    func testAppendingDuplicateSegmentWithChangedTextClearsStaleTranslation() {
        var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        _ = store.append(TranscriptSegment(id: "segment-1", text: "old", language: "en-US", isFinal: true))
        store.attachTranslation("旧翻译", toTurnID: "segment-1")

        let updated = store.append(TranscriptSegment(id: "segment-1", text: "new", language: "en-US", isFinal: true))

        XCTAssertEqual(updated.originalText, "new")
        XCTAssertNil(updated.translatedText)
        XCTAssertEqual(updated.translationHealth, .pending)
        XCTAssertNil(store.turns.first?.translatedText)
        XCTAssertEqual(store.turns.first?.translationHealth, .pending)
    }

    func testAttachTranslationUpdatesSameTurn() {
        var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        _ = store.append(TranscriptSegment(id: "segment-1", text: "hello", language: "en-US"))

        store.attachTranslation("你好", toTurnID: "segment-1")

        XCTAssertEqual(store.turns.first?.translatedText, "你好")
        XCTAssertEqual(store.turns.first?.translationHealth, .live)
    }

    func testTranslationFailureDoesNotChangeCaptionHealth() {
        var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        _ = store.append(TranscriptSegment(id: "segment-1", text: "hello", language: "en-US"))

        store.markTranslationFailed(forTurnID: "segment-1", message: "timeout")

        XCTAssertEqual(store.turns.first?.captionHealth, .live)
        XCTAssertEqual(store.turns.first?.translationHealth, .failed("timeout"))
        XCTAssertNil(store.turns.first?.translatedText)
    }

    func testResetClearsTurnsAndUpdatesLocales() {
        var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        _ = store.append(TranscriptSegment(id: "segment-1", text: "hello", language: "en-US"))

        store.reset(sourceLocale: "ja-JP", targetLocale: "en-US")

        XCTAssertTrue(store.turns.isEmpty)
        XCTAssertEqual(store.sourceLocale, "ja-JP")
        XCTAssertEqual(store.targetLocale, "en-US")
    }
}
