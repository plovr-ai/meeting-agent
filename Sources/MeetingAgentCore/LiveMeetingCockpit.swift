import Foundation

public enum LivePipelineHealth: Codable, Equatable {
    case idle
    case pending
    case live
    case degraded(String)
    case failed(String)

    private enum CodingKeys: String, CodingKey {
        case state
        case message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let state = try container.decode(String.self, forKey: .state)
        let message = try container.decodeIfPresent(String.self, forKey: .message)
        switch state {
        case "idle":
            self = .idle
        case "pending":
            self = .pending
        case "live":
            self = .live
        case "degraded":
            self = .degraded(message ?? "")
        case "failed":
            self = .failed(message ?? "")
        default:
            self = .failed("Unknown health state: \(state)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .idle:
            try container.encode("idle", forKey: .state)
        case .pending:
            try container.encode("pending", forKey: .state)
        case .live:
            try container.encode("live", forKey: .state)
        case .degraded(let message):
            try container.encode("degraded", forKey: .state)
            try container.encode(message, forKey: .message)
        case .failed(let message):
            try container.encode("failed", forKey: .state)
            try container.encode(message, forKey: .message)
        }
    }
}

public enum LiveCaptionChunkState: String, Codable, Equatable {
    case draft
    case frozen
}

public enum LiveCaptionFreezeReason: String, Codable, Equatable {
    case speechFinal
    case speakerChanged
    case maxLength
    case maxDuration
    case punctuation
    case manualStop
}

public struct MeetingKeyTerm: Codable, Equatable, Identifiable {
    public var id: String
    public var value: String
    public var translationHint: String?

    public init(id: String? = nil, value: String, translationHint: String? = nil) {
        self.value = value
        self.id = id ?? value
        self.translationHint = translationHint
    }
}

public struct MeetingObjective: Codable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var keywords: [String]

    public init(id: String, title: String, keywords: [String] = []) {
        self.id = id
        self.title = title
        self.keywords = keywords
    }
}

public struct MeetingGoal: Codable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var objectives: [MeetingObjective]
    public var requiredQuestions: [String]
    public var expectedDecisions: [String]
    public var keyTerms: [MeetingKeyTerm]

    public init(
        id: UUID = UUID(),
        title: String,
        objectives: [MeetingObjective],
        requiredQuestions: [String],
        expectedDecisions: [String],
        keyTerms: [MeetingKeyTerm]
    ) {
        self.id = id
        self.title = title
        self.objectives = objectives
        self.requiredQuestions = requiredQuestions
        self.expectedDecisions = expectedDecisions
        self.keyTerms = keyTerms
    }
}

public struct LiveCaptionTurn: Codable, Equatable, Identifiable {
    public var id: String
    public var sourceSegmentID: String
    public var sourceSegmentIDs: [String]
    public var speaker: TranscriptSpeaker
    public var originalText: String
    public var translatedText: String?
    public var sourceLocale: String
    public var targetLocale: String
    public var isFinal: Bool
    public var captionHealth: LivePipelineHealth
    public var translationHealth: LivePipelineHealth
    public var createdAt: Date
    public var chunkState: LiveCaptionChunkState
    public var translationRevision: Int
    public var freezeReason: LiveCaptionFreezeReason?

