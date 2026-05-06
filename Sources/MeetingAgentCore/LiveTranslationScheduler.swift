import Foundation

public struct LiveTranslationSchedulerConfiguration: Equatable {
    public var maxConcurrentRequests: Int
    public var maxCallsPerMinute: Int
    public var draftTimeoutNanoseconds: UInt64

    public init(
        maxConcurrentRequests: Int = 2,
        maxCallsPerMinute: Int = 12,
        draftTimeoutNanoseconds: UInt64 = 4_000_000_000
    ) {
        self.maxConcurrentRequests = max(1, maxConcurrentRequests)
        self.maxCallsPerMinute = max(1, maxCallsPerMinute)
        self.draftTimeoutNanoseconds = draftTimeoutNanoseconds
    }
}

public struct LiveTranslationScheduler {
    private let provider: TextTranslationProvider
    private let configuration: LiveTranslationSchedulerConfiguration
    private let performanceEventLogger: PerformanceEventLogger?
    private var requestTimes: [Date] = []
    private var laneStates: [TranslationLaneID: LiveTranslationLaneState] = [:]
    private var cachedResultByLaneAndPrefix: [CacheKey: TranslationResult] = [:]
    private var now: () -> Date

    public init(
        provider: TextTranslationProvider,
        configuration: LiveTranslationSchedulerConfiguration = LiveTranslationSchedulerConfiguration(),
        performanceEventLogger: PerformanceEventLogger? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.provider = provider
        self.configuration = configuration
        self.performanceEventLogger = performanceEventLogger
        self.now = now
    }

    public mutating func schedule(_ units: [LiveTranslationUnit]) async -> [TranslationResult] {
        var results: [TranslationResult] = []
        var immediateUnits: [LiveTranslationUnit] = []
        var lanesScheduledInThisBatch = Set<TranslationLaneID>()

        for unit in units {
            var state = laneStates[unit.laneID, default: LiveTranslationLaneState()]
            if state.inFlightUnitID != nil || lanesScheduledInThisBatch.contains(unit.laneID) {
                if let staleUnit = state.pendingLatestUnit {
                    logUnitEvent(
                        "translation_unit_live_stale",
                        unit: staleUnit,
                        metadata: ["reason": "pending_replaced", "replacementUnitID": unit.id]
                    )
                }
                state.pendingLatestUnit = unit
                laneStates[unit.laneID] = state
                continue
            }
            laneStates[unit.laneID] = state
            lanesScheduledInThisBatch.insert(unit.laneID)
            immediateUnits.append(unit)
        }

        for unit in immediateUnits {
            if let result = await scheduleImmediately(unit) {
                results.append(result)
            }
        }

        return results
    }

    public mutating func drainPending() async -> [TranslationResult] {
        var results: [TranslationResult] = []
        let lanes = Array(laneStates.keys)
        for lane in lanes {
            guard var state = laneStates[lane],
                  state.inFlightUnitID == nil,
                  let pending = state.pendingLatestUnit
            else { continue }
            state.pendingLatestUnit = nil
            laneStates[lane] = state
            if let result = await scheduleImmediately(pending) {
                results.append(result)
            }
        }
        return results
    }

    private mutating func scheduleImmediately(_ unit: LiveTranslationUnit) async -> TranslationResult? {
        let cacheKey = CacheKey(laneID: unit.laneID, sourceText: unit.stablePrefixText)
        if let cachedResult = cachedResultByLaneAndPrefix[cacheKey] {
            return cachedResult.rebased(to: unit, createdAt: now())
        }

        pruneRequestTimes()
        guard requestTimes.count < configuration.maxCallsPerMinute else {
            logUnitEvent("translation_unit_live_stale", unit: unit, metadata: ["reason": "budget_disabled"])
            return disabledBudgetResult(for: unit)
        }

        var state: LiveTranslationLaneState
        if let existingState = laneStates[unit.laneID] {
            state = existingState
        } else {
            state = LiveTranslationLaneState()
        }
        guard state.lastRequestedSourcePrefix != unit.stablePrefixText else {
            logUnitEvent("translation_unit_live_stale", unit: unit, metadata: ["reason": "duplicate_prefix"])
            return nil
        }

        requestTimes.append(now())
        state.lastRequestedSourcePrefix = unit.stablePrefixText
        state.inFlightUnitID = unit.id
        laneStates[unit.laneID] = state
        logUnitEvent("translation_unit_live_scheduled", unit: unit)

        let result = await translate(unit)

        var completionState: LiveTranslationLaneState
        if let existingState = laneStates[unit.laneID] {
            completionState = existingState
        } else {
            completionState = LiveTranslationLaneState()
        }
        if completionState.inFlightUnitID == unit.id {
            completionState.inFlightUnitID = nil
        }
        if result.displayState == .liveFresh {
            completionState.lastVisibleSourcePrefix = unit.stablePrefixText
            cachedResultByLaneAndPrefix[cacheKey] = result
        }
        laneStates[unit.laneID] = completionState
        return result
    }

