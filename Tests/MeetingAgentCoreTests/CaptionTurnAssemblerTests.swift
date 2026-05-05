import XCTest
@testable import MeetingAgentCore

final class CaptionTurnAssemblerTests: XCTestCase {
    func testFinalSpeechFinalSegmentSealsHardBoundary() {
        var assembler = CaptionTurnAssembler(sourceLocale: "en-US", targetLocale: "zh-CN")

        let events = assembler.apply(segment(
            id: "segment-1",
            text: "We should launch.",
            speechFinal: true
        ))

        XCTAssertEqual(events.count, 2)
        guard case .draftUpdated(let draft) = events.first else {
            XCTFail("Expected first event to update draft")
            return
        }
        guard case .sealed(let sealed) = events.last else {
            XCTFail("Expected last event to seal turn")
            return
        }
        XCTAssertEqual(draft.displayState, .draft)
        XCTAssertEqual(sealed.originalText, "We should launch.")
        XCTAssertEqual(sealed.boundaryReason, .speechFinal)
        XCTAssertEqual(sealed.boundaryStrength, .hard)
        XCTAssertEqual(sealed.displayState, .sealed)
    }

    func testSameSpeakerFinalSegmentsMergeUntilHardBoundary() {
        var assembler = CaptionTurnAssembler(sourceLocale: "en-US", targetLocale: "zh-CN")

        _ = assembler.apply(segment(
            id: "segment-1",
            text: "First part",
            speechFinal: false
        ))
        let events = assembler.apply(segment(
            id: "segment-2",
            text: "second part.",
            speechFinal: true
        ))

        guard case .sealed(let sealed) = events.last else {
            XCTFail("Expected last event to seal turn")
            return
        }
        XCTAssertEqual(sealed.sourceSegmentIDs, ["segment-1", "segment-2"])
        XCTAssertEqual(sealed.originalText, "First part second part.")
    }

    func testAssemblerUsesReadableChunkingPolicyForSoftSentenceBoundary() {
        var assembler = CaptionTurnAssembler(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            policy: LiveCaptionChunkingPolicy(minSentenceBoundaryCharacters: 18)
        )

        let events = assembler.apply(segment(
            id: "segment-1",
            text: "That sounds very good.",
            speechFinal: false
        ))

        guard case .sealed(let sealed) = events.last else {
            XCTFail("Expected readable sentence punctuation to seal a soft boundary")
            return
        }
        XCTAssertEqual(sealed.boundaryReason, .punctuation)
        XCTAssertEqual(sealed.boundaryStrength, .soft)
    }

    func testInterimSegmentProducesInterimEvent() {
        var assembler = CaptionTurnAssembler(sourceLocale: "ja-JP", targetLocale: "en-US")

        let events = assembler.apply(segment(
            id: "segment-1",
            text: "Still speaking",
            language: nil,
            isFinal: false,
            speechFinal: false
        ))

        guard case .interimUpdated(let interim) = events.single else {
            XCTFail("Expected interim segment to update")
            return
        }
        XCTAssertEqual(interim.id, "segment-1")
        XCTAssertNil(interim.language)
        XCTAssertFalse(interim.isFinal)
    }

    func testInterimUpdatesReplaceDraftForSameSegmentID() {
        var assembler = CaptionTurnAssembler(sourceLocale: "en-US", targetLocale: "zh-CN")
        let id = "deepgram-transcribe-stream-0.0"
        _ = assembler.apply(segment(
            id: id,
            speaker: "deepgram-speaker-0",
            text: "We should",
            isFinal: false,
            speechFinal: false
        ))

        let events = assembler.apply(segment(
            id: id,
            speaker: "deepgram-speaker-0",
            text: "We should decide",
            isFinal: false,
            speechFinal: false
        ))

        XCTAssertEqual(events.count, 1)
        guard case .draftUpdated(let draft) = events.single else {
            XCTFail("Expected same-ID interim to replace existing draft")
            return
        }
        XCTAssertEqual(draft.originalText, "We should decide")
        XCTAssertEqual(draft.sourceSegmentIDs, [id])
        XCTAssertEqual(draft.displayState, .draft)
    }

