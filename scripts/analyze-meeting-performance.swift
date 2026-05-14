#!/usr/bin/env swift
import Foundation

struct PerformanceEvent: Decodable {
    let event: String
    let wallTime: Date
    let audioTimeSeconds: Double?
    let segmentID: String?
    let isFinal: Bool?
    let textLength: Int?
    let metadata: [String: String]

    var identity: String {
        [
            event,
            wallTime.timeIntervalSince1970.description,
            segmentID ?? "",
            metadata["turnID"] ?? "",
            metadata["sourceSegmentID"] ?? ""
        ].joined(separator: "|")
    }
}

struct TranslationResultRecord: Decodable {
    let resultID: String?
    let sourceSegmentIDs: [String]
    let translatedText: String?

    enum CodingKeys: String, CodingKey {
        case resultID
        case sourceSegmentIDs
        case translatedText
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        resultID = try container.decodeIfPresent(String.self, forKey: .resultID)
        sourceSegmentIDs = try container.decodeIfPresent([String].self, forKey: .sourceSegmentIDs) ?? []
        translatedText = try container.decodeIfPresent(String.self, forKey: .translatedText)
    }
}

struct Stats {
    let values: [Double]

    var count: Int { values.count }

    func percentile(_ percentile: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        guard sorted.count > 1 else { return sorted[0] }
        let rank = percentile / 100 * Double(sorted.count - 1)
        let lower = Int(floor(rank))
        let upper = Int(ceil(rank))
        if lower == upper { return sorted[lower] }
        let fraction = rank - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }

    var max: Double? {
        values.max()
    }
}

private let fractionalSecondsDateFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

private let wholeSecondsDateFormatter = ISO8601DateFormatter()

private func usage() -> Never {
    fputs("Usage: swift scripts/analyze-meeting-performance.swift [--assert-translation-e2e] [--assert-speaker-identification-e2e] <meeting-directory|performance-events.jsonl>\n", stderr)
    exit(2)
}

let rawArguments = Array(CommandLine.arguments.dropFirst())
let assertTranslationE2E = rawArguments.contains("--assert-translation-e2e")
let assertSpeakerIdentificationE2E = rawArguments.contains("--assert-speaker-identification-e2e")
let pathArguments = rawArguments.filter {
    $0 != "--assert-translation-e2e" && $0 != "--assert-speaker-identification-e2e"
}
guard pathArguments.count == 1 else {
    usage()
}

let inputURL = URL(fileURLWithPath: pathArguments[0])
let eventsURL: URL
let translationResultsURL: URL?
var isDirectory: ObjCBool = false
guard FileManager.default.fileExists(atPath: inputURL.path, isDirectory: &isDirectory) else {
    fputs("Input does not exist: \(inputURL.path)\n", stderr)
    exit(2)
}
if isDirectory.boolValue {
    eventsURL = inputURL.appendingPathComponent("performance-events.jsonl")
    translationResultsURL = inputURL.appendingPathComponent("translation-results.jsonl")
} else {
    eventsURL = inputURL
    translationResultsURL = nil
}

let events: [PerformanceEvent]
do {
    events = try readEvents(from: eventsURL)
} catch {
    fputs("Failed to read performance events: \(error)\n", stderr)
    exit(2)
}

guard !events.isEmpty else {
    fputs("No performance events found at \(eventsURL.path)\n", stderr)
    exit(1)
}

let translationResultRecordCount = translationResultsURL.map(countNonEmptyLines) ?? 0
let translationResultRecords = translationResultsURL.map(readTranslationResultRecords) ?? []
let analyzer = MeetingPerformanceAnalyzer(
    events: events,
    translationResultRecordCount: translationResultRecordCount,
    translationResultRecords: translationResultRecords
)
print(analyzer.report(inputPath: eventsURL.path))
if assertTranslationE2E && !analyzer.e2eTranslationPassed()
    || assertSpeakerIdentificationE2E && !analyzer.e2eSpeakerIdentificationPassed() {
    exit(1)
}

private func readEvents(from url: URL) throws -> [PerformanceEvent] {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom(decodeISO8601Date)
    let content = try String(contentsOf: url, encoding: .utf8)
    return try content
        .split(whereSeparator: \.isNewline)
        .map { try decoder.decode(PerformanceEvent.self, from: Data($0.utf8)) }
        .sorted { $0.wallTime < $1.wallTime }
}

private func decodeISO8601Date(from decoder: Decoder) throws -> Date {
    let container = try decoder.singleValueContainer()
    let value = try container.decode(String.self)
    if let date = fractionalSecondsDateFormatter.date(from: value) ?? wholeSecondsDateFormatter.date(from: value) {
        return date
    }
    throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Expected date string to be ISO8601-formatted."
    )
}

private func countNonEmptyLines(at url: URL) -> Int {
    guard let content = try? String(contentsOf: url, encoding: .utf8) else {
        return 0
    }
    return content
        .split(whereSeparator: \.isNewline)
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .count
}

private func readTranslationResultRecords(from url: URL) -> [TranslationResultRecord] {
    guard let content = try? String(contentsOf: url, encoding: .utf8) else {
        return []
    }
    return content
        .split(whereSeparator: \.isNewline)
        .compactMap { try? JSONDecoder().decode(TranslationResultRecord.self, from: Data($0.utf8)) }
}

struct MeetingPerformanceAnalyzer {
    private static let firstLiveTranslationLatencyBudgetSeconds = 4.0
    private static let minimumStableTranslationCoveragePercent = 80.0
    private static let firstSpeakerIdentityVisibleLatencyBudgetSeconds = 4.0

    let allEvents: [PerformanceEvent]
    let translationResultRecordCount: Int
    let translationResultRecords: [TranslationResultRecord]
    private let events: [PerformanceEvent]
    private let recordingStartedAt: Date?
    private let recordingStoppedAt: Date?

