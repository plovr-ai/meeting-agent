import XCTest
@testable import MeetingAgentCore

final class CaptionReducerTests: XCTestCase {
    func testInterimHypothesesReplaceSameVisibleDraft() {
        var reducer = CaptionReducer(provider: CaptionProviderInfo(id: "deepgram", model: "nova-3", locale: "zh-CN"))

        _ = reducer.apply(.hypothesis(payload(id: "utt-1", resultID: "r1", text: "A", speakerID: "speaker-0")))
        let document = reducer.apply(.hypothesis(payload(id: "utt-1", resultID: "r2", text: "AB", speakerID: "speaker-0")))

        XCTAssertEqual(document.turns.count, 1)
        XCTAssertEqual(document.turns[0].text, "AB")
        XCTAssertEqual(document.turns[0].state, .draft)
        XCTAssertEqual(document.turns[0].sections.count, 1)
    }

    func testFinalPromotesDraftWithoutDuplicatingTurn() {
        var reducer = CaptionReducer()

        _ = reducer.apply(.hypothesis(payload(id: "utt-1", text: "负责人是", speakerID: "speaker-0")))
        let document = reducer.apply(.final(payload(id: "utt-1", text: "负责人是 Alice。", speakerID: "speaker-0")))

        XCTAssertEqual(document.turns.count, 1)
        XCTAssertEqual(document.turns[0].text, "负责人是 Alice。")
        XCTAssertEqual(document.turns[0].state, .final)
    }

    func testDuplicateFinalIsIgnored() {
        var reducer = CaptionReducer()

        _ = reducer.apply(.final(payload(id: "utt-1", text: "第一句。", speakerID: "speaker-0")))
        let document = reducer.apply(.final(payload(id: "utt-1", text: "第一句。", speakerID: "speaker-0")))

        XCTAssertEqual(document.turns.count, 1)
        XCTAssertEqual(document.turns[0].text, "第一句。")
    }

    func testDifferentSpeakersCreateSeparateTurns() {
        var reducer = CaptionReducer()

        _ = reducer.apply(.final(payload(id: "utt-1", text: "你好。", speakerID: "speaker-0")))
        let document = reducer.apply(.final(payload(id: "utt-2", text: "收到。", speakerID: "speaker-1")))

        XCTAssertEqual(document.turns.count, 2)
        XCTAssertEqual(document.turns.map(\.speakerID), ["speaker-0", "speaker-1"])
    }

    func testSameSpeakerWithoutBoundaryExtendsSameSection() {
        var reducer = CaptionReducer()

        _ = reducer.apply(.final(payload(id: "utt-1", text: "我们确认", speakerID: "speaker-0")))
        let document = reducer.apply(.final(payload(id: "utt-2", text: "负责人", speakerID: "speaker-0")))

        XCTAssertEqual(document.turns.count, 1)
        XCTAssertEqual(document.turns[0].sections.count, 1)
        XCTAssertEqual(document.turns[0].text, "我们确认 负责人")
    }

    func testPauseBoundaryCreatesReadableSectionButKeepsSameSpeakerTurn() {
        var reducer = CaptionReducer()

        _ = reducer.apply(.final(payload(id: "utt-1", text: "第一段", speakerID: "speaker-0", pause: 0.8)))
        let document = reducer.apply(.final(payload(id: "utt-2", text: "第二段", speakerID: "speaker-0")))

        XCTAssertEqual(document.turns.count, 1)
        XCTAssertEqual(document.turns[0].sections.count, 2)
        XCTAssertEqual(document.turns[0].text, "第一段\n第二段")
    }

    func testPunctuationBoundaryCreatesReadableSectionButKeepsSameSpeakerTurn() {
        var reducer = CaptionReducer()

        _ = reducer.apply(.final(payload(id: "utt-1", text: "第一句。", speakerID: "speaker-0")))
        let document = reducer.apply(.final(payload(id: "utt-2", text: "第二句", speakerID: "speaker-0")))

        XCTAssertEqual(document.turns.count, 1)
        XCTAssertEqual(document.turns[0].sections.count, 2)
        XCTAssertEqual(document.turns[0].text, "第一句。\n第二句")
    }

    func testSpeechFinalBoundaryCreatesReadableSectionButKeepsSameSpeakerTurn() {
        var reducer = CaptionReducer()

        _ = reducer.apply(.final(payload(id: "utt-1", text: "先这样", speakerID: "speaker-0", speechFinal: true)))
        let document = reducer.apply(.final(payload(id: "utt-2", text: "然后继续", speakerID: "speaker-0")))

        XCTAssertEqual(document.turns.count, 1)
        XCTAssertEqual(document.turns[0].sections.count, 2)
        XCTAssertEqual(document.turns[0].text, "先这样\n然后继续")
    }

    func testLongCJKWithoutBoundaryDoesNotSplitByCharacterCount() {
        var reducer = CaptionReducer()
        let longText = String(repeating: "这是一个很长的中文实时字幕片段", count: 20)

        let document = reducer.apply(.final(payload(id: "utt-1", text: longText, speakerID: "speaker-0")))

        XCTAssertEqual(document.turns.count, 1)
        XCTAssertEqual(document.turns[0].sections.count, 1)
        XCTAssertEqual(document.turns[0].text, longText)
    }

    private func payload(
        id: String,
        resultID: String? = nil,
        text: String,
        speakerID: String?,
        speechFinal: Bool = false,
        pause: Double? = nil
    ) -> SpeechUtterancePayload {
        SpeechUtterancePayload(
            providerID: "deepgram",
            providerResultID: resultID,
            providerUtteranceID: id,
            speaker: speakerID.map { TranscriptSpeaker(identifier: $0) },
            startTimeSeconds: nil,
            endTimeSeconds: nil,
            text: text,
            language: "zh-CN",
            confidence: 0.9,
            boundary: SpeechBoundary(
                speechFinal: speechFinal,
                punctuationFinal: SpeechBoundary.detectsPunctuationFinal(in: text),
                pauseDurationSeconds: pause
            )
        )
    }
}