    private mutating func pruneRequestTimes() {
        let cutoff = now().addingTimeInterval(-60)
        requestTimes.removeAll { $0 < cutoff }
    }

    private func disabledBudgetResult(for unit: LiveTranslationUnit) -> TranslationResult {
        TranslationResult(
            id: "\(unit.id)-budget",
            sourceID: unit.id,
            laneID: unit.laneID,
            sourceText: unit.stablePrefixText,
            translatedText: "",
            displayState: .disabledBudget,
            createdAt: now(),
            sourceCreatedAt: unit.createdAt,
            riskFlags: unit.riskFlags,
            sourceSegmentIDs: unit.sourceSegmentIDs
        )
    }

    private func logUnitEvent(
        _ event: String,
        unit: LiveTranslationUnit,
        metadata: [String: String] = [:]
    ) {
        var eventMetadata = metadata
        eventMetadata["translationKind"] = "live"
        eventMetadata["laneID"] = "\(unit.laneID.speakerID)|\(unit.laneID.sourceLocale)|\(unit.laneID.targetLocale)"
        eventMetadata["revision"] = String(unit.revision)
        eventMetadata["sourceSegmentIDs"] = unit.sourceSegmentIDs.joined(separator: ",")
        performanceEventLogger?.log(
            event,
            segmentID: unit.id,
            isFinal: false,
            textLength: unit.stablePrefixText.count,
            metadata: eventMetadata
        )
    }

    private func translate(_ unit: LiveTranslationUnit) async -> TranslationResult {
        do {
            let transcript = TranscriptDocument(segments: [
                TranscriptSegment(
                    id: unit.id,
                    text: unit.stablePrefixText,
                    language: unit.laneID.sourceLocale,
                    isFinal: false,
                    createdAt: unit.createdAt
                )
            ])
            let translated = try await provider.translate(
                transcript: transcript,
                options: TranslationOptions(sourceLocale: unit.laneID.sourceLocale, targetLocale: unit.laneID.targetLocale)
            )
            return TranslationResult(
                id: "\(unit.id)-live-result",
                sourceID: unit.id,
                laneID: unit.laneID,
                sourceText: unit.stablePrefixText,
                translatedText: translated.segments.first?.targetText ?? "",
                displayState: .liveFresh,
                createdAt: now(),
                sourceCreatedAt: unit.createdAt,
                riskFlags: unit.riskFlags,
                sourceSegmentIDs: unit.sourceSegmentIDs
            )
        } catch {
            return TranslationResult(
                id: "\(unit.id)-failed",
                sourceID: unit.id,
                laneID: unit.laneID,
                sourceText: unit.stablePrefixText,
                translatedText: "",
                displayState: .failedRecoverable,
                createdAt: now(),
                sourceCreatedAt: unit.createdAt,
                riskFlags: unit.riskFlags,
                sourceSegmentIDs: unit.sourceSegmentIDs
            )
        }
    }
}

private struct LiveTranslationLaneState {
    var inFlightUnitID: String?
    var pendingLatestUnit: LiveTranslationUnit?
    var lastVisibleSourcePrefix: String = ""
    var lastRequestedSourcePrefix: String = ""
}

private struct CacheKey: Hashable {
    var laneID: TranslationLaneID
    var sourceText: String
}

private extension TranslationResult {
    func rebased(to unit: LiveTranslationUnit, createdAt: Date) -> TranslationResult {
        TranslationResult(
            id: "\(unit.id)-live-result",
            sourceID: unit.id,
            laneID: unit.laneID,
            sourceText: unit.stablePrefixText,
            translatedText: translatedText,
            displayState: displayState,
            createdAt: createdAt,
            sourceCreatedAt: unit.createdAt,
            riskFlags: unit.riskFlags,
            sourceSegmentIDs: unit.sourceSegmentIDs
        )
    }
}
