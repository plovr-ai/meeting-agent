import Foundation

public struct TranslationExperiencePipelineSnapshot: Equatable {
    public var liveResults: [TranslationResult]
    public var stableResults: [TranslationResult]
    public var visibleResults: [TranslationResult]

    public init(
        liveResults: [TranslationResult],
        stableResults: [TranslationResult],
        visibleResults: [TranslationResult]
    ) {
        self.liveResults = liveResults
        self.stableResults = stableResults
        self.visibleResults = visibleResults
    }
}

public struct TranslationExperiencePipeline {
    private let meetingID: UUID
    private let accurateProviderID: String
    private var unitBuilder: TranslationUnitBuilder
    private var liveScheduler: LiveTranslationScheduler
    private var accurateScheduler: AccurateTranslationScheduler
    private var resultStore = TranslationResultStore()
    private let persistFinalResult: ((TranslationResultPersistenceRecord) -> Void)?

    public init(
        meetingID: UUID = UUID(),
        sourceLocale: String,
        targetLocale: String,
        liveProvider: TextTranslationProvider,
        accurateProvider: TextTranslationProvider,
        persistFinalResult: ((TranslationResultPersistenceRecord) -> Void)? = nil
    ) {
        self.meetingID = meetingID
        self.accurateProviderID = accurateProvider.descriptor.id
        self.unitBuilder = TranslationUnitBuilder(sourceLocale: sourceLocale, targetLocale: targetLocale)
        self.liveScheduler = LiveTranslationScheduler(provider: liveProvider)
        self.accurateScheduler = AccurateTranslationScheduler(provider: accurateProvider)
        self.persistFinalResult = persistFinalResult
    }

    public mutating func apply(
        segments: [TranscriptSegment],
        now: Date = Date()
    ) async -> TranslationExperiencePipelineSnapshot {
        let units = unitBuilder.apply(segments: segments, now: now)
        let liveResults = await liveScheduler.schedule(units.liveUnits)
        let stableResults = await accurateScheduler.translate(units.stableBlocks)

        for result in liveResults + stableResults {
            resultStore.attach(result)
        }
        persistStableResults(stableResults, blocks: units.stableBlocks, finalizedAt: now)

        let lanes = Set((liveResults + stableResults).map(\.laneID))
        let visibleResults = lanes.compactMap { resultStore.visibleResult(for: $0) }
        return TranslationExperiencePipelineSnapshot(
            liveResults: liveResults,
            stableResults: stableResults,
            visibleResults: visibleResults
        )
    }

    public mutating func flushAndFinalize(now: Date = Date()) async -> TranslationExperiencePipelineSnapshot {
        let blocks = unitBuilder.flushOpenBlocks(now: now)
        let stableResults = await accurateScheduler.translate(blocks)

        for result in stableResults {
            resultStore.attach(result)
        }
        persistStableResults(stableResults, blocks: blocks, finalizedAt: now)

        let lanes = Set(stableResults.map(\.laneID))
        let visibleResults = lanes.compactMap { resultStore.visibleResult(for: $0) }
        return TranslationExperiencePipelineSnapshot(
            liveResults: [],
            stableResults: stableResults,
            visibleResults: visibleResults
        )
    }

    private func persistStableResults(
        _ results: [TranslationResult],
        blocks: [StableTranslationBlock],
        finalizedAt: Date
    ) {
        guard let persistFinalResult else { return }
        for result in results {
            guard let record = persistenceRecord(
                for: result,
                boundaryReason: blocks.first(where: { $0.id == result.sourceID })?.boundaryReason,
                finalizedAt: finalizedAt
            ) else {
                continue
            }
            persistFinalResult(record)
        }
    }

    private func persistenceRecord(
        for result: TranslationResult,
        boundaryReason: StableTranslationBoundaryReason?,
        finalizedAt: Date
    ) -> TranslationResultPersistenceRecord? {
        guard result.displayState == .stableFinal || result.displayState == .failedRecoverable else {
            return nil
        }
        return TranslationResultPersistenceRecord(
            meetingID: meetingID,
            resultID: result.id,
            sourceID: result.sourceID,
            laneID: result.laneID,
            sourceSegmentIDs: result.sourceSegmentIDs,
            sourceTextHash: StableTranslationBlock.stableHash(result.sourceText),
            sourceText: result.sourceText,
            translatedText: result.translatedText,
            displayState: result.displayState,
            boundaryReason: boundaryReason,
            providerID: accurateProviderID,
            createdAt: result.sourceCreatedAt,
            finalizedAt: finalizedAt
        )
    }
}