    init(
        events allEvents: [PerformanceEvent],
        translationResultRecordCount: Int = 0,
        translationResultRecords: [TranslationResultRecord] = []
    ) {
        self.allEvents = allEvents
        self.translationResultRecordCount = translationResultRecordCount
        self.translationResultRecords = translationResultRecords
        let recordingStartedAt = allEvents.first { $0.event == "recording_started" }?.wallTime
        let recordingStoppedAt = allEvents.first { $0.event == "recording_stopped" }?.wallTime
        self.recordingStartedAt = recordingStartedAt
        self.recordingStoppedAt = recordingStoppedAt
        self.events = allEvents.filter { event in
            guard event.metadata["path"] != "replay" else {
                return false
            }
            if let recordingStartedAt, event.wallTime < recordingStartedAt {
                return false
            }
            if let recordingStoppedAt, event.wallTime > recordingStoppedAt {
                return false
            }
            return true
        }
    }

    func report(inputPath: String) -> String {
        var lines: [String] = []
        lines.append("Meeting Performance Report")
        lines.append("Input: \(inputPath)")
        lines.append("Events: \(allEvents.count)")
        lines.append("Realtime Events: \(events.count)")
        lines.append("")
        lines.append("Experience KPIs")
        lines.append("Time to First Live Caption: \(format(duration: timeToFirstLiveCaption()))")
        lines.append("Caption Lag p50/p95/max: \(format(stats: captionLagStats()))")
        lines.append("Time to First Translation: \(format(duration: timeToFirstTranslation()))")
        lines.append("Translation Lag p50/p95/max: \(format(stats: translationLagStats()))")
        lines.append("Caption Stability: \(format(updatesPerFinalCaption())) updates/final caption")
        lines.append("Translation Success Rate: \(format(percent: translationSuccessRate()))")
        lines.append("Draft Translation Success Rate: \(format(percent: translationSuccessRate(kind: "draft")))")
        lines.append("Final Translation Success Rate: \(format(percent: translationSuccessRate(kind: "final")))")
        lines.append("Final Visible Attach Rate: \(format(percent: finalVisibleAttachRate()))")
        lines.append("Final Persist-Only Rate: \(format(percent: finalPersistOnlyRate()))")
        lines.append("Final True Failure Rate: \(format(percent: finalTrueFailureRate()))")
        lines.append("Draft Translation Trigger Rate: \(format(percent: draftTranslationTriggerRate()))")
        lines.append("Draft Translation Skip Rate: \(format(percent: draftTranslationSkipRate()))")
        lines.append("Draft Translation In-Flight Skip Count: \(draftTranslationSkipCount(reason: "in_flight"))")
        lines.append("Draft Translation Semantic Boundary Trigger Count: \(draftTranslationTriggerCount(reason: "semantic_boundary"))")
        lines.append("Draft Translation Max-Wait Trigger Count: \(draftTranslationTriggerCount(reason: "max_wait"))")
        lines.append("Draft Translation Stale Rate: \(format(percent: draftTranslationStaleRate()))")
        lines.append("Time to First Draft Translation: \(format(duration: timeToFirstDraftTranslation()))")
        lines.append("Draft Visible Update Interval p50/p95: \(formatP50P95(stats: draftVisibleUpdateIntervalStats()))")
        lines.append("Time to First Visible Translation: \(format(duration: timeToFirstVisibleTranslation()))")
        lines.append("Visible Translation Coverage: \(format(percent: visibleTranslationCoverage()))")
        lines.append("Visible Translation Gap p50/p95/max: \(format(stats: visibleTranslationGapStats()))")
        lines.append("Translation Freshness p50/p95/max: \(format(stats: translationFreshnessStats()))")
        lines.append("Exact Draft Attach Rate: \(format(percent: exactDraftAttachRate()))")
        lines.append("Approximate Draft Attach Rate: \(format(percent: approximateDraftAttachRate()))")
        lines.append("Hidden Draft Stale Rate: \(format(percent: hiddenDraftStaleRate()))")
        lines.append("Draft Translation Carry Forward Count: \(translationEvents("caption_translation_carried_forward").count)")
        lines.append("")
        lines.append("Translation Experience V2")
        lines.append("Time to First Live Translation: \(format(duration: timeToFirstLiveTranslationV2()))")
        lines.append("Live Translation Calls: \(events.filter { $0.event == "translation_live_request_started" }.count)")
        lines.append("Stable Translation Success Count: \(events.filter { $0.event == "translation_stable_result_visible" }.count)")
        lines.append("")
        lines.append("Unit Translation Pipeline")
        lines.append("Live Unit Scheduled Count: \(unitEvents("translation_unit_live_scheduled").count)")
        lines.append("Live Unit Stale Count: \(unitEvents("translation_unit_live_stale").count)")
        lines.append("Live Unit Dropped After Stop Count: \(allUnitEvents("translation_unit_live_dropped_after_stop").count)")
        lines.append("Stable Unit Persisted Count: \(allUnitEvents("translation_unit_final_persisted").count)")
        lines.append("Preview Dropped After Stop Count: \(allUnitEvents("translation_preview_dropped_after_stop").count)")
        lines.append("Preview Published After Stop Count: \(allUnitEvents("translation_preview_published_after_stop").count)")
        lines.append("Translation Runtime Snapshot Count: \(translationRuntimeSnapshots().count)")
        lines.append("Translation Runtime Stop Snapshot Count: \(translationRuntimeSnapshots(path: "stop").count)")
        lines.append("Post-Stop Runtime Realtime Snapshot Count: \(postStopRuntimeRealtimeSnapshots().count)")
        lines.append("Translation Runtime Dropped Result Count: \(translationRuntimeDroppedResultCount())")
        lines.append("Stable Unit Unique Result Count: \(uniqueStableUnitPersistedResultIDs().count)")
        lines.append("Stable Unit Duplicate Persist Count: \(stableUnitDuplicatePersistCount())")
        lines.append("Post-Stop Unit Translation Events: \(postStopUnitTranslationEvents().count)")
        lines.append("")
        lines.append("End-to-End Translation Validation")
        lines.append(contentsOf: e2eTranslationValidationLines())
        lines.append("")
        lines.append("End-to-End Speaker Identification Validation")
        lines.append(contentsOf: e2eSpeakerIdentificationValidationLines())
        lines.append("")
        lines.append("Process Metrics")
        lines.append("First caption path: \(firstCaptionPathText())")
        lines.append("Caption visible lag p50/p95/max: \(format(stats: captionVisiblePipelineStats()))")
        lines.append("Translation path p50: \(translationPathText())")
        lines.append("Translation outcomes: scheduled \(translationEvents("caption_translation_scheduled").count), attached \(translationEvents("caption_translation_attached").count), persisted \(translationEvents("caption_translation_persisted").count), rebound \(translationEvents("caption_translation_rebound").count), stale \(translationEvents("caption_translation_stale").count), cancelled \(translationEvents("caption_translation_cancelled").count), provider_error \(translationEvents("caption_translation_provider_error").count)")
        lines.append("Batch/Flush Caption Events: \(batchOrFlushCaptionEvents.count) excluded from primary caption lag")
        let replayOverhead = replayOverheadLines()
        if !replayOverhead.isEmpty {
            lines.append("")
            lines.append("Replay / Idle Overhead")
            lines.append(contentsOf: replayOverhead)
        }
        let diagnostics = diagnosticLines()
        if !diagnostics.isEmpty {
            lines.append("")
            lines.append("Diagnostics")
            lines.append(contentsOf: diagnostics)
        }
        return lines.joined(separator: "\n")
    }

