import Foundation

public struct LiveCaptionPipelineSnapshot: Equatable {
    public var turns: [LiveCaptionTurn]
    public var captionHealth: LivePipelineHealth
    public var translationHealth: LivePipelineHealth

    public init(
        turns: [LiveCaptionTurn],
        captionHealth: LivePipelineHealth,
        translationHealth: LivePipelineHealth
    ) {
        self.turns = turns
        self.captionHealth = captionHealth
        self.translationHealth = translationHealth
    }
}

@MainActor
public final class LiveCaptionPipeline {
    private var sourceLocale: String
    private var targetLocale: String
    private let performanceEventLogger: PerformanceEventLogger?
    private var store: LiveCaptionStore
    private var turnAssembler: CaptionTurnAssembler
    private var interimSegmentsByID: [String: TranscriptSegment] = [:]
    private var ingestedSegmentSignaturesByID: [String: String] = [:]

    private enum CaptionVisibilityPath: String {
        case realtime
        case replay
    }

    public init(
        sourceLocale: String,
        targetLocale: String,
        performanceEventLogger: PerformanceEventLogger?
    ) {
        self.sourceLocale = sourceLocale
        self.targetLocale = targetLocale
        self.performanceEventLogger = performanceEventLogger
        store = LiveCaptionStore(sourceLocale: sourceLocale, targetLocale: targetLocale)
        turnAssembler = CaptionTurnAssembler(sourceLocale: sourceLocale, targetLocale: targetLocale)
        interimSegmentsByID = [:]
    }

    public func apply(_ result: TranscriptSegmentAccumulationResult) async -> LiveCaptionPipelineSnapshot {
        if result.plainTextReplacement != nil {
            reset(sourceLocale: sourceLocale, targetLocale: targetLocale)
            return snapshot(
                captionHealth: .failed("Plain text transcript replacements are not supported by live captions."),
                translationHealth: .idle
            )
        }

        let currentSegmentIDs = Set(result.document.segments.map(\.id))
        applyEvents(
            turnAssembler.removeSegments(notIn: currentSegmentIDs),
            currentSegments: result.document.segments
        )

        let changedSegmentIDs = Set(result.changedSegmentIDs)
        for segment in result.document.segments where changedSegmentIDs.contains(segment.id) {
            let receivedAt = Date()
            logSegmentIngestedIfNeeded(segment, path: segment.isFinal ? "final" : "interim")
            applyEvents(
                turnAssembler.apply(segment),
                sourceSegment: segment,
                segmentReceivedAt: receivedAt,
                visibilityPath: .realtime
            )
        }
        return snapshot(
            captionHealth: store.turns.isEmpty ? .idle : .live,
            translationHealth: .idle
        )
    }

    public func replay(_ document: TranscriptDocument) async -> LiveCaptionPipelineSnapshot {
        replayCaptions(document)
        return snapshot(
            captionHealth: store.turns.isEmpty ? .idle : .live,
            translationHealth: .idle
        )
    }

    public func replayCaptionsOnly(_ document: TranscriptDocument) -> LiveCaptionPipelineSnapshot {
        replayCaptions(document)
        return snapshot(
            captionHealth: store.turns.isEmpty ? .idle : .live,
            translationHealth: .idle
        )
    }

    public func flush(reason: LiveCaptionFreezeReason) async -> LiveCaptionPipelineSnapshot {
        flushCaptionsOnly(reason: reason)
    }

    public func flushCaptionsOnly(reason: LiveCaptionFreezeReason) -> LiveCaptionPipelineSnapshot {
        applyEvents(turnAssembler.flush(reason: reason))
        return snapshot(
            captionHealth: store.turns.isEmpty ? .idle : .live,
            translationHealth: .idle
        )
    }

    public func reset(sourceLocale: String, targetLocale: String) {
        self.sourceLocale = sourceLocale
        self.targetLocale = targetLocale
        resetCaptionProjection(sourceLocale: sourceLocale, targetLocale: targetLocale)
    }

    private func resetCaptionProjection(sourceLocale: String, targetLocale: String) {
        store = LiveCaptionStore(sourceLocale: sourceLocale, targetLocale: targetLocale)
        turnAssembler = CaptionTurnAssembler(sourceLocale: sourceLocale, targetLocale: targetLocale)
        interimSegmentsByID = [:]
    }