    public init(
        id: String? = nil,
        sourceSegmentID: String,
        sourceSegmentIDs: [String]? = nil,
        speaker: TranscriptSpeaker = .default,
        originalText: String,
        translatedText: String? = nil,
        sourceLocale: String = "en-US",
        targetLocale: String = "zh-CN",
        isFinal: Bool,
        captionHealth: LivePipelineHealth = .live,
        translationHealth: LivePipelineHealth = .pending,
        createdAt: Date = Date(),
        chunkState: LiveCaptionChunkState = .frozen,
        translationRevision: Int = 0,
        freezeReason: LiveCaptionFreezeReason? = nil
    ) {
        self.id = id ?? sourceSegmentID
        self.sourceSegmentID = sourceSegmentID
        self.sourceSegmentIDs = sourceSegmentIDs ?? [sourceSegmentID]
        self.speaker = speaker
        self.originalText = originalText
        self.translatedText = translatedText
        self.sourceLocale = sourceLocale
        self.targetLocale = targetLocale
        self.isFinal = isFinal
        self.captionHealth = captionHealth
        self.translationHealth = translationHealth
        self.createdAt = createdAt
        self.chunkState = chunkState
        self.translationRevision = translationRevision
        self.freezeReason = freezeReason
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sourceSegmentID
        case sourceSegmentIDs
        case speaker
        case originalText
        case translatedText
        case sourceLocale
        case targetLocale
        case isFinal
        case captionHealth
        case translationHealth
        case createdAt
        case chunkState
        case translationRevision
        case freezeReason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sourceSegmentID = try container.decode(String.self, forKey: .sourceSegmentID)
        sourceSegmentIDs = try container.decodeIfPresent([String].self, forKey: .sourceSegmentIDs) ?? [sourceSegmentID]
        speaker = try container.decode(TranscriptSpeaker.self, forKey: .speaker)
        originalText = try container.decode(String.self, forKey: .originalText)
        translatedText = try container.decodeIfPresent(String.self, forKey: .translatedText)
        sourceLocale = try container.decode(String.self, forKey: .sourceLocale)
        targetLocale = try container.decode(String.self, forKey: .targetLocale)
        isFinal = try container.decode(Bool.self, forKey: .isFinal)
        captionHealth = try container.decode(LivePipelineHealth.self, forKey: .captionHealth)
        translationHealth = try container.decode(LivePipelineHealth.self, forKey: .translationHealth)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        chunkState = try container.decodeIfPresent(LiveCaptionChunkState.self, forKey: .chunkState) ?? .frozen
        translationRevision = try container.decodeIfPresent(Int.self, forKey: .translationRevision) ?? 0
        freezeReason = try container.decodeIfPresent(LiveCaptionFreezeReason.self, forKey: .freezeReason)
    }
}

public enum LiveCaptionDisplayState: Equatable {
    case originalOnly(String)
    case translated(primaryText: String, sourceText: String)
    case pending(sourceText: String)
    case failed(sourceText: String, message: String)

    public init(turn: LiveCaptionTurn, secondLanguageEnabled: Bool) {
        let originalText = turn.originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let translatedText = turn.translatedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard secondLanguageEnabled else {
            self = .originalOnly(originalText)
            return
        }
        if !translatedText.isEmpty {
            self = .translated(primaryText: translatedText, sourceText: originalText)
            return
        }
        switch turn.translationHealth {
        case .failed(let message), .degraded(let message):
            self = .failed(sourceText: originalText, message: message)
        case .pending:
            self = .pending(sourceText: originalText)
        case .idle, .live:
            self = .originalOnly(originalText)
        }
    }

    public static func isSecondLanguageEnabled(
        sourceLocale: String,
        targetLocale: String,
        hasTranslatedText: Bool
    ) -> Bool {
        if hasTranslatedText {
            return true
        }
        let source = sourceLocale.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let target = targetLocale.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !source.isEmpty && !target.isEmpty && source != target
    }
}

public struct LiveCaptionStore: Equatable {
    public private(set) var turns: [LiveCaptionTurn] = []
    public private(set) var sourceLocale: String
    public private(set) var targetLocale: String

    public init(sourceLocale: String = "en-US", targetLocale: String = "zh-CN") {
        self.sourceLocale = sourceLocale
        self.targetLocale = targetLocale
    }