    func e2eTranslationPassed() -> Bool {
        e2eTranslationValidation().passed
    }

    func e2eSpeakerIdentificationPassed() -> Bool {
        e2eSpeakerIdentificationValidation().passed
    }

    private func replayOverheadLines() -> [String] {
        let replayCaptionVisible = allEvents.filter {
            $0.event == "caption_turn_visible" && $0.metadata["path"] == "replay"
        }.count
        let postStopTranslation = allEvents.filter { event in
            guard let recordingStoppedAt else { return false }
            return event.wallTime > recordingStoppedAt
                && event.event.hasPrefix("caption_translation_")
        }.count
        let postStopUnitTranslation = postStopUnitTranslationEvents().count
        guard replayCaptionVisible > 0 || postStopTranslation > 0 || postStopUnitTranslation > 0 else {
            return []
        }
        return [
            "Replay Caption Visible Events: \(replayCaptionVisible)",
            "Post-Stop Translation Events: \(postStopTranslation)",
            "Post-Stop Unit Translation Events: \(postStopUnitTranslation)"
        ]
    }

    private var firstAudioSent: PerformanceEvent? {
        events.first { $0.event == "deepgram_audio_frame_sent" }
    }

    private var firstCaptionVisible: PerformanceEvent? {
        events.first { $0.event == "caption_turn_visible" }
    }

    private var finalCaptionVisibleEvents: [PerformanceEvent] {
        events.filter { $0.event == "caption_turn_visible" && $0.isFinal == true }
    }

    private var primaryFinalCaptionVisibleEvents: [PerformanceEvent] {
        let excludedIDs = batchOrFlushCaptionEventIDs
        var seenSegmentIDs = Set<String>()
        return finalCaptionVisibleEvents.filter { event in
            guard !excludedIDs.contains(event.identity) else {
                return false
            }
            guard let segmentID = event.segmentID else {
                return true
            }
            return seenSegmentIDs.insert(segmentID).inserted
        }
    }

    private var batchOrFlushCaptionEvents: [PerformanceEvent] {
        let ids = batchOrFlushCaptionEventIDs
        return finalCaptionVisibleEvents.filter { event in
            ids.contains(event.identity)
        }
    }

    private var batchOrFlushCaptionEventIDs: Set<String> {
        let groupedBySecond = Dictionary(grouping: finalCaptionVisibleEvents) { event in
            Int(event.wallTime.timeIntervalSince1970.rounded(.down))
        }
        let burstIDs = groupedBySecond.values
            .filter { $0.count >= 3 }
            .flatMap { $0.map(\.identity) }
        return Set(burstIDs)
    }

    private func timeToFirstLiveCaption() -> Double? {
        guard let start = firstAudioSent?.wallTime,
              let caption = firstCaptionVisible?.wallTime else {
            return nil
        }
        return max(0, caption.timeIntervalSince(start))
    }

    private func captionLagStats() -> Stats {
        Stats(values: primaryFinalCaptionVisibleEvents.compactMap(audioLag))
    }

    private func captionVisiblePipelineStats() -> Stats {
        let sttBySegmentID = Dictionary(grouping: events.filter { $0.event == "stt_segment_received" }) { $0.segmentID ?? "" }
        let values = primaryFinalCaptionVisibleEvents.compactMap { caption -> Double? in
            guard let segmentID = caption.segmentID,
                  let stt = sttBySegmentID[segmentID]?.last(where: { $0.wallTime <= caption.wallTime }) else {
                return nil
            }
            return max(0, caption.wallTime.timeIntervalSince(stt.wallTime))
        }
        return Stats(values: values)
    }

    private func timeToFirstTranslation() -> Double? {
        guard let caption = firstCaptionVisible?.wallTime,
              let attached = translationEvents("caption_translation_attached").first?.wallTime else {
            return nil
        }
        return max(0, attached.timeIntervalSince(caption))
    }

    private func translationLagStats() -> Stats {
        let finalCaptionBySegmentID = Dictionary(grouping: primaryFinalCaptionVisibleEvents) { $0.segmentID ?? "" }
        let values = translationEvents("caption_translation_attached").compactMap { attached -> Double? in
            let sourceID = attached.metadata["sourceSegmentID"] ?? attached.segmentID ?? ""
            guard let sourceCaption = finalCaptionBySegmentID[sourceID]?.last,
                  let audioTimeSeconds = sourceCaption.audioTimeSeconds,
                  let sessionStart = firstAudioSent?.wallTime else {
                return nil
            }
            return max(0, attached.wallTime.timeIntervalSince(sessionStart) - audioTimeSeconds)
        }
        return Stats(values: values)
    }

