import XCTest
@testable import MeetingAgentCore

final class LiveCaptionDisplayStateTests: XCTestCase {
    func testTranslatedTurnUsesTargetTextAsPrimaryAndSourceAsSecondary() {
        let turn = LiveCaptionTurn(
            sourceSegmentID: "segment-1",
            originalText: "We need a launch owner.",
            translatedText: "我们需要一位上线负责人。",
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            isFinal: true,
            translationHealth: .live
        )

        let state = LiveCaptionDisplayState(turn: turn, secondLanguageEnabled: true)

        XCTAssertEqual(state, .translated(primaryText: "我们需要一位上线负责人。", sourceText: "We need a launch owner."))
    }

    func testOriginalOnlyWhenSecondLanguageIsDisabled() {
        let turn = LiveCaptionTurn(
            sourceSegmentID: "segment-1",
            originalText: "We need a launch owner.",
            translatedText: "我们需要一位上线负责人。",
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            isFinal: true,
            translationHealth: .live
        )

        let state = LiveCaptionDisplayState(turn: turn, secondLanguageEnabled: false)

        XCTAssertEqual(state, .originalOnly("We need a launch owner."))
    }

    func testPendingTranslationWhenSecondLanguageIsEnabledAndTranslationIsMissing() {
        let turn = LiveCaptionTurn(
            sourceSegmentID: "segment-1",
            originalText: "We need a launch owner.",
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            isFinal: true,
            translationHealth: .pending
        )

        let state = LiveCaptionDisplayState(turn: turn, secondLanguageEnabled: true)

        XCTAssertEqual(state, .pending(sourceText: "We need a launch owner."))
    }

    func testFailedTranslationWhenSecondLanguageIsEnabledAndTranslationFails() {
        let turn = LiveCaptionTurn(
            sourceSegmentID: "segment-1",
            originalText: "We need a launch owner.",
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            isFinal: true,
            translationHealth: .failed("timeout")
        )

        let state = LiveCaptionDisplayState(turn: turn, secondLanguageEnabled: true)

        XCTAssertEqual(state, .failed(sourceText: "We need a launch owner.", message: "timeout"))
    }

    func testSecondLanguageEnabledUsesLocaleDifferenceOrExistingTranslation() {
        XCTAssertFalse(LiveCaptionDisplayState.isSecondLanguageEnabled(sourceLocale: "en-US", targetLocale: "en-US", hasTranslatedText: false))
        XCTAssertTrue(LiveCaptionDisplayState.isSecondLanguageEnabled(sourceLocale: "en-US", targetLocale: "zh-CN", hasTranslatedText: false))
        XCTAssertTrue(LiveCaptionDisplayState.isSecondLanguageEnabled(sourceLocale: "en-US", targetLocale: "en-US", hasTranslatedText: true))
    }
}
