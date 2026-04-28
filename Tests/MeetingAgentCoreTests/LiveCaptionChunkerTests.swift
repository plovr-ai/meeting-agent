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

    func testMaxDurationFreezesTimedDraft() {
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

        XCTAssertEqual(updates.last?.turn.chunkState, .frozen)
        XCTAssertEqual(updates.last?.turn.freezeReason, .maxDuration)
    }

    func testPunctuationFreezesWhenMinimumLengthReached() {
        var chunker = LiveCaptionChunker(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            policy: LiveCaptionChunkingPolicy(minPunctuationCharacters: 10)
        )

        let updates = chunker.append(segment(id: "s1", text: "That sounds good."))

        XCTAssertEqual(updates.last?.turn.chunkState, .frozen)
        XCTAssertEqual(updates.last?.turn.freezeReason, .punctuation)
    }

    func testManualFlushFreezesOpenDraft() {
        var chunker = LiveCaptionChunker(sourceLocale: "en-US", targetLocale: "zh-CN")
        _ = chunker.append(segment(id: "s1", text: "Still open"))

        let updates = chunker.flushOpenChunk(reason: .manualStop)

        XCTAssertEqual(updates.single?.turn.chunkState, .frozen)
        XCTAssertEqual(updates.single?.turn.freezeReason, .manualStop)
    }

    private func segment(
        id: String,
        speaker: String = "speaker-1",
        text: String,
        start: Double? = nil,
        end: Double? = nil,
        speechFinal: Bool = false
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            speaker: TranscriptSpeaker(identifier: speaker),
            startTimeSeconds: start,
            endTimeSeconds: end,
            text: text,
            language: "en-US",
            sourceProvider: "deepgram-transcribe",
            speechFinal: speechFinal,
            timingSource: start == nil && end == nil ? .unavailable : .precise
        )
    }
}

private extension Array {
    var single: Element? {
        count == 1 ? first : nil
    }
}