    private func applyEvents(
        _ events: [CaptionTurnEvent],
        sourceSegment: TranscriptSegment? = nil,
        segmentReceivedAt: Date? = nil,
        currentSegments: [TranscriptSegment] = [],
        visibilityPath: CaptionVisibilityPath = .realtime
    ) {
        for event in events {
            switch event {
            case .draftUpdated(let turn):
                if let sourceSegment,
                   let previousSegment = interimSegmentsByID[sourceSegment.id] {
                    let updated = store.replaceRepresentedSegment(
                        previousSegment,
                        with: sourceSegment,
                        applying: turn
                    )
                    logCaptionTurnVisible(updated, sourceSegment: sourceSegment, receivedAt: segmentReceivedAt, visibilityPath: visibilityPath)
                    interimSegmentsByID[sourceSegment.id] = sourceSegment
                    continue
                }
                let updated = store.upsert(turn)
                if let sourceSegment {
                    logCaptionTurnVisible(updated, sourceSegment: sourceSegment, receivedAt: segmentReceivedAt, visibilityPath: visibilityPath)
                }
            case .sealed(let turn):
                if let sourceSegment,
                   let previousSegment = interimSegmentsByID[sourceSegment.id] {
                    let updated = store.replaceRepresentedSegment(
                        previousSegment,
                        with: sourceSegment,
                        applying: turn
                    )
                    logCaptionTurnVisible(updated, sourceSegment: sourceSegment, receivedAt: segmentReceivedAt, visibilityPath: visibilityPath)
                    if sourceSegment.isFinal {
                        interimSegmentsByID[sourceSegment.id] = nil
                    }
                    continue
                }
                let updated = store.upsert(turn)
                if let sourceSegment {
                    logCaptionTurnVisible(updated, sourceSegment: sourceSegment, receivedAt: segmentReceivedAt, visibilityPath: visibilityPath)
                    if sourceSegment.isFinal {
                        interimSegmentsByID[sourceSegment.id] = nil
                    }
                }
            case .interimUpdated(let segment):
                let turn = store.append(segment)
                logCaptionTurnVisible(turn, sourceSegment: segment, receivedAt: segmentReceivedAt, visibilityPath: visibilityPath)
                interimSegmentsByID[segment.id] = segment
            case .removed(let turnID):
                let updatedTurn = store.removeSourceSegment(turnID, remainingSegments: currentSegments)
                interimSegmentsByID[turnID] = nil
                if let updatedTurn,
                   updatedTurn.sourceSegmentIDs.count == 1,
                   let sourceSegmentID = updatedTurn.sourceSegmentIDs.first,
                   let remainingSegment = currentSegments.first(where: { $0.id == sourceSegmentID }) {
                    _ = remainingSegment
                }
            }
        }
    }

    private func logCaptionTurnVisible(
        _ turn: LiveCaptionTurn,
        sourceSegment: TranscriptSegment,
        receivedAt: Date?,
        visibilityPath: CaptionVisibilityPath
    ) {
        var metadata = captionMetadata(for: turn, sourceSegment: sourceSegment)
        metadata["path"] = visibilityPath.rawValue
        if let receivedAt {
            metadata.merge(PerformanceEventLogger.durationMetadata(from: receivedAt)) { _, new in new }
        }
        performanceEventLogger?.log(
            "caption_turn_visible",
            audioTimeSeconds: sourceSegment.endTimeSeconds,
            segmentID: sourceSegment.id,
            isFinal: sourceSegment.isFinal,
            textLength: sourceSegment.text.count,
            metadata: metadata
        )
    }

    private func captionMetadata(for turn: LiveCaptionTurn, sourceSegment: TranscriptSegment) -> [String: String] {
        var metadata: [String: String] = [
            "turnID": turn.id,
            "sourceSegmentID": sourceSegment.id,
            "sourceSegmentIDs": turn.sourceSegmentIDs.joined(separator: ","),
            "sourceLocale": turn.sourceLocale,
            "targetLocale": turn.targetLocale,
            "captionState": String(describing: turn.displayState)
        ]
        let providerID = sourceSegment.sourceProvider.trimmingCharacters(in: .whitespacesAndNewlines)
        if !providerID.isEmpty {
            metadata["providerID"] = providerID
        }
        if let boundaryStrength = turn.boundaryStrength {
            metadata["boundaryStrength"] = String(describing: boundaryStrength)
        }
        if let boundaryReason = turn.boundaryReason {
            metadata["boundaryReason"] = boundaryReason.rawValue
        }
        if let speakerID = turn.speaker.identifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !speakerID.isEmpty {
            metadata["speakerID"] = speakerID
        }
        if let speakerLabel = turn.speaker.label?.trimmingCharacters(in: .whitespacesAndNewlines),
           !speakerLabel.isEmpty {
            metadata["speakerLabel"] = speakerLabel
        }
        return metadata
    }

    private func replayCaptions(_ document: TranscriptDocument) {
        resetCaptionProjection(sourceLocale: sourceLocale, targetLocale: targetLocale)
        for segment in document.segments where segment.isFinal {
            logSegmentIngestedIfNeeded(segment, path: "final")
            applyEvents(turnAssembler.apply(segment), sourceSegment: segment, visibilityPath: .replay)
        }
        for segment in document.segments where !segment.isFinal {
            logSegmentIngestedIfNeeded(segment, path: "interim")
            applyEvents(turnAssembler.apply(segment), sourceSegment: segment, visibilityPath: .replay)
        }
    }

    private func logSegmentIngestedIfNeeded(_ segment: TranscriptSegment, path: String) {
        let signature = [
            segment.text,
            segment.isFinal ? "final" : "interim",
            segment.speechFinal ? "speechFinal" : "open",
            segment.speakerID ?? "",
            segment.speakerLabel ?? ""
        ].joined(separator: "\u{1F}")
        guard ingestedSegmentSignaturesByID[segment.id] != signature else { return }
        ingestedSegmentSignaturesByID[segment.id] = signature
        performanceEventLogger?.logSegment(
            "caption_segment_ingested",
            segment: segment,
            metadata: ["path": path]
        )
    }

    private func snapshot(
        captionHealth: LivePipelineHealth,
        translationHealth: LivePipelineHealth
    ) -> LiveCaptionPipelineSnapshot {
        return LiveCaptionPipelineSnapshot(
            turns: store.turns,
            captionHealth: captionHealth,
            translationHealth: translationHealth
        )
    }
}