    @discardableResult
    public mutating func append(_ segment: TranscriptSegment) -> LiveCaptionTurn {
        let turn = LiveCaptionTurn(
            sourceSegmentID: segment.id,
            speaker: segment.speaker,
            originalText: segment.text,
            sourceLocale: segment.language ?? sourceLocale,
            targetLocale: targetLocale,
            isFinal: segment.isFinal,
            captionHealth: .live,
            translationHealth: .pending,
            createdAt: segment.createdAt,
            chunkState: segment.isFinal ? .frozen : .draft,
            translationRevision: 1
        )
        if let representedIndex = turns.firstIndex(where: { $0.sourceSegmentIDs.contains(segment.id) }),
           turns[representedIndex].sourceSegmentIDs.count > 1 {
            return turns[representedIndex]
        }
        if let index = turns.firstIndex(where: { $0.sourceSegmentID == segment.id }) {
            let previousTurn = turns[index]
            var updated = turn
            if previousTurn.originalText == turn.originalText {
                updated.translatedText = previousTurn.translatedText
                updated.translationHealth = previousTurn.translationHealth
                updated.translationRevision = previousTurn.translationRevision
            } else {
                updated.translationRevision = previousTurn.translationRevision + 1
            }
            turns[index] = updated
            return updated
        }
        if let index = mergeTargetIndex(for: turn) {
            turns[index] = mergedTurn(turns[index], appending: turn)
            return turns[index]
        }
        turns.append(turn)
        return turn
    }

