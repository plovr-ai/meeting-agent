import XCTest
@testable import MeetingAgentCore

final class TranslationUnitBuilderTests: XCTestCase {
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
