import Foundation

public enum MeetingKnowledgeConfidence: String, Codable, Equatable {
    case high = "High"
    case medium = "Medium"
    case low = "Low"

    static func fromScore(_ score: Double) -> MeetingKnowledgeConfidence {
        if score >= 0.8 { return .high }
        if score >= 0.5 { return .medium }
        return .low
    }
}

public struct MeetingKnowledgeEvidence: Codable, Equatable {
    public let segmentID: String
    public let speaker: String
    public let timestamp: String?
    public let anchor: String

    public init(segmentID: String, speaker: String, timestamp: String?, anchor: String) {
        self.segmentID = segmentID
        self.speaker = speaker
        self.timestamp = timestamp
        self.anchor = anchor
    }
}

public struct MeetingKnowledgeItem: Codable, Equatable {
    public let id: String
    public let statement: String?
    public let question: String?
    public let entity: String?
    public let type: String?
    public let owner: String?
    public let due: String?
    public let related: [String]
    public let confidence: MeetingKnowledgeConfidence?
    public let status: String
    public let evidence: [MeetingKnowledgeEvidence]
    public let note: String?

    public init(
        id: String,
        statement: String? = nil,
        question: String? = nil,
        entity: String? = nil,
        type: String? = nil,
        owner: String? = nil,
        due: String? = nil,
        related: [String] = [],
        confidence: MeetingKnowledgeConfidence? = nil,
        status: String,
        evidence: [MeetingKnowledgeEvidence] = [],
        note: String? = nil
    ) {
        self.id = id
        self.statement = statement
        self.question = question
        self.entity = entity
        self.type = type
        self.owner = owner
        self.due = due
        self.related = related
        self.confidence = confidence
        self.status = status
        self.evidence = evidence
        self.note = note
    }
}

public struct MeetingKnowledge: Codable, Equatable {
    public let facts: [MeetingKnowledgeItem]
    public let judgments: [MeetingKnowledgeItem]
    public let decisions: [MeetingKnowledgeItem]
    public let actions: [MeetingKnowledgeItem]
    public let openQuestions: [MeetingKnowledgeItem]
    public let entityUpdates: [MeetingKnowledgeItem]
    public let failureReason: String?

    public init(
        facts: [MeetingKnowledgeItem] = [],
        judgments: [MeetingKnowledgeItem] = [],
        decisions: [MeetingKnowledgeItem] = [],
        actions: [MeetingKnowledgeItem] = [],
        openQuestions: [MeetingKnowledgeItem] = [],
        entityUpdates: [MeetingKnowledgeItem] = [],
        failureReason: String? = nil
    ) {
        self.facts = facts
        self.judgments = judgments
        self.decisions = decisions
        self.actions = actions
        self.openQuestions = openQuestions
        self.entityUpdates = entityUpdates
        self.failureReason = failureReason
    }
}

public struct MeetingKnowledgePackage: Equatable {
    public let record: MeetingRecord
    public let summary: MeetingSummary?
    public let segments: [TranscriptSegment]
    public let knowledge: MeetingKnowledge

    public init(
        record: MeetingRecord,
        summary: MeetingSummary?,
        segments: [TranscriptSegment],
        knowledge: MeetingKnowledge
    ) {
        self.record = record
        self.summary = summary
        self.segments = segments
        self.knowledge = knowledge
    }
}

