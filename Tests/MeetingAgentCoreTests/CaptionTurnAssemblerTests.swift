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

    func testRemoveSegmentsEmitsRemovedEventsForMissingInterimSegments() {
        var assembler = CaptionTurnAssembler(sourceLocale: "en-US", targetLocale: "zh-CN")
        _ = assembler.apply(segment(id: "segment-1", text: "First draft", isFinal: false, speechFinal: false))
        _ = assembler.apply(segment(id: "segment-2", text: "Second draft", isFinal: false, speechFinal: false))

        let events = assembler.removeSegments(notIn: ["segment-2"])

        XCTAssertEqual(events, [.removed(turnID: "segment-1")])
        XCTAssertEqual(assembler.removeSegments(notIn: ["segment-2"]), [])
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
        text: String,
        language: String? = "en-US",
        isFinal: Bool = true,
        speechFinal: Bool
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            speaker: TranscriptSpeaker(identifier: speaker),
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
