import Foundation

public enum TranslationRuntimeState: Equatable {
    case idle
    case active
    case stopping
    case stopped
}

public struct TranslationRuntimeContext: Equatable {
    public var meetingID: UUID
    public var sourceLocale: String
    public var targetLocale: String
    public var generation: Int

    public init(
        meetingID: UUID,
        sourceLocale: String,
        targetLocale: String,
        generation: Int
    ) {
        self.meetingID = meetingID
        self.sourceLocale = sourceLocale
        self.targetLocale = targetLocale
        self.generation = generation
    }
}

public struct TranslationRuntimeSnapshot: Equatable {
    public var state: TranslationRuntimeState
    public var liveResults: [TranslationResult]
    public var stableResults: [TranslationResult]
    public var visibleResults: [TranslationResult]
    public var droppedResults: [TranslationResult]

    public init(
        state: TranslationRuntimeState,
        liveResults: [TranslationResult] = [],
        stableResults: [TranslationResult] = [],
        visibleResults: [TranslationResult] = [],
        droppedResults: [TranslationResult] = []
    ) {
        self.state = state
        self.liveResults = liveResults
        self.stableResults = stableResults
        self.visibleResults = visibleResults
        self.droppedResults = droppedResults
    }
}

public actor TranslationRuntimeActor {
    private var runtime = TranslationRuntime()
    private var tail: Task<Void, Never>?
    private var currentOperation: Task<TranslationRuntimeSnapshot, Never>?
    private var epoch = 0

    public init() {}

    public func start(
        context: TranslationRuntimeContext,
        liveProvider: TextTranslationProvider,
        accurateProvider: TextTranslationProvider,
        performanceEventLogger: PerformanceEventLogger? = nil,
        persistFinalResult: ((TranslationResultPersistenceRecord) -> Void)? = nil
    ) {
        epoch += 1
        tail?.cancel()
        currentOperation?.cancel()
        tail = nil
        currentOperation = nil
        runtime = TranslationRuntime()
        runtime.start(
            context: context,
            liveProvider: liveProvider,
            accurateProvider: accurateProvider,
            performanceEventLogger: performanceEventLogger,
            persistFinalResult: persistFinalResult
        )
    }

    public func start(context: TranslationRuntimeContext) {
        epoch += 1
        tail?.cancel()
        currentOperation?.cancel()
        tail = nil
        currentOperation = nil
        runtime = TranslationRuntime()
        runtime.start(context: context)
    }

    public func reset() {
        epoch += 1
        tail?.cancel()
        currentOperation?.cancel()
        tail = nil
        currentOperation = nil
        runtime = TranslationRuntime()
    }

    public func submit(
        document: TranscriptDocument,
        generation: Int,
        now: Date = Date()
    ) async -> TranslationRuntimeSnapshot {
        let operationEpoch = epoch
        let previous = tail
        let operation = Task { [previous] in
            await previous?.value
            return await self.performSubmit(
                document: document,
                generation: generation,
                now: now,
                epoch: operationEpoch
            )
        }
        currentOperation = operation
        tail = Task { _ = await operation.value }
        return await operation.value
    }

    public func finalize(
        generation: Int,
        now: Date = Date()
    ) async -> TranslationRuntimeSnapshot {
        let operationEpoch = epoch
        let previous = tail
        let operation = Task { [previous] in
            await previous?.value
            return await self.performFinalize(
                generation: generation,
                now: now,
                epoch: operationEpoch
            )
        }
        currentOperation = operation
        tail = Task { _ = await operation.value }
        return await operation.value
    }

    public func hydrate(records: [TranslationResultPersistenceRecord]) -> [TranslationResult] {
        runtime.hydrate(records: records)
    }

    private func performSubmit(
        document: TranscriptDocument,
        generation: Int,
        now: Date,
        epoch operationEpoch: Int
    ) async -> TranslationRuntimeSnapshot {
        var localRuntime = runtime
        let snapshot = await localRuntime.apply(document: document, generation: generation, now: now)
        guard operationEpoch == epoch else {
            return TranslationRuntimeSnapshot(state: .idle)
        }
        runtime = localRuntime
        return snapshot
    }

    private func performFinalize(
        generation: Int,
        now: Date,
        epoch operationEpoch: Int
    ) async -> TranslationRuntimeSnapshot {
        var localRuntime = runtime
        let snapshot = await localRuntime.stopAndFinalizeCurrent(now: now)
        guard operationEpoch == epoch else {
            return TranslationRuntimeSnapshot(state: .idle)
        }
        runtime = localRuntime
        return snapshot
    }
}

