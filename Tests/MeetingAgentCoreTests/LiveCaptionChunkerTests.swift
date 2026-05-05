import XCTest
@testable import MeetingAgentCore

final class LiveCaptionChunkerTests: XCTestCase {
    func testSpeechFinalFreezesDraftChunk() {
        var chunker = LiveCaptionChunker(sourceLocale: "en-US", targetLocale: "zh-CN")

        let updates = chunker.append(segment(
            id: "s1",
            text: "We should launch.",
            speechFinal: true
        ))

        XCTAssertEqual(updates.count, 2)
        XCTAssertEqual(updates.first?.turn.chunkState, .draft)
        XCTAssertEqual(updates.last?.turn.chunkState, .frozen)
        XCTAssertEqual(updates.last?.turn.freezeReason, .speechFinal)
        XCTAssertEqual(updates.last?.turn.originalText, "We should launch.")
    }

    func testSpeakerChangeFreezesPreviousChunkAndStartsNewDraft() {
        var chunker = LiveCaptionChunker(sourceLocale: "en-US", targetLocale: "zh-CN")
        _ = chunker.append(segment(id: "a1", speaker: "a", text: "First speaker"))

        let updates = chunker.append(segment(id: "b1", speaker: "b", text: "Second speaker"))

        XCTAssertEqual(updates.map { $0.turn.originalText }, ["First speaker", "Second speaker"])
        XCTAssertEqual(updates.map { $0.turn.chunkState }, [.frozen, .draft])
        XCTAssertEqual(updates.first?.turn.freezeReason, .speakerChanged)
    }

    func testSameSpeakerShortFragmentsMergeWhenTimingIsClose() {
        var chunker = LiveCaptionChunker(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            policy: LiveCaptionChunkingPolicy(
                readableCharacterLimit: 80,
                shortFragmentCharacters: 24,
                maxMergeGapSeconds: 1.25,
                minSentenceBoundaryCharacters: 30
            )
        )

        _ = chunker.append(segment(id: "s1", text: "Let's align", start: 0, end: 0.7))
        let updates = chunker.append(segment(id: "s2", text: "on the launch owner", start: 0.9, end: 1.8))

        XCTAssertEqual(updates.single?.turn.originalText, "Let's align on the launch owner")
        XCTAssertEqual(updates.single?.turn.sourceSegmentIDs, ["s1", "s2"])
        XCTAssertEqual(updates.single?.turn.displayState, .draft)
        XCTAssertNil(updates.single?.turn.boundaryReason)
        XCTAssertNil(updates.single?.turn.boundaryStrength)
    }

    func testMaxLengthFreezesLongDraft() {
        var chunker = LiveCaptionChunker(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            policy: LiveCaptionChunkingPolicy(maxCharacters: 20)
        )

        let updates = chunker.append(segment(id: "s1", text: "This is a source segment that is long enough."))

        XCTAssertEqual(updates.last?.turn.chunkState, .frozen)
        XCTAssertEqual(updates.last?.turn.freezeReason, .maxLength)
    }

    func testReadableCharacterLimitFreezesBeforeHardMaximum() {
        var chunker = LiveCaptionChunker(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            policy: LiveCaptionChunkingPolicy(
                maxCharacters: 120,
                readableCharacterLimit: 48,
                minSentenceBoundaryCharacters: 80
            )
        )

        let updates = chunker.append(segment(
            id: "s1",
            text: "This caption is already long enough to become difficult to scan"
        ))

        XCTAssertEqual(updates.last?.turn.displayState, .sealed)
        XCTAssertEqual(updates.last?.turn.boundaryReason, .maxLength)
        XCTAssertEqual(updates.last?.turn.boundaryStrength, .soft)
    }

    func testMaxDurationDoesNotFreezeMidSentenceDraft() {
        var chunker = LiveCaptionChunker(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            policy: LiveCaptionChunkingPolicy(maxDurationSeconds: 2)
        )

        let updates = chunker.append(segment(
            id: "s1",
            text: "Timed segment",
            start: 0,
            end: 3
        ))

        XCTAssertEqual(updates.single?.turn.chunkState, .draft)
        XCTAssertNil(updates.single?.turn.freezeReason)
    }

    func testPunctuationFreezesWhenMinimumLengthReached() {
        var chunker = LiveCaptionChunker(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            policy: LiveCaptionChunkingPolicy(minPunctuationCharacters: 10)
        )

        let updates = chunker.append(segment(id: "s1", text: "That sounds very good."))

        XCTAssertEqual(updates.last?.turn.chunkState, .frozen)
        XCTAssertEqual(updates.last?.turn.freezeReason, .punctuation)
    }

