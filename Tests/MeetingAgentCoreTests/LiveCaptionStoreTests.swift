import XCTest
@testable import MeetingAgentCore

final class LiveCaptionStoreTests: XCTestCase {
    func testLiveCaptionTurnDecodesLegacyChunkDefaults() throws {
        let data = Data("""
        {
          "id": "segment-1",
          "sourceSegmentID": "segment-1",
          "speaker": {},
          "originalText": "hello",
          "sourceLocale": "en-US",
          "targetLocale": "zh-CN",
          "isFinal": true,
          "captionHealth": { "state": "live" },
          "translationHealth": { "state": "pending" },
          "createdAt": "2026-04-28T00:00:00Z"
        }
        """.utf8)

        let turn = try JSONDecoder.meetingAgent.decode(LiveCaptionTurn.self, from: data)

        XCTAssertEqual(turn.sourceSegmentIDs, ["segment-1"])
        XCTAssertEqual(turn.chunkState, .frozen)
        XCTAssertEqual(turn.translationRevision, 0)
        XCTAssertNil(turn.freezeReason)
    }

    func testLiveCaptionTurnDefaultsDisplayAndTranslationStateFromLegacyChunkState() throws {
        let data = Data("""
        {
          "id": "segment-1",
          "sourceSegmentID": "segment-1",
          "sourceSegmentIDs": ["segment-1"],
          "speaker": {},
          "originalText": "hello",
          "sourceLocale": "en-US",
          "targetLocale": "zh-CN",
          "isFinal": true,
          "captionHealth": { "state": "live" },
          "translationHealth": { "state": "pending" },
          "createdAt": "2026-04-28T00:00:00Z",
          "chunkState": "frozen",
          "freezeReason": "punctuation"
        }
        """.utf8)

        let turn = try JSONDecoder.meetingAgent.decode(LiveCaptionTurn.self, from: data)

        XCTAssertEqual(turn.displayState, .sealed)
        XCTAssertEqual(turn.translationState, .draft)
        XCTAssertEqual(turn.boundaryReason, .punctuation)
        XCTAssertEqual(turn.boundaryStrength, .soft)
        XCTAssertEqual(turn.chunkState, .frozen)
    }

    func testHardBoundaryDefaultsTranslationStateToFinal() {
        let turn = LiveCaptionTurn(
            sourceSegmentID: "segment-1",
            originalText: "done",
            isFinal: true,
            displayState: .sealed,
            translationState: .final,
            boundaryReason: .speechFinal,
            boundaryStrength: .hard
        )

        XCTAssertEqual(turn.displayState, .sealed)
        XCTAssertEqual(turn.translationState, .final)
        XCTAssertEqual(turn.boundaryReason, .speechFinal)
        XCTAssertEqual(turn.boundaryStrength, .hard)
        XCTAssertEqual(turn.chunkState, .frozen)
    }

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

    func testUpdatingDraftSegmentKeepsPreviousDraftTranslationWhileRetranslating() {
        var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        _ = store.append(TranscriptSegment(id: "segment-1", text: "old draft", language: "en-US", isFinal: false))
        store.attachTranslation("旧草稿翻译", toTurnID: "segment-1")

        let updated = store.append(TranscriptSegment(id: "segment-1", text: "old draft with more text", language: "en-US", isFinal: false))

        XCTAssertEqual(updated.originalText, "old draft with more text")
        XCTAssertEqual(updated.translatedText, "旧草稿翻译")
        XCTAssertEqual(updated.translationHealth, .pending)
        XCTAssertEqual(store.turns.first?.translatedText, "旧草稿翻译")
        XCTAssertEqual(store.turns.first?.translationHealth, .pending)
    }

    func testAppendingFinalSegmentFromSameSpeakerMergesIntoLatestTurn() {
        var store = LiveCaptionStore(sourceLocale: "zh-CN", targetLocale: "en-US")
        let speaker = TranscriptSpeaker(identifier: "speaker-1", label: "User 1")
        _ = store.append(TranscriptSegment(
            id: "segment-1",
            speaker: speaker,
            text: "我们先看一下",
            language: "zh-CN",
            isFinal: true,
            createdAt: Date(timeIntervalSince1970: 100)
        ))

        let merged = store.append(TranscriptSegment(
            id: "segment-2",
            speaker: speaker,
            text: "这个季度的目标",
            language: "zh-CN",
            isFinal: true,
            createdAt: Date(timeIntervalSince1970: 120)
        ))

        XCTAssertEqual(store.turns.count, 1)
        XCTAssertEqual(merged.id, "segment-1")
        XCTAssertEqual(merged.sourceSegmentID, "segment-2")
        XCTAssertEqual(merged.sourceSegmentIDs, ["segment-1", "segment-2"])
        XCTAssertEqual(merged.originalText, "我们先看一下 这个季度的目标")
        XCTAssertEqual(merged.speaker, speaker)
        XCTAssertEqual(merged.sourceLocale, "zh-CN")
        XCTAssertEqual(merged.targetLocale, "en-US")
        XCTAssertTrue(merged.isFinal)
        XCTAssertEqual(merged.translationHealth, .pending)
        XCTAssertEqual(merged.createdAt, Date(timeIntervalSince1970: 120))
    }

