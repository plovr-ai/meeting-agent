import XCTest
@testable import MeetingAgentCore

final class TranslationRuntimeTests: XCTestCase {
    func testActorProviderlessStartReturnsActiveSnapshotAndResetReturnsIdle() async {
        let actor = TranslationRuntimeActor()
        await actor.start(context: TranslationRuntimeContext(
            meetingID: UUID(uuidString: "00000000-0000-0000-0000-000000000556")!,
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            generation: 1
        ))

        let activeSnapshot = await actor.submit(
            document: TranscriptDocument(segments: [
                TranscriptSegment(id: "segment-1", text: "We approve the launch today", language: "en-US", isFinal: false)
            ]),
            generation: 1,
            now: Date(timeIntervalSince1970: 1)
        )
        await actor.reset()
        let idleSnapshot = await actor.submit(
            document: TranscriptDocument(segments: [
                TranscriptSegment(id: "segment-2", text: "This should not run", language: "en-US", isFinal: false)
            ]),
            generation: 1,
            now: Date(timeIntervalSince1970: 2)
        )

        XCTAssertEqual(activeSnapshot.state, .active)
        XCTAssertTrue(activeSnapshot.visibleResults.isEmpty)
        XCTAssertEqual(idleSnapshot.state, .idle)
    }

    func testActorHydrateReturnsStableResultsFromPersistenceRecords() async {
        let meetingID = UUID(uuidString: "00000000-0000-0000-0000-000000000557")!
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
        let actor = TranslationRuntimeActor()

        let hydrated = await actor.hydrate(records: [record])

        XCTAssertEqual(hydrated.map(\.id), ["stable-1"])
        XCTAssertEqual(hydrated.first?.translatedText, "我们批准上线。")
    }

    func testActorSerializesRealtimeApplyAndStopWithoutLosingOpenStableBlock() async throws {
        let provider = DelayedRuntimeTranslationProvider()
        var persisted: [TranslationResultPersistenceRecord] = []
        let actor = TranslationRuntimeActor()
        await actor.start(
            context: TranslationRuntimeContext(
                meetingID: UUID(uuidString: "00000000-0000-0000-0000-000000000555")!,
                sourceLocale: "en-US",
                targetLocale: "zh-CN",
                generation: 1
            ),
            liveProvider: provider,
            accurateProvider: provider,
            persistFinalResult: { persisted.append($0) }
        )

        let applyTask = Task {
            await actor.submit(
                document: TranscriptDocument(segments: [
                    TranscriptSegment(
                        id: "segment-1",
                        text: "We should approve the launch today",
                        language: "en-US",
                        isFinal: true,
                        speechFinal: false,
                        createdAt: Date(timeIntervalSince1970: 1)
                    )
                ]),
                generation: 1,
                now: Date(timeIntervalSince1970: 2)
            )
        }
        try await waitForRuntimeCondition { provider.pendingRequestCount == 1 }

        let stopTask = Task {
            await actor.finalize(generation: 1, now: Date(timeIntervalSince1970: 3))
        }
        provider.completeRequest(at: 0, targetText: "实时翻译先完成。")
        _ = await applyTask.value
        try await waitForRuntimeCondition { provider.pendingRequestCount == 2 }

        provider.completeRequest(at: 1, targetText: "停止时稳定翻译必须完成。")
        let stopSnapshot = await stopTask.value

        XCTAssertEqual(stopSnapshot.state, .stopped)
        XCTAssertEqual(stopSnapshot.stableResults.first?.translatedText, "停止时稳定翻译必须完成。")
        XCTAssertEqual(persisted.map(\.translatedText), ["停止时稳定翻译必须完成。"])
    }

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

