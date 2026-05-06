import Foundation

public struct TranslationResultStore: Equatable {
    private var resultsByLane: [TranslationLaneID: [TranslationResult]] = [:]
    private var resultsByID: [String: TranslationResult] = [:]
    private var resultIDsBySourceSegmentID: [String: Set<String>] = [:]

    public init() {}

    public mutating func attach(_ result: TranslationResult) {
        removeIndexes(forResultID: result.id)
        var laneResults = resultsByLane[result.laneID, default: []]
        laneResults.removeAll { $0.id == result.id }
        laneResults.append(result)
        laneResults.sort {
            if $0.displayState.priority == $1.displayState.priority {
                return $0.createdAt < $1.createdAt
            }
            return $0.displayState.priority < $1.displayState.priority
        }
        resultsByLane[result.laneID] = laneResults
        resultsByID[result.id] = result
        for sourceSegmentID in result.sourceSegmentIDs {
            resultIDsBySourceSegmentID[sourceSegmentID, default: []].insert(result.id)
        }
    }

    public mutating func hydrate(from records: [TranslationResultPersistenceRecord]) {
        for record in records {
            attach(TranslationResult(
                id: record.resultID,
                sourceID: record.sourceID,
                laneID: record.laneID,
                sourceText: record.sourceText,
                translatedText: record.translatedText,
                displayState: record.displayState,
                createdAt: record.finalizedAt ?? record.createdAt,
                sourceCreatedAt: record.createdAt,
                sourceSegmentIDs: record.sourceSegmentIDs
            ))
        }
    }

    public func visibleResult(for laneID: TranslationLaneID) -> TranslationResult? {
        resultsByLane[laneID]?.max {
            if $0.displayState.priority == $1.displayState.priority {
                return $0.createdAt < $1.createdAt
            }
            return $0.displayState.priority < $1.displayState.priority
        }
    }

    public func stableResults() -> [TranslationResult] {
        resultsByID.values
            .filter { $0.displayState == .stableFinal }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func resultsForSourceSegmentIDs(_ ids: [String]) -> [TranslationResult] {
        let resultIDs = ids.reduce(into: Set<String>()) { partialResult, sourceSegmentID in
            partialResult.formUnion(resultIDsBySourceSegmentID[sourceSegmentID, default: []])
        }
        return resultIDs
            .compactMap { resultsByID[$0] }
            .sorted {
                if $0.displayState.priority == $1.displayState.priority {
                    return $0.createdAt < $1.createdAt
                }
                return $0.displayState.priority < $1.displayState.priority
            }
    }

    public func carriedForwardResult(
        for laneID: TranslationLaneID,
        currentRiskFlags: Set<TranslationRiskFlag>
    ) -> TranslationResult? {
        guard currentRiskFlags.isDisjoint(with: Self.nonCarryForwardRiskFlags) else {
            return nil
        }
        guard var result = visibleResult(for: laneID),
              result.displayState == .liveFresh || result.displayState == .liveLagging
        else {
            return nil
        }
        result.displayState = .liveCarried
        return result
    }

    static let nonCarryForwardRiskFlags: Set<TranslationRiskFlag> = [
        .number,
        .dateOrTime,
        .negation,
        .commitment,
        .namedEntity,
        .speakerChanged,
        .localeChanged
    ]

    private mutating func removeIndexes(forResultID resultID: String) {
        guard let oldResult = resultsByID[resultID] else { return }
        for sourceSegmentID in oldResult.sourceSegmentIDs {
            resultIDsBySourceSegmentID[sourceSegmentID]?.remove(resultID)
            if resultIDsBySourceSegmentID[sourceSegmentID]?.isEmpty == true {
                resultIDsBySourceSegmentID[sourceSegmentID] = nil
            }
        }
        resultsByID[resultID] = nil
    }
}