    func testAppendingFinalSegmentFromDifferentSpeakerCreatesNewTurn() {
        var store = LiveCaptionStore(sourceLocale: "zh-CN", targetLocale: "en-US")
        _ = store.append(TranscriptSegment(
            id: "segment-1",
            speaker: TranscriptSpeaker(identifier: "speaker-1", label: "User 1"),
            text: "我们先看一下",
            language: "zh-CN",
            isFinal: true
        ))

        _ = store.append(TranscriptSegment(
            id: "segment-2",
            speaker: TranscriptSpeaker(identifier: "speaker-2", label: "User 2"),
            text: "我有一个问题",
            language: "zh-CN",
            isFinal: true
        ))

        XCTAssertEqual(store.turns.count, 2)
        XCTAssertEqual(store.turns.map(\.originalText), ["我们先看一下", "我有一个问题"])
    }

    func testAppendingInterimFromSameSpeakerExtendsLatestTurnWithoutDuplicatingOverlap() {
        var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        let speaker = TranscriptSpeaker(identifier: "speaker-1", label: "User A")
        _ = store.append(TranscriptSegment(
            id: "final-1",
            speaker: speaker,
            text: "So I just No. It works. It",
            language: "en-US",
            isFinal: true
        ))

        let updated = store.append(TranscriptSegment(
            id: "interim-1",
            speaker: speaker,
            text: "No. It works. It works very well.",
            language: "en-US",
            isFinal: false
        ))

        XCTAssertEqual(store.turns.count, 1)
        XCTAssertEqual(updated.id, "final-1")
        XCTAssertEqual(updated.sourceSegmentID, "final-1")
        XCTAssertEqual(updated.sourceSegmentIDs, ["final-1", "interim-1"])
        XCTAssertEqual(updated.originalText, "So I just No. It works. It works very well.")
        XCTAssertFalse(updated.isFinal)
        XCTAssertEqual(updated.chunkState, .draft)
    }

    func testAppendingInterimContainingLatestTurnKeepsSingleCompleteText() {
        var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        let speaker = TranscriptSpeaker(identifier: "speaker-1", label: "User A")
        _ = store.append(TranscriptSegment(
            id: "final-1",
            speaker: speaker,
            text: "It works very well.",
            language: "en-US",
            isFinal: true
        ))

        let updated = store.append(TranscriptSegment(
            id: "interim-1",
            speaker: speaker,
            text: "No. It works very well. Oh.",
            language: "en-US",
            isFinal: false
        ))

        XCTAssertEqual(store.turns.count, 1)
        XCTAssertEqual(updated.sourceSegmentIDs, ["final-1", "interim-1"])
        XCTAssertEqual(updated.originalText, "No. It works very well. Oh.")
        XCTAssertFalse(updated.isFinal)
    }

    func testUpsertingSoftSealedTurnPreservesDraftTranslationState() {
        var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        let turn = LiveCaptionTurn(
            sourceSegmentID: "segment-1",
            originalText: "That sounds good.",
            isFinal: true,
            chunkState: .frozen,
            freezeReason: .punctuation,
            displayState: .sealed,
            translationState: .draft,
            boundaryReason: .punctuation,
            boundaryStrength: .soft
        )

        store.upsert(turn)

        XCTAssertEqual(store.turns.first?.displayState, .sealed)
        XCTAssertEqual(store.turns.first?.translationState, .draft)
        XCTAssertEqual(store.turns.first?.boundaryStrength, .soft)
    }

    func testAppendingInterimToSoftSealedSameSpeakerBlockKeepsDisplayDraftOnlyWhenOverlapping() {
        var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        let speaker = TranscriptSpeaker(identifier: "speaker-1", label: "User A")
        store.upsert(LiveCaptionTurn(
            sourceSegmentID: "final-1",
            speaker: speaker,
            originalText: "No. It works.",
            isFinal: true,
            chunkState: .frozen,
            freezeReason: .punctuation,
            displayState: .sealed,
            translationState: .draft,
            boundaryReason: .punctuation,
            boundaryStrength: .soft
        ))

        let updated = store.append(TranscriptSegment(
            id: "interim-1",
            speaker: speaker,
            text: "It works very well.",
            language: "en-US",
            isFinal: false
        ))

        XCTAssertEqual(store.turns.count, 1)
        XCTAssertEqual(updated.displayState, .draft)
        XCTAssertEqual(updated.translationState, .draft)
        XCTAssertNil(updated.boundaryReason)
        XCTAssertNil(updated.boundaryStrength)
    }

