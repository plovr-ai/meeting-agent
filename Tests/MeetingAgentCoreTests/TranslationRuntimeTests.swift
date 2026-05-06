import XCTest
@testable import MeetingAgentCore

final class TranslationRuntimeTests: XCTestCase {
    func testHydrateReturnsStableResultsFromPersistenceRecords() {
        let meetingID = UUID(uuidString: "00000000-0000-0000-0000-000000000111")!
        let lane = TranslationLaneID(speaker: .default, sourceLocale: "en-US", targetLocale: "zh-CN")
        let record = TranslationResultPersistenceRecord(
            meetingID: meetingID,
            resultID: "stable-1",
            sourceID: "block-1",
            laneID: lane,
            sourceSegmentIDs: ["segment-1"],
            sourceTextHash: "hash",
            sourceText: "We approve the rollout.",
            translatedText: "我们批准上线。",
            displayState: .stableFinal,
            boundaryReason: .providerHardBoundary,
            providerID: "test",
            createdAt: Date(timeIntervalSince1970: 1),
            finalizedAt: Date(timeIntervalSince1970: 2)
        )

        var runtime = TranslationRuntime()
        let hydrated = runtime.hydrate(records: [record])

        XCTAssertEqual(hydrated.map(\.id), ["stable-1"])
        XCTAssertEqual(hydrated.first?.displayState, .stableFinal)
        XCTAssertEqual(hydrated.first?.sourceSegmentIDs, ["segment-1"])
    }

    func testApplyWithoutStartedContextReturnsIdleSnapshot() async {
        var runtime = TranslationRuntime()

        let snapshot = await runtime.apply(
            document: TranscriptDocument(segments: [
                TranscriptSegment(id: "segment-1", text: "We approve the rollout today", language: "en-US", isFinal: false)
            ]),
            generation: 1,
            now: Date(timeIntervalSince1970: 1)
        )

        XCTAssertTrue(snapshot.visibleResults.isEmpty)
        XCTAssertTrue(snapshot.droppedResults.isEmpty)
        XCTAssertEqual(snapshot.state, .idle)
    }

    func testApplyUsesUnitPipelineAndReturnsVisibleLiveResult() async {
        let provider = RuntimeTranslationProvider(translations: ["segment-1-live-1": "我们确认负责人"])
        var persisted: [TranslationResultPersistenceRecord] = []
        var runtime = TranslationRuntime()
        runtime.start(
            context: TranslationRuntimeContext(
                meetingID: UUID(uuidString: "00000000-0000-0000-0000-000000000222")!,
                sourceLocale: "en-US",
                targetLocale: "zh-CN",
                generation: 1
            ),
            liveProvider: provider,
            accurateProvider: provider,
            performanceEventLogger: nil,
            persistFinalResult: { persisted.append($0) }
        )

        let snapshot = await runtime.apply(
            document: TranscriptDocument(segments: [
                TranscriptSegment(
                    id: "segment-1",
                    text: "We should confirm the launch owner today",
                    language: "en-US",
                    isFinal: false,
                    createdAt: Date(timeIntervalSince1970: 1)
                )
            ]),
            generation: 1,
            now: Date(timeIntervalSince1970: 2)
        )

        XCTAssertEqual(snapshot.state, .active)
        XCTAssertEqual(snapshot.liveResults.count, 1)
        XCTAssertEqual(snapshot.visibleResults.first?.translatedText, "我们确认负责人")
        XCTAssertTrue(persisted.isEmpty)
    }
}

private final class RuntimeTranslationProvider: TextTranslationProvider {
    let translations: [String: String]
    private(set) var requestIDs: [String] = []

    init(translations: [String: String]) {
        self.translations = translations
    }

    var descriptor: ProviderDescriptor {
        ProviderDescriptor(
            id: "runtime-test",
            displayName: "Runtime Test",
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
        requestIDs.append(segment.id)
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
            provenance: PipelineProvenance(profileID: "runtime-test", successfulProviders: ["runtime-test"])
        )
    }
}
