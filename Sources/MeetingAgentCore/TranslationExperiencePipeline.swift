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
    private var unitBuilder: TranslationUnitBuilder
    private var liveScheduler: LiveTranslationScheduler
    private var accurateScheduler: AccurateTranslationScheduler
    private var resultStore = TranslationResultStore()

    public init(
        sourceLocale: String,
        targetLocale: String,
        liveProvider: TextTranslationProvider,
        accurateProvider: TextTranslationProvider
    ) {
        self.unitBuilder = TranslationUnitBuilder(sourceLocale: sourceLocale, targetLocale: targetLocale)
        self.liveScheduler = LiveTranslationScheduler(provider: liveProvider)
        self.accurateScheduler = AccurateTranslationScheduler(provider: accurateProvider)
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

        let lanes = Set((liveResults + stableResults).map(\.laneID))
        let visibleResults = lanes.compactMap { resultStore.visibleResult(for: $0) }
        return TranslationExperiencePipelineSnapshot(
            liveResults: liveResults,
            stableResults: stableResults,
            visibleResults: visibleResults
        )
    }
}