    func testMergingSameSpeakerPreservesTranslationWhileRetranslating() {
        var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        let speaker = TranscriptSpeaker(identifier: "speaker-1", label: "User 1")
        _ = store.append(TranscriptSegment(
            id: "segment-1",
            speaker: speaker,
            text: "first",
            language: "en-US",
            isFinal: true
        ))
        store.attachTranslation("第一句", toTurnID: "segment-1")

        let merged = store.append(TranscriptSegment(
            id: "segment-2",
            speaker: speaker,
            text: "second",
            language: "en-US",
            isFinal: true
        ))

        XCTAssertEqual(merged.originalText, "first second")
        XCTAssertEqual(merged.translatedText, "第一句")
        XCTAssertEqual(merged.translationHealth, .pending)
        XCTAssertEqual(store.turns.first?.translatedText, "第一句")
        XCTAssertEqual(store.turns.first?.translationHealth, .pending)
    }

    func testAppendingAlreadyRepresentedSegmentToMergedTurnDoesNotDuplicateText() {
        var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        let speaker = TranscriptSpeaker(identifier: "speaker-1", label: "User 1")
        _ = store.append(TranscriptSegment(id: "segment-1", speaker: speaker, text: "first", language: "en-US", isFinal: true))
        _ = store.append(TranscriptSegment(id: "segment-2", speaker: speaker, text: "second", language: "en-US", isFinal: true))

        let existing = store.append(TranscriptSegment(id: "segment-1", speaker: speaker, text: "first", language: "en-US", isFinal: true))

        XCTAssertEqual(store.turns.count, 1)
        XCTAssertEqual(existing.originalText, "first second")
        XCTAssertEqual(existing.sourceSegmentIDs, ["segment-1", "segment-2"])
        XCTAssertEqual(store.turns.first?.originalText, "first second")
    }

    func testUpsertingDraftUpdatesSameTurn() {
        var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        let draft = LiveCaptionTurn(
            sourceSegmentID: "segment-1",
            originalText: "first",
            isFinal: true,
            chunkState: .draft,
            translationRevision: 1
        )
        let updatedDraft = LiveCaptionTurn(
            id: draft.id,
            sourceSegmentID: "segment-2",
            sourceSegmentIDs: ["segment-1", "segment-2"],
            originalText: "first second",
            isFinal: true,
            chunkState: .draft,
            translationRevision: 2
        )

        store.upsert(draft)
        store.upsert(updatedDraft)

        XCTAssertEqual(store.turns.count, 1)
        XCTAssertEqual(store.turns.first?.originalText, "first second")
        XCTAssertEqual(store.turns.first?.translationRevision, 2)
    }

    func testFrozenSameSpeakerTurnDoesNotMergeWithLaterDraft() {
        var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        let frozen = LiveCaptionTurn(
            sourceSegmentID: "segment-1",
            speaker: TranscriptSpeaker(identifier: "speaker-1"),
            originalText: "finished",
            isFinal: true,
            chunkState: .frozen,
            freezeReason: .speechFinal
        )
        let nextDraft = LiveCaptionTurn(
            sourceSegmentID: "segment-2",
            speaker: TranscriptSpeaker(identifier: "speaker-1"),
            originalText: "new thought",
            isFinal: true,
            chunkState: .draft,
            translationRevision: 1
        )

        store.upsert(frozen)
        store.upsert(nextDraft)

        XCTAssertEqual(store.turns.map(\.originalText), ["finished", "new thought"])
    }

    func testAttachTranslationUpdatesSameTurn() {
        var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        _ = store.append(TranscriptSegment(id: "segment-1", text: "hello", language: "en-US"))

        store.attachTranslation("你好", toTurnID: "segment-1")

        XCTAssertEqual(store.turns.first?.translatedText, "你好")
        XCTAssertEqual(store.turns.first?.translationHealth, .live)
    }

    func testAppendTranslationCombinesTranslatedTextForMergedTurn() {
        var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
        let speaker = TranscriptSpeaker(identifier: "speaker-1", label: "User 1")
        _ = store.append(TranscriptSegment(id: "segment-1", speaker: speaker, text: "first", language: "en-US", isFinal: true))
        _ = store.append(TranscriptSegment(id: "segment-2", speaker: speaker, text: "second", language: "en-US", isFinal: true))

        store.appendTranslation("第一句", toTurnID: "segment-1")
        store.appendTranslation("第二句", toTurnID: "segment-1")

        XCTAssertEqual(store.turns.first?.translatedText, "第一句 第二句")
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