    func testTerminalSentencePunctuationCreatesSoftBoundaryAtReadableLength() {
        var chunker = LiveCaptionChunker(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            policy: LiveCaptionChunkingPolicy(minSentenceBoundaryCharacters: 18)
        )

        let updates = chunker.append(segment(id: "s1", text: "That sounds very good."))

        XCTAssertEqual(updates.last?.turn.displayState, .sealed)
        XCTAssertEqual(updates.last?.turn.boundaryReason, .punctuation)
        XCTAssertEqual(updates.last?.turn.boundaryStrength, .soft)
        XCTAssertEqual(updates.last?.turn.translationState, .draft)
    }

    func testInlinePunctuationDoesNotCreateSentenceBoundary() {
        var chunker = LiveCaptionChunker(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            policy: LiveCaptionChunkingPolicy(minSentenceBoundaryCharacters: 10)
        )

        let updates = chunker.append(segment(id: "s1", text: "Yes, we can continue with rollout planning"))

        XCTAssertEqual(updates.single?.turn.displayState, .draft)
        XCTAssertNil(updates.single?.turn.boundaryReason)
        XCTAssertNil(updates.single?.turn.boundaryStrength)
    }

    func testSoftPunctuationBoundarySealsDisplayButKeepsDraftTranslation() {
        var chunker = LiveCaptionChunker(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            policy: LiveCaptionChunkingPolicy(minPunctuationCharacters: 10)
        )

        let updates = chunker.append(segment(id: "s1", text: "That sounds good."))

        XCTAssertEqual(updates.last?.turn.displayState, .sealed)
        XCTAssertEqual(updates.last?.turn.translationState, .draft)
        XCTAssertEqual(updates.last?.turn.boundaryReason, .punctuation)
        XCTAssertEqual(updates.last?.turn.boundaryStrength, .soft)
    }

    func testSpeechFinalBoundarySealsDisplayAndFinalizesTranslation() {
        var chunker = LiveCaptionChunker(sourceLocale: "en-US", targetLocale: "zh-CN")

        let updates = chunker.append(segment(id: "s1", text: "Done.", speechFinal: true))

        XCTAssertEqual(updates.last?.turn.displayState, .sealed)
        XCTAssertEqual(updates.last?.turn.translationState, .final)
        XCTAssertEqual(updates.last?.turn.boundaryReason, .speechFinal)
        XCTAssertEqual(updates.last?.turn.boundaryStrength, .hard)
    }

    func testSpeakerChangeBoundaryFinalizesPreviousSpeakerTranslation() {
        var chunker = LiveCaptionChunker(sourceLocale: "en-US", targetLocale: "zh-CN")
        _ = chunker.append(segment(id: "a1", speaker: "a", text: "First thought"))

        let updates = chunker.append(segment(id: "b1", speaker: "b", text: "Second thought"))

        XCTAssertEqual(updates.first?.turn.displayState, .sealed)
        XCTAssertEqual(updates.first?.turn.translationState, .final)
        XCTAssertEqual(updates.first?.turn.boundaryReason, .speakerChanged)
        XCTAssertEqual(updates.first?.turn.boundaryStrength, .hard)
        XCTAssertEqual(updates.last?.turn.displayState, .draft)
        XCTAssertEqual(updates.last?.turn.translationState, .draft)
    }

    func testInlineSentencePunctuationDoesNotCreateBoundaryInLongDeepgramChunk() {
        var chunker = LiveCaptionChunker(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            policy: LiveCaptionChunkingPolicy(
                minPunctuationCharacters: 80,
                readableCharacterLimit: 240
            )
        )

        let updates = chunker.append(segment(
            id: "deepgram-transcribe-stream-0.00",
            text: "My name is Sherwin Chaffee, and I work at Microsoft as a copilot principal technical specialist. Now on this channel, we often build our own autonomous agents",
            start: 0,
            end: 9.49
        ))

        XCTAssertEqual(updates.single?.turn.chunkState, .draft)
        XCTAssertNil(updates.single?.turn.freezeReason)
    }

    func testJoiningAdjacentFinalChunksRemovesSuffixPrefixOverlap() {
        var chunker = LiveCaptionChunker(sourceLocale: "en-US", targetLocale: "zh-CN")

        _ = chunker.append(segment(
            id: "deepgram-transcribe-stream-44.34",
            text: "inside Microsoft Teams, which are outlined here, to be able to take",
            start: 44.34,
            end: 46.9
        ))
        let updates = chunker.append(segment(
            id: "deepgram-transcribe-stream-47.52",
            text: "to be able to take advantage of these public preview features.",
            start: 47.52,
            end: 52.08
        ))

        XCTAssertEqual(
            updates.last?.turn.originalText,
            "inside Microsoft Teams, which are outlined here, to be able to take advantage of these public preview features."
        )
    }

    func testManualFlushFreezesOpenDraft() {
        var chunker = LiveCaptionChunker(sourceLocale: "en-US", targetLocale: "zh-CN")
        _ = chunker.append(segment(id: "s1", text: "Still open"))

        let updates = chunker.flushOpenChunk(reason: .manualStop)

        XCTAssertEqual(updates.single?.turn.chunkState, .frozen)
        XCTAssertEqual(updates.single?.turn.freezeReason, .manualStop)
    }

