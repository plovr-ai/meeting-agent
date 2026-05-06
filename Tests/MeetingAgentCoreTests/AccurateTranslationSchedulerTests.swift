import Foundation
import XCTest
@testable import MeetingAgentCore

@MainActor
final class AccurateTranslationSchedulerTests: XCTestCase {
    func testTranslatesStableBlockAsStableFinal() async {
        let lane = TranslationLaneID(speaker: .default, sourceLocale: "en-US", targetLocale: "zh-CN")
        let provider = AccurateRecordingTranslationProvider(translations: ["block-1": "我们批准上线日期。"])
        var scheduler = AccurateTranslationScheduler(provider: provider)
        let block = StableTranslationBlock(
            id: "block-1",
            laneID: lane,
            sourceText: "We approved the launch date.",
            sourceSegmentIDs: ["segment-1"],
            previousBlockSummary: "Team discussed launch readiness.",
            meetingGoalContext: "Confirm launch date.",
            keyTerms: [MeetingKeyTerm(id: "launch", value: "launch", translationHint: "上线")],
            boundaryReason: .terminalPunctuation,
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let results = await scheduler.translate([block])

        XCTAssertEqual(provider.requests.first?.sourceText, "We approved the launch date.")
        XCTAssertEqual(results.first?.translatedText, "我们批准上线日期。")
        XCTAssertEqual(results.first?.displayState, .stableFinal)
        XCTAssertEqual(results.first?.sourceSegmentIDs, ["segment-1"])
    }

    func testLogsProviderCallStartAndFinishForStableBlock() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("accurate-translation-provider-events-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let eventsURL = root.appendingPathComponent("performance-events.jsonl")
        let lane = TranslationLaneID(speaker: .default, sourceLocale: "en-US", targetLocale: "zh-CN")
        let provider = AccurateRecordingTranslationProvider(translations: ["block-1": "我们批准上线日期。"])
        var scheduler = AccurateTranslationScheduler(
            provider: provider,
            performanceEventLogger: PerformanceEventLogger(url: eventsURL)
        )
        let block = StableTranslationBlock(
            id: "block-1",
            laneID: lane,
            sourceText: "We approved the launch date.",
            sourceSegmentIDs: ["segment-1"],
            boundaryReason: .terminalPunctuation,
            createdAt: Date(timeIntervalSince1970: 1)
        )

        _ = await scheduler.translate([block])

        let events = try readAccurateLoggedEvents(from: eventsURL)
        XCTAssertTrue(events.contains {
            $0.event == "translation_provider_call_started"
                && $0.segmentID == "block-1"
                && $0.metadata["translationKind"] == "final"
                && $0.metadata["providerID"] == "test-accurate"
        })
        XCTAssertTrue(events.contains {
            $0.event == "translation_provider_call_finished"
                && $0.segmentID == "block-1"
                && $0.metadata["translationKind"] == "final"
                && $0.metadata["providerID"] == "test-accurate"
        })
    }

    func testRetriesRecoverableFailureBeforeStableFinal() async {
        let lane = TranslationLaneID(speaker: .default, sourceLocale: "en-US", targetLocale: "zh-CN")
        let provider = AccurateSequencedTranslationProvider(outcomes: [
            .failure(NSError(domain: "translation", code: 1)),
            .success("我们批准上线日期。")
        ])
        var scheduler = AccurateTranslationScheduler(
            provider: provider,
            configuration: AccurateTranslationSchedulerConfiguration(retryCount: 1)
        )
        let block = StableTranslationBlock(
            id: "block-1",
            laneID: lane,
            sourceText: "We approved the launch date.",
            sourceSegmentIDs: ["segment-1"],
            boundaryReason: .terminalPunctuation,
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let results = await scheduler.translate([block])

        XCTAssertEqual(provider.requests.count, 2)
        XCTAssertEqual(results.first?.translatedText, "我们批准上线日期。")
        XCTAssertEqual(results.first?.displayState, .stableFinal)
    }

    func testFailureReturnsRecoverableResult() async {
        let lane = TranslationLaneID(speaker: .default, sourceLocale: "en-US", targetLocale: "zh-CN")
        let provider = AccurateSequencedTranslationProvider(outcomes: [
            .failure(NSError(domain: "translation", code: 1))
        ])
        var scheduler = AccurateTranslationScheduler(
            provider: provider,
            configuration: AccurateTranslationSchedulerConfiguration(retryCount: 0)
        )
        let block = StableTranslationBlock(
            id: "block-1",
            laneID: lane,
            sourceText: "We approved the launch date.",
            sourceSegmentIDs: ["segment-1"],
            boundaryReason: .terminalPunctuation,
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let results = await scheduler.translate([block])

        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertEqual(results.first?.displayState, .failedRecoverable)
        XCTAssertEqual(results.first?.sourceSegmentIDs, ["segment-1"])
    }

    func testLogsProviderCallFailureForStableBlock() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("accurate-translation-provider-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let eventsURL = root.appendingPathComponent("performance-events.jsonl")
        let lane = TranslationLaneID(speaker: .default, sourceLocale: "en-US", targetLocale: "zh-CN")
        let provider = AccurateSequencedTranslationProvider(outcomes: [
            .failure(NSError(domain: "translation", code: 1))
        ])
        var scheduler = AccurateTranslationScheduler(
            provider: provider,
            configuration: AccurateTranslationSchedulerConfiguration(retryCount: 0),
            performanceEventLogger: PerformanceEventLogger(url: eventsURL)
        )
        let block = StableTranslationBlock(
            id: "block-1",
            laneID: lane,
            sourceText: "We approved the launch date.",
            sourceSegmentIDs: ["segment-1"],
            boundaryReason: .terminalPunctuation,
            createdAt: Date(timeIntervalSince1970: 1)
        )

        _ = await scheduler.translate([block])

        let events = try readAccurateLoggedEvents(from: eventsURL)
        XCTAssertTrue(events.contains {
            $0.event == "translation_provider_call_started"
                && $0.segmentID == "block-1"
        })
        XCTAssertTrue(events.contains {
            $0.event == "translation_provider_call_failed"
                && $0.segmentID == "block-1"
                && $0.metadata["providerID"] == "test-accurate-sequenced"
        })
    }

    func testDoesNotTranslateStableBlockTwiceAfterSuccess() async {
        let lane = TranslationLaneID(speaker: .default, sourceLocale: "en-US", targetLocale: "zh-CN")
        let provider = AccurateRecordingTranslationProvider(translations: ["block-1": "我们批准上线日期。"])
        var scheduler = AccurateTranslationScheduler(provider: provider)
        let block = StableTranslationBlock(
            id: "block-1",
            laneID: lane,
            sourceText: "We approved the launch date.",
            sourceSegmentIDs: ["segment-1"],
            boundaryReason: .terminalPunctuation,
            createdAt: Date(timeIntervalSince1970: 1)
        )

        _ = await scheduler.translate([block])
        let secondResults = await scheduler.translate([block])

        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertTrue(secondResults.isEmpty)
    }

    func testConfigurationNormalizesRetryCountAndSupportsEquality() {
        XCTAssertEqual(
            AccurateTranslationSchedulerConfiguration(timeoutNanoseconds: 1, retryCount: -1),
            AccurateTranslationSchedulerConfiguration(timeoutNanoseconds: 1, retryCount: 0)
        )
    }

    func testStableSuccessWithMissingReturnedSegmentUsesEmptyTranslation() async {
        let lane = TranslationLaneID(speaker: .default, sourceLocale: "en-US", targetLocale: "zh-CN")
        let provider = EmptyAccurateTranslationProvider()
        var scheduler = AccurateTranslationScheduler(provider: provider)
        let block = StableTranslationBlock(
            id: "block-1",
            laneID: lane,
            sourceText: "We approved the launch date.",
            sourceSegmentIDs: ["segment-1"],
            boundaryReason: .terminalPunctuation,
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let results = await scheduler.translate([block])

        XCTAssertEqual(results.first?.translatedText, "")
        XCTAssertEqual(results.first?.displayState, .stableFinal)
    }
}

private func readAccurateLoggedEvents(from url: URL) throws -> [PerformanceEvent] {
    try String(contentsOf: url, encoding: .utf8)
        .split(separator: "\n")
        .map { try JSONDecoder.meetingAgent.decode(PerformanceEvent.self, from: Data($0.utf8)) }
}

private final class AccurateRecordingTranslationProvider: TextTranslationProvider {
    struct Request: Equatable {
        var id: String
        var sourceText: String
    }

    private let translations: [String: String]
    private(set) var requests: [Request] = []

    init(translations: [String: String]) {
        self.translations = translations
    }

    var descriptor: ProviderDescriptor {
        ProviderDescriptor(
            id: "test-accurate",
            displayName: "Test Accurate",
            capability: .textTranslation,
            executionMode: .hosted,
            supportedSourceLocales: ["*"],
            supportedTargetLocales: ["*"],
            requiresNetwork: false,
            requiresAPIKey: false
        )
    }

    func translate(transcript: TranscriptDocument, options: TranslationOptions) async throws -> TranslatedTranscript {
        let segment = transcript.segments[0]
        requests.append(Request(id: segment.id, sourceText: segment.text))
        return TranslatedTranscript(
            sourceLocale: options.sourceLocale,
            targetLocale: options.targetLocale,
            segments: [
                BilingualSubtitleSegment(
                    id: segment.id,
                    sourceText: segment.text,
                    targetText: translations[segment.id] ?? "stable \(segment.text)"
                )
            ],
            provenance: PipelineProvenance(profileID: "test-accurate", successfulProviders: ["test-accurate"])
        )
    }
}

private final class EmptyAccurateTranslationProvider: TextTranslationProvider {
    var descriptor: ProviderDescriptor {
        ProviderDescriptor(
            id: "test-accurate-empty",
            displayName: "Test Accurate Empty",
            capability: .textTranslation,
            executionMode: .hosted,
            supportedSourceLocales: ["*"],
            supportedTargetLocales: ["*"],
            requiresNetwork: false,
            requiresAPIKey: false
        )
    }

    func translate(transcript: TranscriptDocument, options: TranslationOptions) async throws -> TranslatedTranscript {
        TranslatedTranscript(
            sourceLocale: options.sourceLocale,
            targetLocale: options.targetLocale,
            segments: [],
            provenance: PipelineProvenance(profileID: "test-accurate-empty", successfulProviders: ["test-accurate-empty"])
        )
    }
}

private final class AccurateSequencedTranslationProvider: TextTranslationProvider {
    enum Outcome {
        case success(String)
        case failure(Error)
    }

    struct Request: Equatable {
        var id: String
        var sourceText: String
    }

    private var outcomes: [Outcome]
    private(set) var requests: [Request] = []

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    var descriptor: ProviderDescriptor {
        ProviderDescriptor(
            id: "test-accurate-sequenced",
            displayName: "Test Accurate Sequenced",
            capability: .textTranslation,
            executionMode: .hosted,
            supportedSourceLocales: ["*"],
            supportedTargetLocales: ["*"],
            requiresNetwork: false,
            requiresAPIKey: false
        )
    }

    func translate(transcript: TranscriptDocument, options: TranslationOptions) async throws -> TranslatedTranscript {
        let segment = transcript.segments[0]
        requests.append(Request(id: segment.id, sourceText: segment.text))
        let outcome = outcomes.isEmpty ? .success("stable \(segment.text)") : outcomes.removeFirst()
        switch outcome {
        case let .success(text):
            return TranslatedTranscript(
                sourceLocale: options.sourceLocale,
                targetLocale: options.targetLocale,
                segments: [
                    BilingualSubtitleSegment(
                        id: segment.id,
                        sourceText: segment.text,
                        targetText: text
                    )
                ],
                provenance: PipelineProvenance(profileID: "test-accurate-sequenced", successfulProviders: ["test-accurate-sequenced"])
            )
        case let .failure(error):
            throw error
        }
    }
}
