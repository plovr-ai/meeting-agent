import Foundation
import XCTest
@testable import MeetingAgentCore

@MainActor
final class LiveTranslationSchedulerTests: XCTestCase {
    func testSchedulesOneLiveRequestPerLane() async {
        let lane = TranslationLaneID(speaker: .default, sourceLocale: "en-US", targetLocale: "zh-CN")
        let provider = LiveRecordingTranslationProvider(translations: ["unit-1": "我们确认负责人"])
        var scheduler = LiveTranslationScheduler(
            provider: provider,
            configuration: LiveTranslationSchedulerConfiguration(draftTimeoutNanoseconds: 1_000_000_000)
        )

        let unit = LiveTranslationUnit(
            id: "unit-1",
            laneID: lane,
            stablePrefixText: "We confirm the owner",
            sourceSegmentIDs: ["segment-1"],
            revision: 1,
            createdAt: Date(),
            deadline: Date().addingTimeInterval(4)
        )
        let updates = await scheduler.schedule([unit])

        XCTAssertEqual(provider.requests.map(\.sourceText), ["We confirm the owner"])
        XCTAssertEqual(updates.first?.translatedText, "我们确认负责人")
        XCTAssertEqual(updates.first?.displayState, .liveFresh)
    }

    func testBudgetDisablesExtraLiveRequests() async {
        let lane = TranslationLaneID(speaker: .default, sourceLocale: "en-US", targetLocale: "zh-CN")
        let provider = LiveRecordingTranslationProvider(translations: [:])
        var scheduler = LiveTranslationScheduler(
            provider: provider,
            configuration: LiveTranslationSchedulerConfiguration(maxCallsPerMinute: 1, draftTimeoutNanoseconds: 1_000_000_000)
        )
        let first = LiveTranslationUnit(
            id: "unit-1",
            laneID: lane,
            stablePrefixText: "We confirm the owner",
            sourceSegmentIDs: ["segment-1"],
            revision: 1,
            createdAt: Date(),
            deadline: Date().addingTimeInterval(4)
        )
        let second = LiveTranslationUnit(
            id: "unit-2",
            laneID: lane,
            stablePrefixText: "We confirm the launch owner",
            sourceSegmentIDs: ["segment-1"],
            revision: 2,
            createdAt: Date(),
            deadline: Date().addingTimeInterval(4)
        )

        _ = await scheduler.schedule([first])
        let updates = await scheduler.schedule([second])

        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertEqual(updates.first?.displayState, .disabledBudget)
    }

    func testHighRiskUnitDoesNotLagAttachOlderText() async {
        let lane = TranslationLaneID(speaker: .default, sourceLocale: "en-US", targetLocale: "zh-CN")
        let provider = LiveRecordingTranslationProvider(translations: ["unit-1": "预算是 10%"])
        var scheduler = LiveTranslationScheduler(provider: provider)
        let unit = LiveTranslationUnit(
            id: "unit-1",
            laneID: lane,
            stablePrefixText: "Budget is 10 percent",
            sourceSegmentIDs: ["segment-1"],
            revision: 1,
            createdAt: Date(),
            deadline: Date().addingTimeInterval(4),
            riskFlags: [.number]
        )

        let updates = await scheduler.schedule([unit])

        XCTAssertEqual(updates.first?.displayState, .liveFresh)
        XCTAssertEqual(updates.first?.riskFlags, [.number])
    }
}

private final class LiveRecordingTranslationProvider: TextTranslationProvider {
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
            id: "test-live",
            displayName: "Test Live",
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
                    targetText: translations[segment.id] ?? "translated \(segment.text)"
                )
            ],
            provenance: PipelineProvenance(profileID: "test-live", successfulProviders: ["test-live"])
        )
    }
}