    @discardableResult
    public mutating func upsert(_ turn: LiveCaptionTurn) -> LiveCaptionTurn {
        if let index = turns.firstIndex(where: { $0.id == turn.id }) {
            let previous = turns[index]
            var updated = turn
            if !((previous.translatedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
               updated.translatedText == nil {
                updated.translatedText = previous.translatedText
            }
            turns[index] = updated
            return updated
        }
        turns.append(turn)
        return turn
    }

    public mutating func removeNonFinalTurnsNotIn(segmentIDs: Set<String>) {
        turns.removeAll { !$0.isFinal && !segmentIDs.contains($0.sourceSegmentID) }
    }

    private func mergeTargetIndex(for turn: LiveCaptionTurn) -> Int? {
        guard turn.isFinal,
              let lastIndex = turns.indices.last,
              turns[lastIndex].isFinal,
              turns[lastIndex].speaker == turn.speaker
        else {
            return nil
        }
        return lastIndex
    }

    private func mergedTurn(_ existing: LiveCaptionTurn, appending turn: LiveCaptionTurn) -> LiveCaptionTurn {
        var merged = existing
        merged.sourceSegmentID = turn.sourceSegmentID
        merged.sourceSegmentIDs.append(contentsOf: turn.sourceSegmentIDs)
        merged.originalText = joinedTranscriptText(existing.originalText, turn.originalText)
        merged.sourceLocale = turn.sourceLocale
        merged.targetLocale = turn.targetLocale
        merged.isFinal = turn.isFinal
        merged.captionHealth = turn.captionHealth
        merged.translationHealth = .pending
        merged.createdAt = turn.createdAt
        return merged
    }

    private func joinedTranscriptText(_ first: String, _ second: String) -> String {
        let trimmedFirst = first.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecond = second.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedFirst.isEmpty {
            return trimmedSecond
        }
        if trimmedSecond.isEmpty {
            return trimmedFirst
        }
        return "\(trimmedFirst) \(trimmedSecond)"
    }

    public mutating func attachTranslation(_ text: String, toTurnID turnID: String) {
        guard let index = turns.firstIndex(where: { $0.id == turnID }) else { return }
        turns[index].translatedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        turns[index].translationHealth = .live
    }

    public mutating func appendTranslation(_ text: String, toTurnID turnID: String) {
        guard let index = turns.firstIndex(where: { $0.id == turnID }) else { return }
        turns[index].translatedText = joinedTranscriptText(turns[index].translatedText ?? "", text)
        turns[index].translationHealth = .live
    }

    public mutating func markTranslationFailed(forTurnID turnID: String, message: String) {
        guard let index = turns.firstIndex(where: { $0.id == turnID }) else { return }
        turns[index].translationHealth = .failed(message)
    }

    public mutating func reset(sourceLocale: String, targetLocale: String) {
        self.sourceLocale = sourceLocale
        self.targetLocale = targetLocale
        turns.removeAll()
    }
}

public struct LiveCaptionTranslationAdapter {
    private let provider: TextTranslationProvider

    public init(provider: TextTranslationProvider) {
        self.provider = provider
    }

    public func translate(turn: LiveCaptionTurn, in store: inout LiveCaptionStore) async throws {
        guard turn.isFinal else { return }
        let segment = TranscriptSegment(
            id: turn.sourceSegmentID,
            speaker: turn.speaker,
            text: turn.originalText,
            language: turn.sourceLocale,
            isFinal: turn.isFinal,
            createdAt: turn.createdAt
        )
        do {
            let translated = try await provider.translate(
                transcript: TranscriptDocument(segments: [segment]),
                options: TranslationOptions(sourceLocale: turn.sourceLocale, targetLocale: turn.targetLocale)
            )
            let translatedText = translated.segments.first { $0.id == turn.sourceSegmentID }?.targetText ?? ""
            store.attachTranslation(translatedText, toTurnID: turn.id)
        } catch {
            let nsError = error as NSError
            store.markTranslationFailed(forTurnID: turn.id, message: "\(nsError.domain) error \(nsError.code)")
            throw error
        }
    }
}

public enum MeetingProgressStatus: String, Codable, Equatable {
    case notStarted
    case onTrack
    case partiallyCovered
    case blocked

    public var displayText: String {
        switch self {
        case .notStarted:
            return "not started"
        case .onTrack:
            return "on track"
        case .partiallyCovered:
            return "partially covered"
        case .blocked:
            return "blocked"
        }
    }
}

public enum MeetingObjectiveProgressStatus: String, Codable, Equatable {
    case pending
    case confirmed
    case unresolved
}

public struct MeetingObjectiveProgress: Codable, Equatable {
    public var objectiveID: String
    public var title: String
    public var status: MeetingObjectiveProgressStatus
    public var evidenceSegmentIDs: [String]

    public init(
        objectiveID: String,
        title: String,
        status: MeetingObjectiveProgressStatus,
        evidenceSegmentIDs: [String]
    ) {
        self.objectiveID = objectiveID
        self.title = title
        self.status = status
        self.evidenceSegmentIDs = evidenceSegmentIDs
    }
}

public struct FollowUpQuestionSuggestion: Codable, Equatable, Identifiable {
    public var id: String
    public var chinese: String
    public var english: String
    public var sourceObjectiveID: String?

    public init(id: String? = nil, chinese: String, english: String, sourceObjectiveID: String?) {
        self.english = english
        self.chinese = chinese
        self.sourceObjectiveID = sourceObjectiveID
        self.id = id ?? english
    }
}

public struct MeetingProgressHealth: Codable, Equatable {
    public var caption: LivePipelineHealth
    public var translation: LivePipelineHealth
    public var analysis: LivePipelineHealth

    public init(caption: LivePipelineHealth, translation: LivePipelineHealth, analysis: LivePipelineHealth) {
        self.caption = caption
        self.translation = translation
        self.analysis = analysis
    }
}

public struct MeetingProgressState: Codable, Equatable {
    public var schemaVersion: Int
    public var meetingID: UUID
    public var goal: MeetingGoal
    public var status: MeetingProgressStatus
    public var objectives: [MeetingObjectiveProgress]
    public var confirmedItems: [String]
    public var unresolvedItems: [String]
    public var suggestedQuestions: [FollowUpQuestionSuggestion]
    public var health: MeetingProgressHealth
    public var lastAnalyzedSegmentID: String?
    public var updatedAt: Date

    public init(
        schemaVersion: Int = 1,
        meetingID: UUID,
        goal: MeetingGoal,
        status: MeetingProgressStatus,
        objectives: [MeetingObjectiveProgress],
        confirmedItems: [String],
        unresolvedItems: [String],
        suggestedQuestions: [FollowUpQuestionSuggestion],
        health: MeetingProgressHealth,
        lastAnalyzedSegmentID: String?,
        updatedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.meetingID = meetingID
        self.goal = goal
        self.status = status
        self.objectives = objectives
        self.confirmedItems = confirmedItems
        self.unresolvedItems = unresolvedItems
        self.suggestedQuestions = suggestedQuestions
        self.health = health
        self.lastAnalyzedSegmentID = lastAnalyzedSegmentID
        self.updatedAt = updatedAt
    }
}

public protocol MeetingProgressAnalyzing {
    func analyze(
        goal: MeetingGoal,
        recentCaptions: [LiveCaptionTurn],
        previousState: MeetingProgressState?
    ) async throws -> MeetingProgressState
}

public final class DeterministicMeetingProgressAnalyzer: MeetingProgressAnalyzing {
    private let meetingID: UUID
    private let now: () -> Date

    public init(meetingID: UUID = UUID(), now: @escaping () -> Date = Date.init) {
        self.meetingID = meetingID
        self.now = now
    }

    public func analyze(
        goal: MeetingGoal,
        recentCaptions: [LiveCaptionTurn],
        previousState: MeetingProgressState?
    ) async throws -> MeetingProgressState {
        let text = recentCaptions.map(\.originalText).joined(separator: " ").lowercased()
        let objectiveProgress = goal.objectives.map { objective in
            let terms = ([objective.title] + objective.keywords).map { $0.lowercased() }
            let matched = terms.contains { !text.isEmpty && text.contains($0) }
            return MeetingObjectiveProgress(
                objectiveID: objective.id,
                title: objective.title,
                status: matched ? .confirmed : .unresolved,
                evidenceSegmentIDs: matched ? recentCaptions.map(\.sourceSegmentID) : []
            )
        }
        let confirmed = objectiveProgress.filter { $0.status == .confirmed }.map(\.title)
        let unresolved = objectiveProgress.filter { $0.status == .unresolved }.map(\.title)
        let status: MeetingProgressStatus
        if objectiveProgress.isEmpty {
            status = .onTrack
        } else if confirmed.isEmpty {
            status = .notStarted
        } else if unresolved.isEmpty {
            status = .onTrack
        } else {
            status = .partiallyCovered
        }
        let questions = goal.requiredQuestions
            .filter { question in
                !text.contains(question.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "?？")))
            }
            .prefix(3)
            .map {
                FollowUpQuestionSuggestion(
                    chinese: Self.simpleChinesePrompt(for: $0),
                    english: $0,
                    sourceObjectiveID: nil
                )
            }
        return MeetingProgressState(
            meetingID: previousState?.meetingID ?? meetingID,
            goal: goal,
            status: status,
            objectives: objectiveProgress,
            confirmedItems: confirmed,
            unresolvedItems: unresolved,
            suggestedQuestions: Array(questions),
            health: MeetingProgressHealth(caption: .live, translation: .pending, analysis: .live),
            lastAnalyzedSegmentID: recentCaptions.last?.sourceSegmentID ?? previousState?.lastAnalyzedSegmentID,
            updatedAt: now()
        )
    }