    func testInterimGrowthPreservesSharedStablePrefix() {
        var assembler = CaptionTurnAssembler(sourceLocale: "en-US", targetLocale: "zh-CN")
        let id = "deepgram-transcribe-stream-0.0"
        _ = assembler.apply(segment(
            id: id,
            speaker: "deepgram-speaker-0",
            text: "We should",
            isFinal: false,
            speechFinal: false
        ))

        let events = assembler.apply(segment(
            id: id,
            speaker: "deepgram-speaker-0",
            text: "We should decide",
            isFinal: false,
            speechFinal: false
        ))

        guard case .draftUpdated(let draft) = events.single else {
            XCTFail("Expected same-ID interim to update draft")
            return
        }
        XCTAssertEqual(draft.originalText, "We should decide")
        XCTAssertEqual(draft.stableOriginalTextPrefix, "We should")
        XCTAssertEqual(draft.unstableOriginalTextTail, " decide")
    }

    func testInterimCorrectionKeepsOnlyPrefixBeforeChangedWordStable() {
        var assembler = CaptionTurnAssembler(sourceLocale: "en-US", targetLocale: "zh-CN")
        let id = "deepgram-transcribe-stream-0.0"
        _ = assembler.apply(segment(
            id: id,
            speaker: "deepgram-speaker-0",
            text: "We should decide",
            isFinal: false,
            speechFinal: false
        ))

        let events = assembler.apply(segment(
            id: id,
            speaker: "deepgram-speaker-0",
            text: "We might decide",
            isFinal: false,
            speechFinal: false
        ))

        guard case .draftUpdated(let draft) = events.single else {
            XCTFail("Expected same-ID interim to update draft")
            return
        }
        XCTAssertEqual(draft.stableOriginalTextPrefix, "We ")
        XCTAssertEqual(draft.unstableOriginalTextTail, "might decide")
    }

    func testFinalPromotionClearsMutableStableTail() {
        var assembler = CaptionTurnAssembler(sourceLocale: "en-US", targetLocale: "zh-CN")
        let id = "deepgram-transcribe-stream-0.0"
        _ = assembler.apply(segment(
            id: id,
            speaker: "deepgram-speaker-0",
            text: "We should decide",
            isFinal: false,
            speechFinal: false
        ))

        let events = assembler.apply(segment(
            id: id,
            speaker: "deepgram-speaker-0",
            text: "We should decide today.",
            isFinal: true,
            speechFinal: true
        ))

        guard case .sealed(let sealed) = events.last else {
            XCTFail("Expected final segment to seal matching interim draft")
            return
        }
        XCTAssertEqual(sealed.originalText, "We should decide today.")
        XCTAssertEqual(sealed.stableOriginalTextPrefix, "We should decide today.")
        XCTAssertEqual(sealed.unstableOriginalTextTail, "")
    }

    func testSpeakerChangeResetsStablePrefixForSameSegmentID() {
        var assembler = CaptionTurnAssembler(sourceLocale: "en-US", targetLocale: "zh-CN")
        let id = "deepgram-transcribe-stream-0.0"
        _ = assembler.apply(segment(
            id: id,
            speaker: "deepgram-speaker-0",
            text: "We should decide",
            isFinal: false,
            speechFinal: false
        ))

        let events = assembler.apply(segment(
            id: id,
            speaker: "deepgram-speaker-1",
            text: "We should decide now",
            isFinal: false,
            speechFinal: false
        ))

        guard case .draftUpdated(let draft) = events.single else {
            XCTFail("Expected same-ID interim to update draft")
            return
        }
        XCTAssertEqual(draft.stableOriginalTextPrefix, "")
        XCTAssertEqual(draft.unstableOriginalTextTail, "We should decide now")
    }

