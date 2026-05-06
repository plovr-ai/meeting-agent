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

public struct TranslationRuntime {
    private var context: TranslationRuntimeContext?
    private var state: TranslationRuntimeState = .idle
    private var hydratedStore = TranslationResultStore()

    public init() {}

    public mutating func start(context: TranslationRuntimeContext) {
        self.context = context
        state = .active
    }

    public mutating func apply(
        document: TranscriptDocument,
        generation: Int,
        now: Date = Date()
    ) async -> TranslationRuntimeSnapshot {
        guard context != nil else {
            return TranslationRuntimeSnapshot(state: .idle)
        }
        return TranslationRuntimeSnapshot(state: state)
    }

    public mutating func hydrate(records: [TranslationResultPersistenceRecord]) -> [TranslationResult] {
        hydratedStore.hydrate(from: records)
        return hydratedStore.stableResults()
    }
}