    func testAppendingBlankTextDoesNotAddExtraJoinerWhitespace() {
        var firstBlankChunker = LiveCaptionChunker(sourceLocale: "en-US", targetLocale: "zh-CN")
        _ = firstBlankChunker.append(segment(id: "s1", text: " "))
        let firstBlankUpdates = firstBlankChunker.append(segment(id: "s2", text: "second"))

        XCTAssertEqual(firstBlankUpdates.single?.turn.originalText, "second")

        var secondBlankChunker = LiveCaptionChunker(sourceLocale: "en-US", targetLocale: "zh-CN")
        _ = secondBlankChunker.append(segment(id: "s1", text: "first"))
        let secondBlankUpdates = secondBlankChunker.append(segment(id: "s2", text: " "))

        XCTAssertEqual(secondBlankUpdates.single?.turn.originalText, "first")
    }

    func testUpdatingSameSegmentIDReplacesOpenDraftText() {
        var chunker = LiveCaptionChunker(sourceLocale: "en-US", targetLocale: "zh-CN")
        _ = chunker.append(segment(
            id: "dg-utterance",
            text: "Now what we can do is select",
            start: 2,
            end: 3
        ))

        let draftUpdates = chunker.append(segment(
            id: "dg-utterance",
            text: "Now what we can do is select German and hear what it sounds like",
            start: 1,
            end: 4,
            language: nil
        ))

        XCTAssertEqual(draftUpdates.single?.turn.sourceSegmentIDs, ["dg-utterance"])
        XCTAssertEqual(draftUpdates.single?.turn.sourceLocale, "en-US")
        XCTAssertEqual(
            draftUpdates.single?.turn.originalText,
            "Now what we can do is select German and hear what it sounds like"
        )

        let finalUpdates = chunker.append(segment(
            id: "dg-utterance",
            text: "Now what we can do is select German and hear what it sounds like",
            speechFinal: true
        ))

        XCTAssertEqual(finalUpdates.map(\.turn.originalText), [
            "Now what we can do is select German and hear what it sounds like",
            "Now what we can do is select German and hear what it sounds like"
        ])
        XCTAssertEqual(finalUpdates.last?.turn.chunkState, .frozen)
        XCTAssertEqual(finalUpdates.last?.turn.freezeReason, .speechFinal)
    }

    func testMissingSegmentLanguageFallsBackToChunkerSourceLocale() {
        var chunker = LiveCaptionChunker(sourceLocale: "ja-JP", targetLocale: "en-US")

        let firstUpdates = chunker.append(segment(id: "s1", text: "first", language: nil))
        let secondUpdates = chunker.append(segment(id: "s2", text: "second", language: nil))

        XCTAssertEqual(firstUpdates.single?.turn.sourceLocale, "ja-JP")
        XCTAssertEqual(secondUpdates.single?.turn.sourceLocale, "ja-JP")
    }

    func testChunkingTypesSupportEquality() {
        XCTAssertEqual(
            LiveCaptionChunkingPolicy(maxCharacters: 10, maxDurationSeconds: 2, minPunctuationCharacters: 5),
            LiveCaptionChunkingPolicy(maxCharacters: 10, maxDurationSeconds: 2, minPunctuationCharacters: 5)
        )

        let turn = LiveCaptionTurn(
            sourceSegmentID: "s1",
            speaker: TranscriptSpeaker(identifier: "speaker-1"),
            originalText: "hello",
            isFinal: true
        )
        XCTAssertEqual(LiveCaptionChunkUpdate(turn: turn), LiveCaptionChunkUpdate(turn: turn))

        var first = LiveCaptionChunker(sourceLocale: "en-US", targetLocale: "zh-CN")
        var second = LiveCaptionChunker(sourceLocale: "en-US", targetLocale: "zh-CN")
        let createdAt = Date(timeIntervalSince1970: 100)
        _ = first.append(segment(id: "s1", text: "Still open", createdAt: createdAt))
        _ = second.append(segment(id: "s1", text: "Still open", createdAt: createdAt))

        XCTAssertEqual(first, second)
    }

    private func segment(
        id: String,
        speaker: String = "speaker-1",
        text: String,
        start: Double? = nil,
        end: Double? = nil,
        speechFinal: Bool = false,
        createdAt: Date = Date(),
        language: String? = "en-US"
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            speaker: TranscriptSpeaker(identifier: speaker),
            startTimeSeconds: start,
            endTimeSeconds: end,
            text: text,
            language: language,
            sourceProvider: "deepgram-transcribe",
            speechFinal: speechFinal,
            createdAt: createdAt,
            timingSource: start == nil && end == nil ? .unavailable : .precise
        )
    }
}

private extension Array {
    var single: Element? {
        count == 1 ? first : nil
    }
}