    private func updatesPerFinalCaption() -> Double? {
        let finalCount = max(1, primaryFinalCaptionVisibleEvents.count)
        let draftCount = events.filter { $0.event == "caption_turn_visible" && $0.isFinal == false }.count
        return Double(draftCount) / Double(finalCount)
    }

    private func translationSuccessRate() -> Double? {
        let scheduled = translationEvents("caption_translation_scheduled").count
        guard scheduled > 0 else { return nil }
        let successful = successfulTranslationEvents().count
        return Double(successful) / Double(scheduled) * 100
    }

    private func translationSuccessRate(kind: String) -> Double? {
        let scheduled = translationEvents("caption_translation_scheduled")
            .filter { $0.metadata["translationKind"] == kind }
            .count
        guard scheduled > 0 else { return nil }
        let successful = successfulTranslationEvents(kind: kind).count
        return Double(successful) / Double(scheduled) * 100
    }

    private func successfulTranslationEvents(kind: String? = nil) -> [PerformanceEvent] {
        let successEvents = translationEvents("caption_translation_attached")
            + translationEvents("caption_translation_persisted")
        guard let kind else { return successEvents }
        return successEvents.filter { $0.metadata["translationKind"] == kind }
    }

    private func finalVisibleAttachRate() -> Double? {
        let scheduled = translationEvents("caption_translation_scheduled")
            .filter { $0.metadata["translationKind"] == "final" }
            .count
        guard scheduled > 0 else { return nil }
        let attached = translationEvents("caption_translation_attached")
            .filter { $0.metadata["translationKind"] == "final" }
            .count
        return Double(attached) / Double(scheduled) * 100
    }

    private func finalPersistOnlyRate() -> Double? {
        let scheduled = translationEvents("caption_translation_scheduled")
            .filter { $0.metadata["translationKind"] == "final" }
            .count
        guard scheduled > 0 else { return nil }
        let persisted = translationEvents("caption_translation_persisted")
            .filter { $0.metadata["translationKind"] == "final" }
            .count
        return Double(persisted) / Double(scheduled) * 100
    }

    private func finalTrueFailureRate() -> Double? {
        let scheduled = translationEvents("caption_translation_scheduled")
            .filter { $0.metadata["translationKind"] == "final" }
            .count
        guard scheduled > 0 else { return nil }
        let trueStaleReasons: Set<String> = [
            "source_segment_deleted",
            "target_locale_changed",
            "provider_configuration_changed"
        ]
        let staleFailures = translationEvents("caption_translation_stale")
            .filter { $0.metadata["translationKind"] == "final" }
            .filter { trueStaleReasons.contains($0.metadata["reason"] ?? "") }
            .count
        let providerFailures = translationEvents("caption_translation_provider_error")
            .filter { $0.metadata["translationKind"] == "final" }
            .count
        return Double(staleFailures + providerFailures) / Double(scheduled) * 100
    }

    private func draftTranslationTriggerRate() -> Double? {
        let triggered = draftTriggerEvents.count
        let skipped = draftSkipEvents.count
        guard triggered + skipped > 0 else { return nil }
        return Double(triggered) / Double(triggered + skipped) * 100
    }

    private func draftTranslationSkipRate() -> Double? {
        let triggered = draftTriggerEvents.count
        let skipped = draftSkipEvents.count
        guard triggered + skipped > 0 else { return nil }
        return Double(skipped) / Double(triggered + skipped) * 100
    }

    private func draftTranslationTriggerCount(reason: String) -> Int {
        draftTriggerEvents.filter { $0.metadata["reason"] == reason }.count
    }

    private func draftTranslationSkipCount(reason: String) -> Int {
        draftSkipEvents.filter { $0.metadata["reason"] == reason }.count
    }

    private func draftTranslationStaleRate() -> Double? {
        let scheduled = translationEvents("caption_translation_scheduled")
            .filter { $0.metadata["translationKind"] == "draft" }
            .count
        guard scheduled > 0 else { return nil }
        let stale = translationEvents("caption_translation_stale")
            .filter { $0.metadata["translationKind"] == "draft" }
            .count
        return Double(stale) / Double(scheduled) * 100
    }

    private func timeToFirstDraftTranslation() -> Double? {
        guard let firstDraftCaption = events.first(where: { $0.event == "caption_turn_visible" && $0.isFinal == false })?.wallTime,
              let firstDraftAttached = draftAttachedEvents.first?.wallTime else {
            return nil
        }
        return max(0, firstDraftAttached.timeIntervalSince(firstDraftCaption))
    }

    private func draftVisibleUpdateIntervalStats() -> Stats {
        let attached = draftAttachedEvents.sorted { $0.wallTime < $1.wallTime }
        guard attached.count >= 2 else {
            return Stats(values: [])
        }
        let values = zip(attached, attached.dropFirst()).map { previous, current in
            max(0, current.wallTime.timeIntervalSince(previous.wallTime))
        }
        return Stats(values: values)
    }

    private func timeToFirstVisibleTranslation() -> Double? {
        guard let firstCaption = firstCaptionVisible?.wallTime,
              let firstVisible = visibleTranslationEvents().first?.wallTime else {
            return nil
        }
        return max(0, firstVisible.timeIntervalSince(firstCaption))
    }

    private func timeToFirstLiveTranslationV2() -> Double? {
        guard let firstAudioSent = firstAudioSent?.wallTime,
              let firstLive = events.first(where: { $0.event == "translation_live_result_visible" })?.wallTime else {
            return nil
        }
        return max(0, firstLive.timeIntervalSince(firstAudioSent))
    }

    private func visibleTranslationCoverage() -> Double? {
        guard let firstCaption = firstCaptionVisible?.wallTime,
              let lastCaption = events.last(where: { $0.event == "caption_turn_visible" })?.wallTime,
              let firstVisible = visibleTranslationEvents().first?.wallTime else {
            return nil
        }
        let total = max(0, lastCaption.timeIntervalSince(firstCaption))
        guard total > 0 else { return nil }
        let covered = max(0, lastCaption.timeIntervalSince(firstVisible))
        return min(100, covered / total * 100)
    }