public struct TranslationRuntime {
    private var context: TranslationRuntimeContext?
    private var state: TranslationRuntimeState = .idle
    private var pipeline: TranslationExperiencePipeline?
    private var hydratedStore = TranslationResultStore()
    private var performanceEventLogger: PerformanceEventLogger?

    public init() {}

    public mutating func start(
        context: TranslationRuntimeContext,
        liveProvider: TextTranslationProvider,
        accurateProvider: TextTranslationProvider,
        performanceEventLogger: PerformanceEventLogger? = nil,
        persistFinalResult: ((TranslationResultPersistenceRecord) -> Void)? = nil
    ) {
        self.context = context
        self.performanceEventLogger = performanceEventLogger
        pipeline = TranslationExperiencePipeline(
            meetingID: context.meetingID,
            sourceLocale: context.sourceLocale,
            targetLocale: context.targetLocale,
            liveProvider: liveProvider,
            accurateProvider: accurateProvider,
            performanceEventLogger: performanceEventLogger,
            persistFinalResult: persistFinalResult
        )
        state = .active
    }

    public mutating func start(context: TranslationRuntimeContext) {
        self.context = context
        state = .active
    }

    public mutating func apply(
        document: TranscriptDocument,
        generation: Int,
        now: Date = Date()
    ) async -> TranslationRuntimeSnapshot {
        guard let context else {
            return TranslationRuntimeSnapshot(state: state)
        }
        guard state == .active else {
            let dropped = syntheticDroppedPreviewResults(from: document, now: now)
            for result in dropped {
                logDroppedAfterStop(result)
            }
            return TranslationRuntimeSnapshot(
                state: state,
                visibleResults: [],
                droppedResults: dropped
            )
        }
        guard context.generation == generation else {
            logSnapshot(path: "stale_generation", liveCount: 0, stableCount: 0, visibleCount: 0, droppedCount: 0)
            return TranslationRuntimeSnapshot(state: state)
        }
        guard var pipeline else {
            return TranslationRuntimeSnapshot(state: state)
        }

        let pipelineSnapshot = await pipeline.apply(segments: document.segments, now: now)
        self.pipeline = pipeline
        let snapshot = TranslationRuntimeSnapshot(
            state: state,
            liveResults: pipelineSnapshot.liveResults,
            stableResults: pipelineSnapshot.stableResults,
            visibleResults: pipelineSnapshot.visibleResults
        )
        logSnapshot(
            path: "realtime",
            liveCount: snapshot.liveResults.count,
            stableCount: snapshot.stableResults.count,
            visibleCount: snapshot.visibleResults.count,
            droppedCount: snapshot.droppedResults.count
        )
        logVisibleResults(snapshot.visibleResults, path: "realtime")
        return snapshot
    }

    public mutating func stopAndFinalize(
        generation: Int,
        now: Date = Date()
    ) async -> TranslationRuntimeSnapshot {
        guard let context, context.generation == generation else {
            return TranslationRuntimeSnapshot(state: state)
        }
        return await stopAndFinalizeCurrent(now: now)
    }