public enum MeetingKnowledgeExtractor {
    public static func fromSummary(_ summary: MeetingSummary, segments: [TranscriptSegment]) -> MeetingKnowledge {
        let lookup = MeetingKnowledgeSegmentLookup(segments: segments)

        return MeetingKnowledge(
            facts: numberedItems(
                prefix: "fact",
                values: summary.keyTopics,
                sourceSegmentIDs: summary.sourceSegmentIDs,
                lookup: lookup,
                confidence: .medium
            ),
            judgments: numberedItems(
                prefix: "judgment",
                values: summary.risks,
                sourceSegmentIDs: summary.sourceSegmentIDs,
                lookup: lookup,
                confidence: .medium,
                note: "This is an inferred judgment from the meeting summary and should be reviewed before reuse."
            ),
            decisions: summary.decisions.enumerated().map { index, decision in
                MeetingKnowledgeItem(
                    id: numberedID(prefix: "decision", index: index),
                    statement: decision.description,
                    confidence: .fromScore(decision.confidence),
                    status: "Proposed",
                    evidence: lookup.evidence(for: decision.sourceSegmentIDs)
                )
            },
            actions: summary.actionItems.enumerated().map { index, action in
                MeetingKnowledgeItem(
                    id: numberedID(prefix: "action", index: index),
                    statement: action.description,
                    owner: action.owner,
                    due: action.dueDate,
                    confidence: .fromScore(action.confidence),
                    status: "Open",
                    evidence: lookup.evidence(for: action.sourceSegmentIDs)
                )
            },
            openQuestions: summary.openQuestions.enumerated().map { index, question in
                MeetingKnowledgeItem(
                    id: numberedID(prefix: "question", index: index),
                    question: question,
                    status: "Open",
                    evidence: lookup.evidence(for: summary.sourceSegmentIDs)
                )
            },
            entityUpdates: []
        )
    }

    private static func numberedItems(
        prefix: String,
        values: [String],
        sourceSegmentIDs: [String],
        lookup: MeetingKnowledgeSegmentLookup,
        confidence: MeetingKnowledgeConfidence,
        note: String? = nil
    ) -> [MeetingKnowledgeItem] {
        values.enumerated().map { index, value in
            MeetingKnowledgeItem(
                id: numberedID(prefix: prefix, index: index),
                statement: value,
                confidence: confidence,
                status: "Proposed",
                evidence: lookup.evidence(for: sourceSegmentIDs),
                note: note
            )
        }
    }

    private static func numberedID(prefix: String, index: Int) -> String {
        "\(prefix)_\(String(format: "%03d", index + 1))"
    }
}

public enum MeetingKnowledgePackageMarkdownRenderer {
    public static func renderMeeting(_ package: MeetingKnowledgePackage) -> String {
        var lines = frontmatter([
            ("type", "meeting"),
            ("meeting_id", package.record.id.uuidString),
            ("title", title(for: package)),
            ("date", dateOnly(package.record.startedAt)),
            ("started_at", iso(package.record.startedAt)),
            ("ended_at", package.record.endedAt.map(iso)),
            ("language", package.summary?.language ?? package.record.speechLocaleIdentifier),
            ("transcription_provider", package.record.transcriptionProviderID)
        ])

        let participants = participantNames(for: package)
        if !participants.isEmpty {
            lines.insert(contentsOf: yamlList(title: "participants", values: participants), at: lines.count - 1)
        }

        lines.append(contentsOf: [
            "",
            "# \(title(for: package))",
            "",
            "## One-Line Summary",
            oneLineSummary(for: package),
            "",
            "## Key Outcomes"
        ])
        let outcomes = keyOutcomes(for: package)
        lines.append(contentsOf: outcomes.isEmpty ? ["No key outcomes available."] : outcomes.map { "- \($0)" })
        lines.append(contentsOf: [
            "",
            "## Meeting Context"
        ])
        if let goal = package.record.meetingGoal?.title, !goal.isEmpty {
            lines.append("- Goal: \(goal)")
        }
        lines.append(contentsOf: [
            "- Started: \(display(package.record.startedAt))",
            "- Ended: \(package.record.endedAt.map(display) ?? "Not ended")",
            "- Language: \(package.summary?.language ?? package.record.speechLocaleIdentifier)",
            "- Transcription provider: \(package.record.transcriptionProviderID)",
            "",
            "## Files",
            "- [[transcript]]",
            "- [[knowledge]]"
        ])

        return lines.joined(separator: "\n") + "\n"
    }