    private func visibleTranslationGapStats() -> Stats {
        let visible = (visibleTranslationEvents() + translationEvents("caption_translation_carried_forward"))
            .sorted { $0.wallTime < $1.wallTime }
        guard visible.count >= 2 else {
            return Stats(values: [])
        }
        let values = zip(visible, visible.dropFirst()).map { previous, current in
            max(0, current.wallTime.timeIntervalSince(previous.wallTime))
        }
        return Stats(values: values)
    }

    private func translationFreshnessStats() -> Stats {
        let values = (visibleTranslationEvents() + translationEvents("caption_translation_carried_forward"))
            .compactMap { event -> Double? in
                guard let value = event.metadata["sourceLagMilliseconds"],
                      let milliseconds = Double(value) else {
                    return nil
                }
                return milliseconds / 1_000
            }
        return Stats(values: values)
    }

    private func exactDraftAttachRate() -> Double? {
        draftVisibleOutcomeRate(eventName: "caption_translation_exact_attached", denominatorIncludesHidden: false)
    }

    private func approximateDraftAttachRate() -> Double? {
        draftVisibleOutcomeRate(eventName: "caption_translation_approximate_attached", denominatorIncludesHidden: false)
    }

    private func hiddenDraftStaleRate() -> Double? {
        let exact = draftVisibilityEvents("caption_translation_exact_attached").count
        let approximate = draftVisibilityEvents("caption_translation_approximate_attached").count
        let hidden = draftVisibilityEvents("caption_translation_hidden_stale").count
        let denominator = exact + approximate + hidden
        guard denominator > 0 else { return nil }
        return Double(hidden) / Double(denominator) * 100
    }

    private func draftVisibleOutcomeRate(eventName: String, denominatorIncludesHidden: Bool) -> Double? {
        let exact = draftVisibilityEvents("caption_translation_exact_attached").count
        let approximate = draftVisibilityEvents("caption_translation_approximate_attached").count
        let hidden = denominatorIncludesHidden ? draftVisibilityEvents("caption_translation_hidden_stale").count : 0
        let denominator = exact + approximate + hidden
        guard denominator > 0 else { return nil }
        let numerator = draftVisibilityEvents(eventName).count
        return Double(numerator) / Double(denominator) * 100
    }

    private func firstCaptionPathText() -> String {
        guard let audio = firstAudioSent else {
            return "unavailable"
        }
        let raw = events.first { $0.event == "deepgram_raw_response_received" }
        let stt = events.first { $0.event == "stt_segment_received" }
        let caption = firstCaptionVisible
        var parts: [String] = []
        if let raw {
            parts.append("audio sent -> Deepgram response \(format(duration: raw.wallTime.timeIntervalSince(audio.wallTime)))")
        }
        if let raw, let stt {
            parts.append("response -> STT segment \(format(duration: stt.wallTime.timeIntervalSince(raw.wallTime)))")
        }
        if let stt, let caption {
            parts.append("STT segment -> caption visible \(format(duration: caption.wallTime.timeIntervalSince(stt.wallTime)))")
        }
        return parts.isEmpty ? "unavailable" : parts.joined(separator: ", ")
    }

    private func translationPathText() -> String {
        let requests = groupedTranslationRequests()
        let scheduledToStarted = requests.compactMap { duration(from: "caption_translation_scheduled", to: "caption_translation_started", in: $0.value) }
        let startedToFinished = requests.compactMap { duration(from: "caption_translation_started", to: "caption_translation_finished", in: $0.value) }
        let finishedToAttached = requests.compactMap { duration(from: "caption_translation_finished", to: "caption_translation_attached", in: $0.value) }
        return [
            "scheduled -> started \(format(duration: Stats(values: scheduledToStarted).percentile(50)))",
            "started -> finished \(format(duration: Stats(values: startedToFinished).percentile(50)))",
            "finished -> attached \(format(duration: Stats(values: finishedToAttached).percentile(50)))"
        ].joined(separator: ", ")
    }

    private func groupedTranslationRequests() -> [String: [PerformanceEvent]] {
        Dictionary(grouping: events.filter { $0.event.hasPrefix("caption_translation_") }) {
            $0.metadata["translationRequestID"] ?? $0.segmentID ?? "unknown"
        }
    }

    private func duration(from startName: String, to endName: String, in events: [PerformanceEvent]) -> Double? {
        guard let start = events.first(where: { $0.event == startName }),
              let end = events.first(where: { $0.event == endName }) else {
            return nil
        }
        return max(0, end.wallTime.timeIntervalSince(start.wallTime))
    }

    private func audioLag(for event: PerformanceEvent) -> Double? {
        guard let sessionStart = firstAudioSent?.wallTime,
              let audioTimeSeconds = event.audioTimeSeconds else {
            return nil
        }
        return max(0, event.wallTime.timeIntervalSince(sessionStart) - audioTimeSeconds)
    }

    private func translationEvents(_ name: String) -> [PerformanceEvent] {
        events.filter { $0.event == name }
    }

    private func unitEvents(_ name: String) -> [PerformanceEvent] {
        events.filter { $0.event == name }
    }

    private func allUnitEvents(_ name: String) -> [PerformanceEvent] {
        allEvents.filter { $0.event == name }
    }

    private func postStopUnitTranslationEvents() -> [PerformanceEvent] {
        guard let recordingStoppedAt else { return [] }
        return allEvents.filter {
            $0.wallTime > recordingStoppedAt && $0.event.hasPrefix("translation_unit_")
        }
    }

    private func postStopRuntimeRealtimeSnapshots() -> [PerformanceEvent] {
        guard let recordingStoppedAt else { return [] }
        return allEvents.filter {
            $0.wallTime > recordingStoppedAt
                && $0.event == "translation_runtime_snapshot"
                && $0.metadata["path"] == "realtime"
        }
    }

    private func translationRuntimeSnapshots(path: String? = nil) -> [PerformanceEvent] {
        allEvents.filter {
            $0.event == "translation_runtime_snapshot"
                && (path == nil || $0.metadata["path"] == path)
        }
    }

