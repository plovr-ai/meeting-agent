import XCTest
@testable import MeetingAgentCore

final class TranslationUnitBuilderTests: XCTestCase {
    func testFlushOpenBlocksSortsMultipleLanesDeterministically() {
        var builder = TranslationUnitBuilder(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            configuration: TranslationUnitBuilderConfiguration(minimumStableBlockCharacters: 5)
        )
        _ = builder.apply(segments: [
            TranscriptSegment(id: "segment-b", speaker: TranscriptSpeaker(identifier: "speaker-b"), text: "Second lane text", language: "en-US", isFinal: true),
            TranscriptSegment(id: "segment-a", speaker: TranscriptSpeaker(identifier: "speaker-a"), text: "First lane text", language: "en-US", isFinal: true)
        ], now: Date(timeIntervalSince1970: 1))

        let blocks = builder.flushOpenBlocks(now: Date(timeIntervalSince1970: 2))

        XCTAssertEqual(blocks.map(\.sourceSegmentIDs), [["segment-a"], ["segment-b"]])
    }

    func testLiveUnitUsesConfiguredSourceLocaleWhenSegmentLanguageIsMissing() {
        var builder = TranslationUnitBuilder(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            configuration: TranslationUnitBuilderConfiguration(minimumLiveWords: 2)
        )

        let output = builder.apply(segments: [
            TranscriptSegment(id: "segment-1", text: "Confirm owner today", isFinal: false)
        ], now: Date(timeIntervalSince1970: 1))

        XCTAssertEqual(output.liveUnits.first?.laneID.sourceLocale, "en-US")
        XCTAssertEqual(output.liveUnits.first?.revision, 1)
    }

    func testManualStopCanSealShortNonFillerText() {
        var builder = TranslationUnitBuilder(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            configuration: TranslationUnitBuilderConfiguration(minimumStableBlockCharacters: 20)
        )
        _ = builder.apply(segments: [
            TranscriptSegment(id: "segment-1", text: "go live", language: "en-US", isFinal: true)
        ], now: Date(timeIntervalSince1970: 1))

        let blocks = builder.flushOpenBlocks(now: Date(timeIntervalSince1970: 2))

        XCTAssertEqual(blocks.first?.sourceText, "go live")
        XCTAssertEqual(blocks.first?.boundaryReason, .manualStop)
    }

    func testMaxLengthAndMaxDurationSealStableBlocks() {
        var lengthBuilder = TranslationUnitBuilder(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            configuration: TranslationUnitBuilderConfiguration(
                minimumStableBlockCharacters: 5,
                maximumStableBlockCharacters: 10,
                maximumStableBlockDuration: 60
            )
        )
        let lengthOutput = lengthBuilder.apply(segments: [
            TranscriptSegment(id: "segment-1", text: "This text is long enough", language: "en-US", isFinal: true)
        ], now: Date(timeIntervalSince1970: 1))

        var durationBuilder = TranslationUnitBuilder(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            configuration: TranslationUnitBuilderConfiguration(
                minimumStableBlockCharacters: 5,
                maximumStableBlockCharacters: 100,
                maximumStableBlockDuration: 1
            )
        )
        _ = durationBuilder.apply(segments: [
            TranscriptSegment(id: "segment-2", text: "Short open text", language: "en-US", isFinal: true, createdAt: Date(timeIntervalSince1970: 1))
        ], now: Date(timeIntervalSince1970: 1))
        let durationOutput = durationBuilder.apply(segments: [
            TranscriptSegment(id: "segment-3", text: "Short open text continued", language: "en-US", isFinal: true, createdAt: Date(timeIntervalSince1970: 3))
        ], now: Date(timeIntervalSince1970: 3))

        XCTAssertEqual(lengthOutput.stableBlocks.first?.boundaryReason, .maxLength)
        XCTAssertEqual(durationOutput.stableBlocks.first?.boundaryReason, .maxDuration)
    }

    func testManualStopDoesNotEmitEmptyOrFillerOnlyBlocks() {
        var emptyBuilder = TranslationUnitBuilder(sourceLocale: "en-US", targetLocale: "zh-CN")
        let emptyBlocks = emptyBuilder.flushOpenBlocks(now: Date(timeIntervalSince1970: 1))

        var fillerBuilder = TranslationUnitBuilder(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            configuration: TranslationUnitBuilderConfiguration(minimumStableBlockCharacters: 2)
        )
        _ = fillerBuilder.apply(segments: [
            TranscriptSegment(id: "segment-1", text: "um", language: "en-US", isFinal: true)
        ], now: Date(timeIntervalSince1970: 1))
        let fillerBlocks = fillerBuilder.flushOpenBlocks(now: Date(timeIntervalSince1970: 2))

        XCTAssertTrue(emptyBlocks.isEmpty)
        XCTAssertTrue(fillerBlocks.isEmpty)
    }