    func testFinalSegmentReplacesMatchingInterimDraft() {
        var assembler = CaptionTurnAssembler(sourceLocale: "en-US", targetLocale: "zh-CN")
        let id = "deepgram-transcribe-stream-0.0"
        _ = assembler.apply(segment(
            id: id,
            speaker: "deepgram-speaker-0",
            startTimeSeconds: 0,
            endTimeSeconds: 1,
            text: "We should decide",
            isFinal: false,
            speechFinal: false
        ))

        let events = assembler.apply(segment(
            id: id,
            speaker: "deepgram-speaker-0",
            startTimeSeconds: 0,
            endTimeSeconds: 1,
            text: "We should decide today.",
            isFinal: true,
            speechFinal: true
        ))

        guard case .sealed(let sealed) = events.last else {
            XCTFail("Expected final segment to seal matching interim draft")
            return
        }
        XCTAssertEqual(sealed.originalText, "We should decide today.")
        XCTAssertEqual(sealed.sourceSegmentIDs, [id])
        XCTAssertEqual(sealed.boundaryStrength, .hard)
    }

    func testRemoveSegmentsEmitsRemovedEventsForMissingInterimSegments() {
        var assembler = CaptionTurnAssembler(sourceLocale: "en-US", targetLocale: "zh-CN")
        _ = assembler.apply(segment(id: "segment-1", text: "First draft", isFinal: false, speechFinal: false))
        _ = assembler.apply(segment(id: "segment-2", text: "Second draft", isFinal: false, speechFinal: false))

        let events = assembler.removeSegments(notIn: ["segment-2"])

        XCTAssertEqual(events, [.removed(turnID: "segment-1")])
        XCTAssertEqual(assembler.removeSegments(notIn: ["segment-2"]), [])
    }

    func testSpeechFinalFalseFinalChunksRemainOpenAndDeduplicateOverlap() {
        var assembler = CaptionTurnAssembler(sourceLocale: "en-US", targetLocale: "zh-CN")

        _ = assembler.apply(segment(
            id: "deepgram-transcribe-stream-44.34",
            startTimeSeconds: 44.34,
            endTimeSeconds: 46.9,
            text: "inside Microsoft Teams, which are outlined here, to be able to take",
            speechFinal: false
        ))
        let events = assembler.apply(segment(
            id: "deepgram-transcribe-stream-47.52",
            startTimeSeconds: 47.52,
            endTimeSeconds: 52.08,
            text: "to be able to take advantage of these public preview features",
            speechFinal: false
        ))

        guard case .draftUpdated(let draft) = events.single else {
            XCTFail("Expected the second speechFinal=false final segment to keep updating the open draft")
            return
        }
        XCTAssertEqual(
            draft.originalText,
            "inside Microsoft Teams, which are outlined here, to be able to take advantage of these public preview features"
        )
        XCTAssertNil(draft.boundaryReason)
        XCTAssertEqual(draft.displayState, .draft)
    }

    func testFlushSealsOpenFinalDraft() {
        var assembler = CaptionTurnAssembler(sourceLocale: "en-US", targetLocale: "zh-CN")
        _ = assembler.apply(segment(id: "segment-1", text: "Open draft", speechFinal: false))

        let events = assembler.flush(reason: .manualStop)

        XCTAssertEqual(events.count, 1)
        guard case .sealed(let sealed) = events.first else {
            XCTFail("Expected flush to seal open draft")
            return
        }
        XCTAssertEqual(sealed.boundaryReason, .manualStop)
        XCTAssertEqual(sealed.displayState, .sealed)
    }

    private func segment(
        id: String,
        speaker: String = "speaker-1",
        startTimeSeconds: Double? = nil,
        endTimeSeconds: Double? = nil,
        text: String,
        language: String? = "en-US",
        isFinal: Bool = true,
        speechFinal: Bool
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            speaker: TranscriptSpeaker(identifier: speaker),
            startTimeSeconds: startTimeSeconds,
            endTimeSeconds: endTimeSeconds,
            text: text,
            language: language,
            sourceProvider: "deepgram-transcribe",
            isFinal: isFinal,
            speechFinal: speechFinal
        )
    }
}

private extension Array {
    var single: Element? {
        count == 1 ? first : nil
    }
}