    private func translationRuntimeDroppedResultCount() -> Int {
        translationRuntimeSnapshots().reduce(0) { total, event in
            total + (Int(event.metadata["droppedResultCount"] ?? "") ?? 0)
        }
    }

    private func e2eTranslationValidationLines() -> [String] {
        e2eTranslationValidation().lines
    }

    private func e2eSpeakerIdentificationValidationLines() -> [String] {
        e2eSpeakerIdentificationValidation().lines
    }

    private func e2eSpeakerIdentificationValidation() -> (passed: Bool, lines: [String]) {
        let speakerCaptionEvents = realtimeSpeakerCaptionEvents()
        let scheduled = speakerIdentityEvents("speaker_identity_scheduled")
        let embeddingStarted = speakerIdentityEvents("speaker_identity_embedding_started")
        let embeddingFinished = speakerIdentityEvents("speaker_identity_embedding_finished")
        let embeddingFailed = speakerIdentityEvents("speaker_identity_embedding_failed")
        let clipUnavailable = speakerIdentityEvents("speaker_identity_clip_unavailable")
        let resolved = speakerIdentityEvents("speaker_identity_resolved")
        let labelVisible = speakerIdentityEvents("speaker_identity_label_visible")
        let firstVisibleLatency = firstSpeakerIdentityVisibleLatency()
        var failures: [String] = []

        if speakerCaptionEvents.isEmpty
            && scheduled.isEmpty
            && embeddingStarted.isEmpty
            && embeddingFinished.isEmpty
            && embeddingFailed.isEmpty
            && clipUnavailable.isEmpty
            && resolved.isEmpty
            && labelVisible.isEmpty {
            return (false, [
                "E2E Speaker Identification Status: SKIP",
                "Realtime Speaker Caption Events: 0",
                "Speaker Identity Scheduled Events: 0",
                "Speaker Identity Embedding Started Events: 0",
                "Speaker Identity Embedding Finished Events: 0",
                "Speaker Identity Embedding Failed Events: 0",
                "Speaker Identity Resolved Events: 0",
                "Speaker Identity Label Visible Events: 0",
                "First Speaker Identity Visible Latency: unavailable"
            ])
        }

        if speakerCaptionEvents.isEmpty {
            failures.append("Failure: no realtime captions with speaker IDs were visible")
        }
        if !speakerCaptionEvents.isEmpty && scheduled.isEmpty {
            failures.append("Failure: speaker captions were visible but identity was never scheduled")
        }
        if !scheduled.isEmpty && embeddingStarted.isEmpty {
            failures.append("Failure: speaker identity was scheduled but embedding never started")
        }
        if !embeddingStarted.isEmpty && embeddingFinished.isEmpty && embeddingFailed.isEmpty {
            failures.append("Failure: speaker identity embedding started but never finished or failed")
        }
        if !embeddingFailed.isEmpty {
            failures.append("Failure: speaker identity embedding failed")
        }
        if !clipUnavailable.isEmpty {
            failures.append("Failure: speaker identity audio evidence clip was unavailable")
        }
        if !embeddingFinished.isEmpty && resolved.isEmpty {
            failures.append("Failure: speaker identity embedding finished but no identity resolved")
        }
        if !resolved.isEmpty && labelVisible.isEmpty {
            failures.append("Failure: speaker identity resolved but never became visible")
        }
        if labelVisible.contains(where: { Int($0.metadata["visibleTurnCount"] ?? "0") ?? 0 <= 0 }) {
            failures.append("Failure: speaker identity visible event did not update any visible turns")
        }
        if let firstVisibleLatency,
           firstVisibleLatency > Self.firstSpeakerIdentityVisibleLatencyBudgetSeconds {
            failures.append("Failure: first speaker identity visible latency exceeded budget")
        }

        let passed = failures.isEmpty && !speakerCaptionEvents.isEmpty && !labelVisible.isEmpty
        let status = passed ? "PASS" : "FAIL"
        let lines = [
            "E2E Speaker Identification Status: \(status)",
            "Realtime Speaker Caption Events: \(speakerCaptionEvents.count)",
            "Speaker Identity Scheduled Events: \(scheduled.count)",
            "Speaker Identity Embedding Started Events: \(embeddingStarted.count)",
            "Speaker Identity Embedding Finished Events: \(embeddingFinished.count)",
            "Speaker Identity Embedding Failed Events: \(embeddingFailed.count)",
            "Speaker Identity Resolved Events: \(resolved.count)",
            "Speaker Identity Label Visible Events: \(labelVisible.count)",
            "First Speaker Identity Visible Latency: \(format(duration: firstVisibleLatency))"
        ] + failures
        return (passed, lines)
    }

    private func realtimeSpeakerCaptionEvents() -> [PerformanceEvent] {
        allEvents.filter {
            $0.event == "caption_turn_visible"
                && $0.metadata["path"] != "replay"
                && speakerIDMetadata(for: $0) != nil
        }
    }

    private func speakerIdentityEvents(_ name: String) -> [PerformanceEvent] {
        allEvents.filter { $0.event == name }
    }

    private func firstSpeakerIdentityVisibleLatency() -> Double? {
        guard let visible = speakerIdentityEvents("speaker_identity_label_visible").first else {
            return nil
        }
        let visibleSpeakerID = speakerID(for: visible)
        let sourceCaption = realtimeSpeakerCaptionEvents().first { event in
            if let visibleSpeakerID {
                return speakerID(for: event) == visibleSpeakerID
            }
            return event.wallTime <= visible.wallTime
        } ?? realtimeSpeakerCaptionEvents().first
        guard let sourceCaption else {
            return nil
        }
        return max(0, visible.wallTime.timeIntervalSince(sourceCaption.wallTime))
    }