    func testIsFinalAdvancesStablePrefixButDoesNotSealBlock() {
        var builder = TranslationUnitBuilder(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            configuration: TranslationUnitBuilderConfiguration(minimumLiveWords: 4, unstableTailWords: 1, minimumStableBlockCharacters: 10)
        )
        let segment = TranscriptSegment(
            id: "segment-1",
            speaker: TranscriptSpeaker(identifier: "speaker-1"),
            text: "Select settings and about",
            language: "en-US",
            isFinal: true,
            speechFinal: false,
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let output = builder.apply(segments: [segment], now: Date(timeIntervalSince1970: 2))

        XCTAssertEqual(output.liveUnits.count, 1)
        XCTAssertEqual(output.liveUnits.first?.stablePrefixText, "Select settings and")
        XCTAssertTrue(output.stableBlocks.isEmpty)
    }

    func testSpeechFinalSealsAccumulatedLaneBlock() {
        var builder = TranslationUnitBuilder(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            configuration: TranslationUnitBuilderConfiguration(minimumLiveWords: 4, unstableTailWords: 1, minimumStableBlockCharacters: 10)
        )
        let first = TranscriptSegment(
            id: "segment-1",
            speaker: TranscriptSpeaker(identifier: "speaker-1"),
            text: "Select settings and about",
            language: "en-US",
            isFinal: true,
            speechFinal: false,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let second = TranscriptSegment(
            id: "segment-2",
            speaker: TranscriptSpeaker(identifier: "speaker-1"),
            text: "then choose public preview.",
            language: "en-US",
            isFinal: true,
            speechFinal: true,
            createdAt: Date(timeIntervalSince1970: 2)
        )

        _ = builder.apply(segments: [first], now: Date(timeIntervalSince1970: 3))
        let output = builder.apply(segments: [first, second], now: Date(timeIntervalSince1970: 4))

        XCTAssertEqual(output.stableBlocks.count, 1)
        XCTAssertEqual(output.stableBlocks.first?.sourceText, "Select settings and about then choose public preview.")
        XCTAssertEqual(output.stableBlocks.first?.sourceSegmentIDs, ["segment-1", "segment-2"])
        XCTAssertEqual(output.stableBlocks.first?.boundaryReason, .providerHardBoundary)
    }

    func testManualStopFlushSealsOpenBlock() {
        var builder = TranslationUnitBuilder(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            configuration: TranslationUnitBuilderConfiguration(minimumLiveWords: 4, unstableTailWords: 1, minimumStableBlockCharacters: 10)
        )
        let segment = TranscriptSegment(
            id: "segment-1",
            speaker: TranscriptSpeaker(identifier: "speaker-1"),
            text: "We should review the rollout status",
            language: "en-US",
            isFinal: true,
            speechFinal: false,
            createdAt: Date(timeIntervalSince1970: 1)
        )

        _ = builder.apply(segments: [segment], now: Date(timeIntervalSince1970: 2))
        let flushed = builder.flushOpenBlocks(now: Date(timeIntervalSince1970: 3))

        XCTAssertEqual(flushed.count, 1)
        XCTAssertEqual(flushed.first?.sourceText, "We should review the rollout status")
        XCTAssertEqual(flushed.first?.boundaryReason, .manualStop)
    }

    func testInterimChurnUpdatesLiveUnitWithoutStableBlock() {
        var builder = TranslationUnitBuilder(sourceLocale: "en-US", targetLocale: "zh-CN")
        let createdAt = Date(timeIntervalSince1970: 1)
        let segment = TranscriptSegment(
            id: "segment-1",
            speaker: TranscriptSpeaker(identifier: "speaker-1"),
            text: "We should confirm the launch owner today",
            language: "en-US",
            isFinal: false,
            createdAt: createdAt
        )

        let output = builder.apply(segments: [segment], now: Date(timeIntervalSince1970: 2))

        XCTAssertEqual(output.liveUnits.count, 1)
        XCTAssertEqual(output.liveUnits.first?.stablePrefixText, "We should confirm the launch owner")
        XCTAssertEqual(output.liveUnits.first?.unstableTailText, "today")
        XCTAssertTrue(output.stableBlocks.isEmpty)
    }

    func testSpeechFinalCreatesStableBlock() {
        var builder = TranslationUnitBuilder(sourceLocale: "en-US", targetLocale: "zh-CN")
        let segment = TranscriptSegment(
            id: "segment-1",
            speaker: TranscriptSpeaker(identifier: "speaker-1"),
            text: "We approved the launch date.",
            language: "en-US",
            isFinal: true,
            speechFinal: true
        )

        let output = builder.apply(segments: [segment], now: Date(timeIntervalSince1970: 2))

        XCTAssertEqual(output.stableBlocks.count, 1)
        XCTAssertEqual(output.stableBlocks.first?.sourceText, "We approved the launch date.")
        XCTAssertEqual(output.stableBlocks.first?.boundaryReason, .providerHardBoundary)
    }

    func testTerminalPunctuationCreatesStableBlockWithoutSpeechFinal() {
        var builder = TranslationUnitBuilder(sourceLocale: "en-US", targetLocale: "zh-CN")
        let segment = TranscriptSegment(
            id: "segment-1",
            speaker: TranscriptSpeaker(identifier: "speaker-1"),
            text: "We approved the launch date.",
            language: "en-US",
            isFinal: true,
            speechFinal: false
        )

        let output = builder.apply(segments: [segment], now: Date(timeIntervalSince1970: 2))

        XCTAssertEqual(output.stableBlocks.count, 1)
        XCTAssertEqual(output.stableBlocks.first?.boundaryReason, .terminalPunctuation)
    }

    func testRiskFlagsDetectNumbersAndNegation() {
        var builder = TranslationUnitBuilder(sourceLocale: "en-US", targetLocale: "zh-CN")
        let segment = TranscriptSegment(id: "segment-1", text: "We cannot approve 30 percent today", language: "en-US", isFinal: false)

        let output = builder.apply(segments: [segment], now: Date(timeIntervalSince1970: 2))

        XCTAssertTrue(output.liveUnits.first?.riskFlags.contains(.number) == true)
        XCTAssertTrue(output.liveUnits.first?.riskFlags.contains(.negation) == true)
    }

    func testFinalWithoutTerminalPunctuationDoesNotCreateStableBlock() {
        var builder = TranslationUnitBuilder(sourceLocale: "en-US", targetLocale: "zh-CN")
        let segment = TranscriptSegment(
            id: "segment-1",
            text: "We approved the launch date",
            language: "en-US",
            isFinal: true,
            speechFinal: false
        )

        let output = builder.apply(segments: [segment], now: Date(timeIntervalSince1970: 2))

        XCTAssertTrue(output.stableBlocks.isEmpty)
    }

    func testDuplicateStableBlockIsEmittedOnce() {
        var builder = TranslationUnitBuilder(sourceLocale: "en-US", targetLocale: "zh-CN")
        let segment = TranscriptSegment(
            id: "segment-1",
            text: "We approved the launch date.",
            language: "en-US",
            isFinal: true,
            speechFinal: true
        )

        _ = builder.apply(segments: [segment], now: Date(timeIntervalSince1970: 2))
        let second = builder.apply(segments: [segment], now: Date(timeIntervalSince1970: 3))

        XCTAssertTrue(second.stableBlocks.isEmpty)
    }

    func testRiskFlagsDetectCommitment() {
        var builder = TranslationUnitBuilder(sourceLocale: "en-US", targetLocale: "zh-CN")
        let segment = TranscriptSegment(id: "segment-1", text: "We will confirm the launch owner today", language: "en-US", isFinal: false)

        let output = builder.apply(segments: [segment], now: Date(timeIntervalSince1970: 2))

        XCTAssertTrue(output.liveUnits.first?.riskFlags.contains(.commitment) == true)
    }

    func testConfigurationAndOutputEquality() {
        XCTAssertEqual(
            TranslationUnitBuilderConfiguration(minimumLiveWords: 1, unstableTailWords: 1, minimumStableBlockCharacters: 10),
            TranslationUnitBuilderConfiguration(minimumLiveWords: 1, unstableTailWords: 1, minimumStableBlockCharacters: 10)
        )

        XCTAssertEqual(
            TranslationUnitBuilderOutput(liveUnits: [], stableBlocks: []),
            TranslationUnitBuilderOutput(liveUnits: [], stableBlocks: [])
        )
    }
}
