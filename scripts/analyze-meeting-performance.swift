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
    fputs("Usage: swift scripts/analyze-meeting-performance.swift <meeting-directory|performance-events.jsonl>\n", stderr)
    exit(2)
}

guard CommandLine.arguments.count == 2 else {
    usage()
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let eventsURL: URL
var isDirectory: ObjCBool = false
guard FileManager.default.fileExists(atPath: inputURL.path, isDirectory: &isDirectory) else {
    fputs("Input does not exist: \(inputURL.path)\n", stderr)
    exit(2)
}
if isDirectory.boolValue {
    eventsURL = inputURL.appendingPathComponent("performance-events.jsonl")
} else {
    eventsURL = inputURL
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

let analyzer = MeetingPerformanceAnalyzer(events: events)
print(analyzer.report(inputPath: eventsURL.path))

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

struct MeetingPerformanceAnalyzer {
    let allEvents: [PerformanceEvent]
    private let events: [PerformanceEvent]
    private let recordingStartedAt: Date?
    private let recordingStoppedAt: Date?

    init(events allEvents: [PerformanceEvent]) {
        self.allEvents = allEvents
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

    private func replayOverheadLines() -> [String] {
        let replayCaptionVisible = allEvents.filter {
            $0.event == "caption_turn_visible" && $0.metadata["path"] == "replay"
        }.count
        let postStopTranslation = allEvents.filter { event in
            guard let recordingStoppedAt else { return false }
            return event.wallTime > recordingStoppedAt
                && event.event.hasPrefix("caption_translation_")
        }.count
        guard replayCaptionVisible > 0 || postStopTranslation > 0 else {
            return []
        }
        return [
            "Replay Caption Visible Events: \(replayCaptionVisible)",
            "Post-Stop Translation Events: \(postStopTranslation)"
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