    private func speakerID(for event: PerformanceEvent) -> String? {
        let raw = speakerIDMetadata(for: event) ?? event.segmentID
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func speakerIDMetadata(for event: PerformanceEvent) -> String? {
        let raw = event.metadata["speakerID"]
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func e2eTranslationValidation() -> (passed: Bool, lines: [String]) {
        let providerStarted = allEvents.filter { $0.event == "translation_provider_call_started" }
        let providerFinished = allEvents.filter { $0.event == "translation_provider_call_finished" }
        let providerFailed = allEvents.filter { $0.event == "translation_provider_call_failed" }
        let noProvider = allEvents.filter { $0.event == "translation_provider_unavailable" }
        let sameLanguageSkipped = allEvents.filter { $0.event == "translation_provider_skipped_same_language" }
        let overlayPublished = allEvents.filter { $0.event == "caption_translation_overlay_published" }
        let projectionMismatches = allEvents.filter { $0.event == "translation_unit_projection_mismatch" }
        let persistedProjectionMismatchCount = persistedTranslationProjectionMismatchCount()
        let firstLiveTranslationLatency = firstLiveTranslationLatencyForE2E()
        let stableCoverage = stableTranslationCoverageForE2E()
        let visibleUnitResults = allEvents.filter {
            $0.event == "translation_live_result_visible" || $0.event == "translation_stable_result_visible"
        }
        let captionVisible = allEvents.contains { $0.event == "caption_turn_visible" && $0.metadata["path"] != "replay" }
        let unitScheduled = allUnitEvents("translation_unit_live_scheduled").count
            + allUnitEvents("translation_unit_final_persisted").count
        let stablePersisted = allUnitEvents("translation_unit_final_persisted").count
        let hasVisibleTranslation = !overlayPublished.isEmpty || !visibleUnitResults.isEmpty
        let hasPersistedTranslation = stablePersisted > 0 || translationResultRecordCount > 0
        var failures: [String] = []

        if !captionVisible {
            failures.append("Failure: no realtime captions were visible")
        }
        if unitScheduled > 0 && providerStarted.isEmpty {
            failures.append("Failure: unit translations were scheduled but no provider call was observed")
        }
        if !providerStarted.isEmpty && providerFinished.isEmpty && providerFailed.isEmpty {
            failures.append("Failure: provider calls started but never finished or failed")
        }
        if providerFailed.count > 0 {
            failures.append("Failure: provider calls failed")
        }
        if noProvider.count > 0 {
            failures.append("Failure: translation provider was unavailable")
        }
        if sameLanguageSkipped.count > 0 {
            failures.append("Failure: translation skipped as same-language")
        }
        let observedTranslationActivity = unitScheduled
            + providerStarted.count
            + providerFinished.count
            + providerFailed.count
            + noProvider.count
            + sameLanguageSkipped.count
            + overlayPublished.count
            + visibleUnitResults.count
            + stablePersisted
            + translationResultRecordCount

        if observedTranslationActivity == 0 {
            let lines = [
                "E2E Translation Status: SKIPPED",
                "Reason: no translation activity observed",
                "Realtime Captions Visible: \(captionVisible ? "yes" : "no")",
                "Provider Calls Started: 0",
                "Provider Calls Finished: 0",
                "Provider Calls Failed: 0",
                "Translation Overlay Published Events: 0",
                "Visible Unit Result Events: 0",
                "Translation Result Store Records: 0"
            ]
            return (true, lines)
        }
        if let firstLiveTranslationLatency,
           firstLiveTranslationLatency > Self.firstLiveTranslationLatencyBudgetSeconds {
            failures.append("Failure: first live translation exceeded latency budget")
        }
        if let stableCoverage,
           stableCoverage < Self.minimumStableTranslationCoveragePercent {
            failures.append("Failure: stable translations did not cover realtime final caption turns")
        }
        if stableUnitDuplicatePersistCount() > 0 {
            failures.append("Failure: duplicate stable translation persistence detected")
        }
        if projectionMismatches.count > 0 {
            failures.append("Failure: stable translation projection mismatched visible caption turns")
        }
        if persistedProjectionMismatchCount > 0 {
            failures.append("Failure: persisted translations do not match visible caption turn boundaries")
        }
        if postStopRuntimeRealtimeSnapshots().count > 0 {
            failures.append("Failure: realtime translation snapshots were published after stop")
        }

        let passed = failures.isEmpty && captionVisible && (hasVisibleTranslation || hasPersistedTranslation)
        let status = passed ? "PASS" : "FAIL"
        let lines = [
            "E2E Translation Status: \(status)",
            "Realtime Captions Visible: \(captionVisible ? "yes" : "no")",
            "Provider Calls Started: \(providerStarted.count)",
            "Provider Calls Finished: \(providerFinished.count)",
            "Provider Calls Failed: \(providerFailed.count)",
            "Provider Unavailable Events: \(noProvider.count)",
            "Same-Language Skip Events: \(sameLanguageSkipped.count)",
            "Translation Overlay Published Events: \(overlayPublished.count)",
            "Visible Unit Result Events: \(visibleUnitResults.count)",
            "First Live Translation Latency: \(format(duration: firstLiveTranslationLatency))",
            "Stable Translation Coverage: \(format(percent: stableCoverage))",
            "Translation Projection Mismatch Events: \(projectionMismatches.count)",
            "Persisted Translation Projection Mismatches: \(persistedProjectionMismatchCount)",
            "Translation Result Store Records: \(translationResultRecordCount)"
        ] + failures
        return (passed, lines)
    }

    private func firstLiveTranslationLatencyForE2E() -> Double? {
        guard let firstAudioSent = firstAudioSent?.wallTime,
              let firstLive = allEvents.first(where: { $0.event == "translation_live_result_visible" })?.wallTime
        else {
            return nil
        }
        return max(0, firstLive.timeIntervalSince(firstAudioSent))
    }

    private func stableTranslationCoverageForE2E() -> Double? {
        let finalCaptionSourceIDSets = Set(primaryFinalCaptionVisibleEvents.compactMap { event -> String? in
            guard let value = event.metadata["sourceSegmentIDs"] ?? event.segmentID,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return nil
            }
            return canonicalSourceSegmentIDSet(value.split(separator: ",").map(String.init))
        })
        guard !finalCaptionSourceIDSets.isEmpty else {
            return nil
        }
        let translatedSourceIDSets = stableTranslationSourceIDSetsForE2E()
        let covered = finalCaptionSourceIDSets.filter(translatedSourceIDSets.contains).count
        return Double(covered) / Double(finalCaptionSourceIDSets.count) * 100
    }

    private func stableTranslationSourceIDSetsForE2E() -> Set<String> {
        var translated = Set<String>()
        for event in allEvents where event.event == "translation_unit_final_persisted" || event.event == "translation_stable_result_visible" {
            guard let value = event.metadata["sourceSegmentIDs"],
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                continue
            }
            translated.insert(canonicalSourceSegmentIDSet(value.split(separator: ",").map(String.init)))
        }
        for record in translationResultRecords {
            guard !record.sourceSegmentIDs.isEmpty,
                  record.translatedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            else {
                continue
            }
            translated.insert(canonicalSourceSegmentIDSet(record.sourceSegmentIDs))
        }
        return translated
    }

