import Foundation

public struct TranslationResultStore: Equatable {
    private var resultsByLane: [TranslationLaneID: [TranslationResult]] = [:]

    public init() {}

    public mutating func attach(_ result: TranslationResult) {
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
    }

    public func visibleResult(for laneID: TranslationLaneID) -> TranslationResult? {
        resultsByLane[laneID]?.max {
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
}
