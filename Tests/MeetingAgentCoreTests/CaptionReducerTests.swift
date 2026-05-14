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

    func testIncrementalInterimHypothesesWithNewUtteranceIDsReplaceOpenDraftSection() {
        var reducer = CaptionReducer(provider: CaptionProviderInfo(id: "deepgram", model: "nova-3", locale: "zh-Hans"))

        _ = reducer.apply(.hypothesis(payload(id: "utt-1", text: "英国", speakerID: "speaker-0", start: 7.6, end: 8.0)))
        _ = reducer.apply(.hypothesis(payload(id: "utt-2", text: "英国、法国、德国", speakerID: "speaker-0", start: 7.7, end: 8.1)))
        let document = reducer.apply(.hypothesis(payload(id: "utt-3", text: "英国、法国、德国这些在近代", speakerID: "speaker-0", start: 7.7, end: 9.2)))

        XCTAssertEqual(document.turns.count, 1)
        XCTAssertEqual(document.turns[0].sections.count, 1)
        XCTAssertEqual(document.turns[0].text, "英国、法国、德国这些在近代")
        XCTAssertEqual(document.turns[0].source.utteranceIDs, ["utt-1", "utt-2", "utt-3"])
    }

    func testDriftingInterimHypothesesWithinProtocolWindowReplaceOpenDraftSection() {
        var reducer = CaptionReducer(provider: CaptionProviderInfo(id: "deepgram", model: "nova-3", locale: "zh-Hans"))

        _ = reducer.apply(.hypothesis(payload(id: "utt-1", text: "决定找了一家", speakerID: "speaker-0", start: 0.80, end: 0.96)))
        _ = reducer.apply(.hypothesis(payload(id: "utt-2", text: "这边找了一家女官", speakerID: "speaker-0", start: 1.20, end: 1.36)))
        _ = reducer.apply(.hypothesis(payload(id: "utt-3", text: "这边找了一家旅馆正在", speakerID: "speaker-0", start: 1.52, end: 1.76)))
        let document = reducer.apply(.hypothesis(payload(id: "utt-4", text: "指定找了一家旅馆正叫撞见老板娘在", speakerID: "speaker-0", start: 2.88, end: 3.04)))

        XCTAssertEqual(document.turns.count, 1)
        XCTAssertEqual(document.turns[0].sections.count, 1)
        XCTAssertEqual(document.turns[0].text, "指定找了一家旅馆正叫撞见老板娘在")
        XCTAssertEqual(document.turns[0].source.utteranceIDs, ["utt-1", "utt-2", "utt-3", "utt-4"])
    }

    func testLateFinalForEarlierUtteranceDoesNotShortenNewerOverlappingDraft() {
        var reducer = CaptionReducer(provider: CaptionProviderInfo(id: "deepgram", model: "nova-3", locale: "zh-Hans"))

        _ = reducer.apply(.hypothesis(payload(id: "utt-1", text: "看到来了客人并将手下赶出去去", speakerID: "speaker-0", start: 5.44, end: 5.52)))
        _ = reducer.apply(.hypothesis(payload(id: "utt-2", text: "我们看到来了客人并将手下赶出去铲去", speakerID: "speaker-0", start: 7.04, end: 7.20)))
        let document = reducer.apply(.final(payload(id: "utt-1", text: "看到来了客人并将手下赶出去去", speakerID: "speaker-0", start: 5.44, end: 5.52)))

        XCTAssertEqual(document.turns.count, 1)
        XCTAssertEqual(document.turns[0].sections.count, 1)
        XCTAssertEqual(document.turns[0].text, "我们看到来了客人并将手下赶出去铲去")
        XCTAssertEqual(document.turns[0].state, .draft)
        XCTAssertEqual(document.turns[0].source.utteranceIDs, ["utt-1", "utt-2"])
    }

    func testUnrelatedInterimHypothesisWithNewUtteranceIDStartsReadableSection() {
        var reducer = CaptionReducer(provider: CaptionProviderInfo(id: "deepgram", model: "nova-3", locale: "zh-Hans"))

        _ = reducer.apply(.hypothesis(payload(id: "utt-1", text: "第一件事", speakerID: "speaker-0", start: 1.0, end: 1.5)))
        let document = reducer.apply(.hypothesis(payload(id: "utt-2", text: "第二件事", speakerID: "speaker-0", start: 4.0, end: 4.5)))

        XCTAssertEqual(document.turns.count, 1)
        XCTAssertEqual(document.turns[0].sections.count, 2)
        XCTAssertEqual(document.turns[0].text, "第一件事\n第二件事")
    }

    func testCoveredFinalAfterLongerDraftDoesNotAppendDuplicateText() {
        var reducer = CaptionReducer(provider: CaptionProviderInfo(id: "deepgram", model: "nova-3", locale: "zh-Hans"))

        _ = reducer.apply(.hypothesis(payload(id: "draft-1", text: "英国、法国、德国这些在近代", speakerID: "speaker-0", start: 7.7, end: 9.2)))
        let document = reducer.apply(.final(payload(id: "final-1", text: "英国法国德国", speakerID: "speaker-0", start: 7.6, end: 8.1)))

        XCTAssertEqual(document.turns.count, 1)
        XCTAssertEqual(document.turns[0].sections.count, 1)
        XCTAssertEqual(document.turns[0].text, "英国、法国、德国这些在近代")
        XCTAssertEqual(document.turns[0].state, .draft)
        XCTAssertEqual(document.turns[0].source.utteranceIDs, ["draft-1", "final-1"])
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
        pause: Double? = nil,
        start: Double? = nil,
        end: Double? = nil
    ) -> SpeechUtterancePayload {
        SpeechUtterancePayload(
            providerID: "deepgram",
            providerResultID: resultID,
            providerUtteranceID: id,
            speaker: speakerID.map { TranscriptSpeaker(identifier: $0) },
            startTimeSeconds: start,
            endTimeSeconds: end,
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