    func testProviderlessStartReturnsActiveSnapshotWithoutVisibleResults() async {
        var runtime = TranslationRuntime()
        runtime.start(context: TranslationRuntimeContext(
            meetingID: UUID(uuidString: "00000000-0000-0000-0000-000000000223")!,
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            generation: 1
        ))

        let snapshot = await runtime.apply(
            document: TranscriptDocument(segments: [
                TranscriptSegment(id: "segment-1", text: "We approve the launch today", language: "en-US", isFinal: false)
            ]),
            generation: 1,
            now: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(snapshot.state, .active)
        XCTAssertTrue(snapshot.visibleResults.isEmpty)
    }

    func testStaleGenerationDoesNotApplyProviderPipeline() async {
        let provider = RuntimeTranslationProvider(translations: ["segment-1-live-1": "不应出现"])
        var runtime = TranslationRuntime()
        runtime.start(
            context: TranslationRuntimeContext(
                meetingID: UUID(uuidString: "00000000-0000-0000-0000-000000000224")!,
                sourceLocale: "en-US",
                targetLocale: "zh-CN",
                generation: 2
            ),
            liveProvider: provider,
            accurateProvider: provider
        )

        let snapshot = await runtime.apply(
            document: TranscriptDocument(segments: [
                TranscriptSegment(id: "segment-1", text: "We approve the launch today", language: "en-US", isFinal: false)
            ]),
            generation: 1,
            now: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(snapshot.state, .active)
        XCTAssertTrue(snapshot.visibleResults.isEmpty)
        XCTAssertTrue(provider.requestIDs.isEmpty)
    }

    func testVisibleResultsAreLoggedWithRuntimeMetadata() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("translation-runtime-visible-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let logger = PerformanceEventLogger(url: root.appendingPathComponent("performance-events.jsonl"))
        let provider = RuntimeTranslationProvider(translations: ["segment-1-live-1": "我们确认负责人"])
        var runtime = TranslationRuntime()
        runtime.start(
            context: TranslationRuntimeContext(
                meetingID: UUID(uuidString: "00000000-0000-0000-0000-000000000225")!,
                sourceLocale: "en-US",
                targetLocale: "zh-CN",
                generation: 1
            ),
            liveProvider: provider,
            accurateProvider: provider,
            performanceEventLogger: logger
        )

        _ = await runtime.apply(
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

        let events = try readRuntimeEvents(from: root.appendingPathComponent("performance-events.jsonl"))
        XCTAssertTrue(events.contains {
            $0.event == "translation_live_result_visible"
                && $0.metadata["path"] == "realtime"
                && $0.metadata["translationState"] == "liveFresh"
        })
    }

    func testStopWithMismatchedGenerationDoesNotStopActiveRuntime() async {
        var runtime = TranslationRuntime()
        runtime.start(context: TranslationRuntimeContext(
            meetingID: UUID(uuidString: "00000000-0000-0000-0000-000000000226")!,
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            generation: 2
        ))

        let snapshot = await runtime.stopAndFinalize(generation: 1, now: Date(timeIntervalSince1970: 1))

        XCTAssertEqual(snapshot.state, .active)
        XCTAssertTrue(snapshot.visibleResults.isEmpty)
    }

    func testStopAfterProviderlessStartReturnsStoppedSnapshot() async {
        var runtime = TranslationRuntime()
        runtime.start(context: TranslationRuntimeContext(
            meetingID: UUID(uuidString: "00000000-0000-0000-0000-000000000227")!,
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            generation: 1
        ))

        let snapshot = await runtime.stopAndFinalize(generation: 1, now: Date(timeIntervalSince1970: 1))

        XCTAssertEqual(snapshot.state, .stopped)
        XCTAssertTrue(snapshot.visibleResults.isEmpty)
    }

    func testStopAndFinalizePublishesOnlyStableFinalAndPersistsIt() async {
        let provider = RuntimeTranslationProvider(translations: ["stable-expected": "我们会复查上线状态。"])
        var persisted: [TranslationResultPersistenceRecord] = []
        var runtime = TranslationRuntime()
        runtime.start(
            context: TranslationRuntimeContext(
                meetingID: UUID(uuidString: "00000000-0000-0000-0000-000000000333")!,
                sourceLocale: "en-US",
                targetLocale: "zh-CN",
                generation: 7
            ),
            liveProvider: provider,
            accurateProvider: provider,
            performanceEventLogger: nil,
            persistFinalResult: { persisted.append($0) }
        )
        _ = await runtime.apply(
            document: TranscriptDocument(segments: [
                TranscriptSegment(
                    id: "segment-1",
                    text: "We should review the rollout status",
                    language: "en-US",
                    isFinal: true,
                    speechFinal: false,
                    createdAt: Date(timeIntervalSince1970: 1)
                )
            ]),
            generation: 7,
            now: Date(timeIntervalSince1970: 2)
        )

        let snapshot = await runtime.stopAndFinalize(generation: 7, now: Date(timeIntervalSince1970: 3))

        XCTAssertEqual(snapshot.state, .stopped)
        XCTAssertTrue(snapshot.liveResults.isEmpty)
        XCTAssertEqual(snapshot.stableResults.count, 1)
        XCTAssertEqual(snapshot.visibleResults.first?.displayState, .stableFinal)
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted.first?.sourceSegmentIDs, ["segment-1"])
    }

    func testLatePreviewAfterStopIsDroppedAndLogged() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("translation-runtime-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let logger = PerformanceEventLogger(url: root.appendingPathComponent("performance-events.jsonl"))
        let provider = RuntimeTranslationProvider(translations: ["segment-1-live-1": "我们确认负责人"])
        var runtime = TranslationRuntime()
        runtime.start(
            context: TranslationRuntimeContext(
                meetingID: UUID(uuidString: "00000000-0000-0000-0000-000000000444")!,
                sourceLocale: "en-US",
                targetLocale: "zh-CN",
                generation: 3
            ),
            liveProvider: provider,
            accurateProvider: provider,
            performanceEventLogger: logger
        )

        _ = await runtime.stopAndFinalize(generation: 3, now: Date(timeIntervalSince1970: 4))
        let snapshot = await runtime.apply(
            document: TranscriptDocument(segments: [
                TranscriptSegment(id: "segment-1", text: "We should confirm the launch owner today", language: "en-US", isFinal: false)
            ]),
            generation: 3,
            now: Date(timeIntervalSince1970: 5)
        )

        let events = try String(contentsOf: root.appendingPathComponent("performance-events.jsonl"), encoding: .utf8)
            .split(separator: "\n")
            .map { try JSONDecoder.meetingAgent.decode(PerformanceEvent.self, from: Data($0.utf8)) }
        XCTAssertTrue(snapshot.visibleResults.isEmpty)
        XCTAssertTrue(events.contains { $0.event == "translation_unit_live_dropped_after_stop" })
    }
}

private func readRuntimeEvents(from url: URL) throws -> [PerformanceEvent] {
    try String(contentsOf: url, encoding: .utf8)
        .split(separator: "\n")
        .map { try JSONDecoder.meetingAgent.decode(PerformanceEvent.self, from: Data($0.utf8)) }
}

private func waitForRuntimeCondition(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    condition: () -> Bool
) async throws {
    let started = DispatchTime.now().uptimeNanoseconds
    while !condition() {
        if DispatchTime.now().uptimeNanoseconds - started > timeoutNanoseconds {
            XCTFail("Timed out waiting for runtime condition")
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
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

private final class DelayedRuntimeTranslationProvider: TextTranslationProvider {
    struct PendingRequest {
        let transcript: TranscriptDocument
        let continuation: CheckedContinuation<TranslatedTranscript, Error>
    }

    let descriptor = ProviderDescriptor(
        id: "delayed-runtime-test",
        displayName: "Delayed Runtime Test",
        capability: .textTranslation,
        executionMode: .hosted,
        supportedSourceLocales: ["*"],
        supportedTargetLocales: ["*"],
        requiresNetwork: false,
        requiresAPIKey: false
    )

    private(set) var pendingRequests: [PendingRequest] = []

    var pendingRequestCount: Int {
        pendingRequests.count
    }

    func translate(transcript: TranscriptDocument, options: TranslationOptions) async throws -> TranslatedTranscript {
        try await withCheckedThrowingContinuation { continuation in
            pendingRequests.append(PendingRequest(transcript: transcript, continuation: continuation))
        }
    }

    func completeRequest(at index: Int, targetText: String) {
        let request = pendingRequests[index]
        let segment = request.transcript.segments[0]
        request.continuation.resume(returning: TranslatedTranscript(
            sourceLocale: optionsSourceLocale(for: segment),
            targetLocale: "zh-CN",
            segments: [
                BilingualSubtitleSegment(
                    id: segment.id,
                    sourceText: segment.text,
                    targetText: targetText
                )
            ],
            provenance: PipelineProvenance(profileID: "delayed-runtime-test", successfulProviders: ["delayed-runtime-test"])
        ))
    }

    private func optionsSourceLocale(for segment: TranscriptSegment) -> String {
        segment.language ?? "en-US"
    }
}