    private static func simpleChinesePrompt(for english: String) -> String {
        "请确认：\(english)"
    }
}

public final class MeetingProgressCoordinator {
    private let goal: MeetingGoal
    private let analyzer: MeetingProgressAnalyzing
    private let progressURL: URL
    private let minimumAnalysisInterval: TimeInterval
    private let now: () -> Date
    private var lastAnalyzedAt: Date?

    public private(set) var state: MeetingProgressState?
    public private(set) var analysisHealth: LivePipelineHealth = .idle

    public init(
        goal: MeetingGoal,
        analyzer: MeetingProgressAnalyzing,
        progressURL: URL,
        minimumAnalysisInterval: TimeInterval = 30,
        now: @escaping () -> Date = Date.init
    ) {
        self.goal = goal
        self.analyzer = analyzer
        self.progressURL = progressURL
        self.minimumAnalysisInterval = minimumAnalysisInterval
        self.now = now
    }

    public func process(turns: [LiveCaptionTurn]) async {
        let finalTurns = turns.filter(\.isFinal)
        let newTurns = turnsAfterLastAnalyzed(in: finalTurns)
        guard !newTurns.isEmpty else { return }
        let currentTime = now()
        if let lastAnalyzedAt, currentTime.timeIntervalSince(lastAnalyzedAt) < minimumAnalysisInterval {
            return
        }
        analysisHealth = .pending
        do {
            let nextState = try await analyzer.analyze(
                goal: goal,
                recentCaptions: newTurns,
                previousState: state
            )
            state = nextState
            lastAnalyzedAt = currentTime
            analysisHealth = .live
            try persist(nextState)
        } catch {
            let nsError = error as NSError
            analysisHealth = .failed("\(nsError.domain) error \(nsError.code)")
        }
    }