    public mutating func stopAndFinalizeCurrent(
        now: Date = Date()
    ) async -> TranslationRuntimeSnapshot {
        guard context != nil else {
            return TranslationRuntimeSnapshot(state: state)
        }
        state = .stopping
        guard var pipeline else {
            state = .stopped
            return TranslationRuntimeSnapshot(state: state)
        }

        let pipelineSnapshot = await pipeline.flushAndFinalize(now: now)
        self.pipeline = pipeline
        state = .stopped
        let visibleFinals = pipelineSnapshot.visibleResults.filter { $0.displayState == .stableFinal }
        let snapshot = TranslationRuntimeSnapshot(
            state: state,
            liveResults: [],
            stableResults: pipelineSnapshot.stableResults,
            visibleResults: visibleFinals
        )
        logSnapshot(
            path: "stop",
            liveCount: 0,
            stableCount: snapshot.stableResults.count,
            visibleCount: snapshot.visibleResults.count,
            droppedCount: 0
        )
        logVisibleResults(snapshot.visibleResults, path: "stop")
        return snapshot
    }

    public mutating func hydrate(records: [TranslationResultPersistenceRecord]) -> [TranslationResult] {
        hydratedStore.hydrate(from: records)
        return hydratedStore.stableResults()
    }

    private func syntheticDroppedPreviewResults(
        from document: TranscriptDocument,
        now: Date
    ) -> [TranslationResult] {
        document.segments
            .filter { !$0.isFinal }
            .map { segment in
                let sourceLocale: String
                if let language = segment.language {
                    sourceLocale = language
                } else if let context {
                    sourceLocale = context.sourceLocale
                } else {
                    sourceLocale = ""
                }
                let targetLocale: String
                if let context {
                    targetLocale = context.targetLocale
                } else {
                    targetLocale = ""
                }
                let lane = TranslationLaneID(
                    speaker: segment.speaker,
                    sourceLocale: sourceLocale,
                    targetLocale: targetLocale
                )
                return TranslationResult(
                    id: "\(segment.id)-dropped-after-stop",
                    sourceID: segment.id,
                    laneID: lane,
                    sourceText: segment.text,
                    translatedText: "",
                    displayState: .failedRecoverable,
                    createdAt: now,
                    sourceCreatedAt: segment.createdAt,
                    sourceSegmentIDs: [segment.id]
                )
            }
    }

    private func logDroppedAfterStop(_ result: TranslationResult) {
        performanceEventLogger?.log(
            "translation_unit_live_dropped_after_stop",
            segmentID: result.sourceID,
            isFinal: false,
            textLength: result.sourceText.count,
            metadata: [
                "translationKind": "live",
                "translationState": result.displayState.rawValue,
                "resultID": result.id,
                "sourceSegmentIDs": result.sourceSegmentIDs.joined(separator: ",")
            ]
        )
    }

    private func logSnapshot(
        path: String,
        liveCount: Int,
        stableCount: Int,
        visibleCount: Int,
        droppedCount: Int
    ) {
        performanceEventLogger?.log(
            "translation_runtime_snapshot",
            metadata: [
                "path": path,
                "state": String(describing: state),
                "liveResultCount": String(liveCount),
                "stableResultCount": String(stableCount),
                "visibleResultCount": String(visibleCount),
                "droppedResultCount": String(droppedCount)
            ]
        )
    }

    private func logVisibleResults(
        _ results: [TranslationResult],
        path: String
    ) {
        for result in results where result.displayState == .liveFresh {
            performanceEventLogger?.log(
                "translation_live_result_visible",
                segmentID: result.sourceID,
                isFinal: false,
                textLength: result.translatedText.count,
                metadata: resultMetadata(result, path: path)
            )
        }
        for result in results where result.displayState == .stableFinal {
            performanceEventLogger?.log(
                "translation_stable_result_visible",
                segmentID: result.sourceID,
                isFinal: true,
                textLength: result.translatedText.count,
                metadata: resultMetadata(result, path: path)
            )
        }
    }

    private func resultMetadata(
        _ result: TranslationResult,
        path: String
    ) -> [String: String] {
        [
            "path": path,
            "translationState": result.displayState.rawValue,
            "translationRequestID": result.id,
            "sourceSegmentIDs": result.sourceSegmentIDs.joined(separator: ","),
            "sourceCreatedAt": ISO8601DateFormatter().string(from: result.sourceCreatedAt)
        ]
    }
}