    private func persistedTranslationProjectionMismatchCount() -> Int {
        let visibleTurnSourceIDSets = Set(allEvents.compactMap { event -> String? in
            guard event.event == "caption_turn_visible",
                  event.metadata["path"] != "replay",
                  let value = event.metadata["sourceSegmentIDs"] ?? event.segmentID,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return nil
            }
            return canonicalSourceSegmentIDSet(value.split(separator: ",").map(String.init))
        })
        guard !visibleTurnSourceIDSets.isEmpty else {
            return 0
        }
        return translationResultRecords.filter { record in
            guard !record.sourceSegmentIDs.isEmpty,
                  record.translatedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            else {
                return false
            }
            return !visibleTurnSourceIDSets.contains(canonicalSourceSegmentIDSet(record.sourceSegmentIDs))
        }.count
    }

    private func canonicalSourceSegmentIDSet(_ ids: [String]) -> String {
        ids
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
            .joined(separator: ",")
    }

    private func uniqueStableUnitPersistedResultIDs() -> Set<String> {
        Set(allUnitEvents("translation_unit_final_persisted").compactMap { event in
            event.metadata["resultID"] ?? event.segmentID
        })
    }

    private func stableUnitDuplicatePersistCount() -> Int {
        let persisted = allUnitEvents("translation_unit_final_persisted")
        return max(0, persisted.count - uniqueStableUnitPersistedResultIDs().count)
    }

    private var draftTriggerEvents: [PerformanceEvent] {
        translationEvents("caption_translation_draft_triggered")
    }

    private var draftSkipEvents: [PerformanceEvent] {
        translationEvents("caption_translation_draft_skipped")
    }

    private var draftAttachedEvents: [PerformanceEvent] {
        translationEvents("caption_translation_attached")
            .filter { $0.metadata["translationKind"] == "draft" }
    }

    private func draftVisibilityEvents(_ name: String) -> [PerformanceEvent] {
        translationEvents(name)
            .filter { $0.metadata["translationKind"] == "draft" || $0.isFinal == false }
    }

    private func visibleTranslationEvents() -> [PerformanceEvent] {
        let explicitDraftVisibility = draftVisibilityEvents("caption_translation_exact_attached")
            + draftVisibilityEvents("caption_translation_approximate_attached")
        let legacyAttachEvents = translationEvents("caption_translation_attached")
        let finalPersistedEvents = translationEvents("caption_translation_persisted")
            .filter { $0.metadata["translationKind"] == "final" }
        return (explicitDraftVisibility + legacyAttachEvents + finalPersistedEvents)
            .sorted { $0.wallTime < $1.wallTime }
    }

    private func diagnosticLines() -> [String] {
        var lines: [String] = []
        if !batchOrFlushCaptionEvents.isEmpty {
            lines.append("Caption lag KPI protected: batch/flush visible events excluded")
        }
        if let firstRaw = events.first(where: { $0.event == "deepgram_raw_response_received" }),
           let firstAudio = firstAudioSent {
            let firstResponse = max(0, firstRaw.wallTime.timeIntervalSince(firstAudio.wallTime))
            if firstResponse >= 1.5 {
                lines.append("Primary first-caption bottleneck: Deepgram first response")
            }
        }
        if let providerLatency = translationProviderLatencyP50(), providerLatency >= 1 {
            lines.append("Primary translation bottleneck: provider latency")
        }
        let draftScheduled = translationEvents("caption_translation_scheduled")
            .filter { $0.metadata["translationKind"] == "draft" }
            .count
        let draftStale = translationEvents("caption_translation_stale")
            .filter { $0.metadata["translationKind"] == "draft" }
            .count
        if draftScheduled > 0, Double(draftStale) / Double(draftScheduled) >= 0.3 {
            lines.append("High draft stale rate: source text changes faster than translations return")
        }
        return lines
    }

    private func translationProviderLatencyP50() -> Double? {
        let requests = groupedTranslationRequests()
        let startedToFinished = requests.compactMap { duration(from: "caption_translation_started", to: "caption_translation_finished", in: $0.value) }
        return Stats(values: startedToFinished).percentile(50)
    }

    private func format(stats: Stats) -> String {
        guard stats.count > 0 else { return "unavailable" }
        return "\(format(duration: stats.percentile(50))) / \(format(duration: stats.percentile(95))) / \(format(duration: stats.max))"
    }

    private func formatP50P95(stats: Stats) -> String {
        guard stats.count > 0 else { return "unavailable" }
        return "\(format(duration: stats.percentile(50))) / \(format(duration: stats.percentile(95)))"
    }

    private func format(duration: Double?) -> String {
        guard let duration else { return "unavailable" }
        return String(format: "%.2fs", duration)
    }

    private func format(_ value: Double?) -> String {
        guard let value else { return "unavailable" }
        return String(format: "%.2f", value)
    }

    private func format(percent: Double?) -> String {
        guard let percent else { return "unavailable" }
        return String(format: "%.1f%%", percent)
    }
}