    public static func renderTranscript(_ package: MeetingKnowledgePackage) -> String {
        var lines = frontmatter([
            ("type", "transcript"),
            ("meeting_id", package.record.id.uuidString),
            ("source", package.record.transcriptJSONURL?.lastPathComponent ?? "transcript")
        ])
        lines.append(contentsOf: ["", "# Transcript", ""])

        if package.segments.isEmpty {
            lines.append("Transcript is not available.")
            return lines.joined(separator: "\n") + "\n"
        }

        var mapper = SpeakerLabelMapper(speakers: package.segments.map(\.speaker))
        for segment in package.segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let anchor = anchor(for: segment)
            let label = mapper.label(for: segment.speaker)
            let headingTime = timestamp(for: segment) ?? segment.id
            lines.append(#"<a id="\#(anchor)"></a>"#)
            lines.append("## \(headingTime) \(label)")
            lines.append(text)
            lines.append("")
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    public static func renderKnowledge(_ package: MeetingKnowledgePackage) -> String {
        var lines = frontmatter([
            ("type", "meeting_knowledge"),
            ("meeting_id", package.record.id.uuidString),
            ("status", "proposed"),
            ("generated_at", package.summary.map { iso($0.generatedAt) })
        ])
        lines.append(contentsOf: [
            "",
            "# Knowledge Deltas",
            "",
            "## How To Use This File",
            "Review each item before merging it into a long-term wiki or AI memory. Items marked as inference should not be treated as confirmed fact.",
            ""
        ])

        if let failureReason = package.knowledge.failureReason {
            lines.append("## Extraction Status")
            lines.append("Knowledge extraction failed: \(failureReason)")
            return lines.joined(separator: "\n") + "\n"
        }

        appendSection("Facts", items: package.knowledge.facts, mode: .statement, to: &lines)
        appendSection("Judgments", items: package.knowledge.judgments, mode: .statement, to: &lines)
        appendSection("Decisions", items: package.knowledge.decisions, mode: .statement, to: &lines)
        appendSection("Actions", items: package.knowledge.actions, mode: .statement, to: &lines)
        appendSection("Open Questions", items: package.knowledge.openQuestions, mode: .question, to: &lines)
        appendSection("Entity Updates", items: package.knowledge.entityUpdates, mode: .statement, to: &lines)

        return lines.joined(separator: "\n") + "\n"
    }

    public static func renderIngest(_ package: MeetingKnowledgePackage) -> String {
        let title = title(for: package)
        return """
        # Ingest Meeting

        Read this meeting source package:

        - [[meeting]]
        - [[transcript]]
        - [[knowledge]]

        ## Source

        - Meeting ID: \(package.record.id.uuidString)
        - Title: \(title)
        - Started: \(iso(package.record.startedAt))
        - Language: \(package.summary?.language ?? package.record.speechLocaleIdentifier)

        ## Rules

        - Treat this directory as one meeting source package.
        - Treat `transcript.md` as source evidence.
        - Treat `knowledge.md` items as proposed deltas, not automatic truth.
        - Update the long-term wiki or brain according to the local schema.
        - Preserve evidence links or convert them into the destination citation format.
        - Append timeline entries for accepted decisions, actions, and important entity updates.
        - Mark inferred judgments, cultural interpretation, or relationship insight as inference.

        """
    }

    public static func anchor(for segment: TranscriptSegment) -> String {
        if let timestamp = timestamp(for: segment) {
            return "t-" + timestamp.replacingOccurrences(of: ":", with: "-")
        }
        return "segment-\(segment.id)"
    }

    public static func timestamp(for segment: TranscriptSegment) -> String? {
        guard let seconds = segment.startTimeSeconds else { return nil }
        return timestamp(seconds)
    }

    private enum ItemMode {
        case statement
        case question
    }

    private static func appendSection(_ title: String, items: [MeetingKnowledgeItem], mode: ItemMode, to lines: inout [String]) {
        lines.append("## \(title)")
        lines.append("")
        guard !items.isEmpty else {
            lines.append("No proposed items.")
            lines.append("")
            return
        }

        for item in items {
            lines.append("### \(item.id)")
            if let entity = item.entity {
                lines.append("**Entity:** \(wikiLink(entity))  ")
            }
            if let type = item.type {
                lines.append("**Type:** \(type)  ")
            }
            switch mode {
            case .statement:
                if let statement = item.statement {
                    lines.append("**Statement:** \(statement)  ")
                }
            case .question:
                if let question = item.question ?? item.statement {
                    lines.append("**Question:** \(question)  ")
                }
            }
            if let owner = item.owner {
                lines.append("**Owner:** \(wikiLink(owner))  ")
            }
            if let due = item.due {
                lines.append("**Due:** \(due)  ")
            }
            if !item.related.isEmpty {
                lines.append("**Related:** \(item.related.map(wikiLink).joined(separator: ", "))  ")
            }
            if let confidence = item.confidence {
                lines.append("**Confidence:** \(confidence.rawValue)  ")
            }
            lines.append("**Status:** \(item.status)  ")
            lines.append("**Evidence:** \(renderEvidence(item.evidence))")
            if let note = item.note {
                lines.append("**Note:** \(note)")
            }
            lines.append("")
        }
    }

    private static func renderEvidence(_ evidence: [MeetingKnowledgeEvidence]) -> String {
        guard !evidence.isEmpty else { return "Not available" }
        return evidence.map { item in
            let label = item.timestamp.map { "\(item.speaker) \($0)" } ?? "\(item.speaker) \(item.segmentID)"
            return "[[transcript#\(item.anchor)|\(label)]]"
        }
        .joined(separator: ", ")
    }

    private static func keyOutcomes(for package: MeetingKnowledgePackage) -> [String] {
        var outcomes: [String] = []
        if let summary = package.summary {
            outcomes.append(contentsOf: summary.decisions.map(\.description))
            outcomes.append(contentsOf: summary.actionItems.map(\.description))
            outcomes.append(contentsOf: summary.openQuestions)
        }
        return outcomes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func oneLineSummary(for package: MeetingKnowledgePackage) -> String {
        let overview = package.summary?.overview.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !overview.isEmpty { return overview }
        return "No summary available."
    }

    private static func participantNames(for package: MeetingKnowledgePackage) -> [String] {
        var names = package.record.attendees.map(\.name)
        names.append(contentsOf: package.segments.compactMap(\.speakerLabel))
        var seen = Set<String>()
        return names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }

    private static func title(for package: MeetingKnowledgePackage) -> String {
        package.summary?.autoGeneratedTitle ?? package.record.name
    }

    private static func wikiLink(_ value: String) -> String {
        "[[\(value)]]"
    }

    private static func frontmatter(_ pairs: [(String, String?)]) -> [String] {
        var lines = ["---"]
        for (key, value) in pairs {
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            lines.append("\(key): \(value)")
        }
        lines.append("---")
        return lines
    }

    private static func yamlList(title: String, values: [String]) -> [String] {
        [title + ":"] + values.map { "  - \($0)" }
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func dateOnly(_ date: Date) -> String {
        String(iso(date).prefix(10))
    }

    private static func display(_ date: Date) -> String {
        iso(date)
    }

    private static func timestamp(_ seconds: Double) -> String {
        let totalSeconds = max(Int(seconds.rounded(.down)), 0)
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}

private struct MeetingKnowledgeSegmentLookup {
    private let segmentsByID: [String: TranscriptSegment]

    init(segments: [TranscriptSegment]) {
        segmentsByID = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0) })
    }

    func evidence(for segmentIDs: [String]) -> [MeetingKnowledgeEvidence] {
        var mapper = SpeakerLabelMapper(speakers: segmentsByID.values.map(\.speaker))
        return segmentIDs.compactMap { segmentID in
            guard let segment = segmentsByID[segmentID] else { return nil }
            let speaker = mapper.label(for: segment.speaker)
            return MeetingKnowledgeEvidence(
                segmentID: segment.id,
                speaker: speaker,
                timestamp: MeetingKnowledgePackageMarkdownRenderer.timestamp(for: segment),
                anchor: MeetingKnowledgePackageMarkdownRenderer.anchor(for: segment)
            )
        }
    }
}