    private func turnsAfterLastAnalyzed(in turns: [LiveCaptionTurn]) -> [LiveCaptionTurn] {
        guard let lastAnalyzedSegmentID = state?.lastAnalyzedSegmentID,
              let index = turns.lastIndex(where: { $0.sourceSegmentID == lastAnalyzedSegmentID })
        else {
            return turns
        }
        return Array(turns.dropFirst(index + 1))
    }

    private func persist(_ state: MeetingProgressState) throws {
        let directory = progressURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.meetingAgent.encode(state)
        try data.write(to: progressURL, options: .atomic)
    }
}

public final class TranscriptFixtureReplay {
    private let segments: [TranscriptSegment]
    private let failureAfterSegmentID: String?

    public private(set) var failureHealth: LivePipelineHealth = .idle

    public init(segments: [TranscriptSegment], failureAfterSegmentID: String? = nil) {
        self.segments = segments
        self.failureAfterSegmentID = failureAfterSegmentID
    }

    public func run(_ handle: (TranscriptSegment) async -> Void) async {
        for segment in segments where segment.isFinal {
            await handle(segment)
            if segment.id == failureAfterSegmentID {
                failureHealth = .failed("Replay stopped after \(segment.id)")
                return
            }
        }
        failureHealth = .live
    }
}

public struct GoalOrientedSummaryProvider {
    public init() {}

    public func generate(
        transcript: TranscriptDocument,
        progress: MeetingProgressState?,
        generatedAt: Date = Date()
    ) -> MeetingSummary {
        let sourceSegmentIDs = transcript.segments.map(\.id)
        guard let progress else {
            return MeetingSummary(
                overview: "No meeting progress snapshot was available. Summary is based on transcript only.",
                keyTopics: [],
                decisions: [],
                actionItems: [],
                openQuestions: [],
                risks: [],
                followUps: [],
                language: transcript.segments.compactMap(\.language).first,
                sourceSegmentIDs: sourceSegmentIDs,
                generatedAt: generatedAt,
                provider: "goal-oriented-deterministic",
                status: .succeeded,
                failureReason: nil
            )
        }
        return MeetingSummary(
            overview: "Goal: \(progress.goal.title). Current status: \(progress.status.displayText).",
            keyTopics: ["Goal status: \(progress.status.displayText)"],
            decisions: progress.confirmedItems.map {
                MeetingDecision(description: $0, participants: [], sourceSegmentIDs: sourceSegmentIDs, confidence: 0.8)
            },
            actionItems: [],
            openQuestions: progress.unresolvedItems,
            risks: [],
            followUps: progress.suggestedQuestions.map(\.english),
            language: transcript.segments.compactMap(\.language).first,
            sourceSegmentIDs: sourceSegmentIDs,
            generatedAt: generatedAt,
            provider: "goal-oriented-deterministic",
            status: .succeeded,
            failureReason: nil
        )
    }
}
