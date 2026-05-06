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
    private var requestTimes: [Date] = []
    private var lastRequestedPrefixByLane: [TranslationLaneID: String] = [:]
    private var cachedResultByLaneAndPrefix: [CacheKey: TranslationResult] = [:]
    private var now: () -> Date

    public init(
        provider: TextTranslationProvider,
        configuration: LiveTranslationSchedulerConfiguration = LiveTranslationSchedulerConfiguration(),
        now: @escaping () -> Date = Date.init
    ) {
        self.provider = provider
        self.configuration = configuration
        self.now = now
    }

    public mutating func schedule(_ units: [LiveTranslationUnit]) async -> [TranslationResult] {
        var results: [TranslationResult] = []

        for unit in units {
            let cacheKey = CacheKey(laneID: unit.laneID, sourceText: unit.stablePrefixText)
            if let cachedResult = cachedResultByLaneAndPrefix[cacheKey] {
                results.append(cachedResult.rebased(to: unit, createdAt: now()))
                continue
            }

            pruneRequestTimes()
            guard requestTimes.count < configuration.maxCallsPerMinute else {
                results.append(disabledBudgetResult(for: unit))
                continue
            }

            guard lastRequestedPrefixByLane[unit.laneID] != unit.stablePrefixText else {
                continue
            }

            requestTimes.append(now())
            lastRequestedPrefixByLane[unit.laneID] = unit.stablePrefixText
            let result = await translate(unit)
            cachedResultByLaneAndPrefix[cacheKey] = result
            results.append(result)
        }

        return results
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
            riskFlags: unit.riskFlags
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
                riskFlags: unit.riskFlags
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
                riskFlags: unit.riskFlags
            )
        }
    }
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
            riskFlags: unit.riskFlags
        )
    }
}
