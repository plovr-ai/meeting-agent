@MainActor
final class RealtimeCaptionSession {
    private var pipeline: LiveCaptionPipeline

    init(pipeline: LiveCaptionPipeline) {
        self.pipeline = pipeline
    }

    func replacePipeline(_ pipeline: LiveCaptionPipeline) {
        self.pipeline = pipeline
    }

    func apply(_ result: TranscriptSegmentAccumulationResult) async -> LiveCaptionPipelineSnapshot {
        await pipeline.apply(result)
    }

    func flushCaptionsOnly(reason: LiveCaptionFreezeReason) -> LiveCaptionPipelineSnapshot {
        pipeline.flushCaptionsOnly(reason: reason)
    }

    func scheduleLegacyReplayBackfillTranslations() async -> LiveCaptionPipelineSnapshot {
        await pipeline.scheduleLegacyReplayBackfillTranslations()
    }

    func scheduleLivePendingTranslations() async -> LiveCaptionPipelineSnapshot {
        await pipeline.scheduleLivePendingTranslations()
    }

    func attachTranslationResults(_ results: [TranslationResult]) -> LiveCaptionPipelineSnapshot {
        pipeline.attachTranslationResults(results)
    }
}
