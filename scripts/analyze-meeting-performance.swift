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
    decoder.dateDecodingStrategy = .iso8601
    let content = try String(contentsOf: url, encoding: .utf8)
    return try content
        .split(whereSeparator: \.isNewline)
        .map { try decoder.decode(PerformanceEvent.self, from: Data($0.utf8)) }
        .sorted { $0.wallTime < $1.wallTime }
}

struct MeetingPerformanceAnalyzer {
    let events: [PerformanceEvent]

    func report(inputPath: String) -> String {
        var lines: [String] = []
        lines.append("Meeting Performance Report")
        lines.append("Input: \(inputPath)")
        lines.append("Events: \(events.count)")
        lines.append("")
        lines.append("Experience KPIs")
        lines.append("TTFLC: \(format(duration: timeToFirstLiveCaption()))")
        lines.append("Caption Lag p50/p95/max: \(format(stats: captionLagStats()))")
        lines.append("TTFT: \(format(duration: timeToFirstTranslation()))")
        lines.append("Translation Lag p50/p95/max: \(format(stats: translationLagStats()))")
        lines.append("Caption Stability: \(format(updatesPerFinalCaption())) updates/final caption")
        lines.append("Translation Success Rate: \(format(percent: translationSuccessRate()))")
        lines.append("")
        lines.append("Process Metrics")
        lines.append("First caption path: \(firstCaptionPathText())")
        lines.append("Caption visible lag p50/p95/max: \(format(stats: captionVisiblePipelineStats()))")
        lines.append("Translation path p50: \(translationPathText())")
        lines.append("Translation outcomes: scheduled \(translationEvents("caption_translation_scheduled").count), attached \(translationEvents("caption_translation_attached").count), stale \(translationEvents("caption_translation_stale").count), cancelled \(translationEvents("caption_translation_cancelled").count), provider_error \(translationEvents("caption_translation_provider_error").count)")
        return lines.joined(separator: "\n")
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

    private func timeToFirstLiveCaption() -> Double? {
        guard let start = firstAudioSent?.wallTime,
              let caption = firstCaptionVisible?.wallTime else {
            return nil
        }
        return max(0, caption.timeIntervalSince(start))
    }

    private func captionLagStats() -> Stats {
        Stats(values: finalCaptionVisibleEvents.compactMap(audioLag))
    }

    private func captionVisiblePipelineStats() -> Stats {
        let sttBySegmentID = Dictionary(grouping: events.filter { $0.event == "stt_segment_received" }) { $0.segmentID ?? "" }
        let values = finalCaptionVisibleEvents.compactMap { caption -> Double? in
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
        let finalCaptionBySegmentID = Dictionary(grouping: finalCaptionVisibleEvents) { $0.segmentID ?? "" }
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
        let finalCount = max(1, finalCaptionVisibleEvents.count)
        let draftCount = events.filter { $0.event == "caption_turn_visible" && $0.isFinal == false }.count
        return Double(draftCount) / Double(finalCount)
    }

    private func translationSuccessRate() -> Double? {
        let scheduled = translationEvents("caption_translation_scheduled").count
        guard scheduled > 0 else { return nil }
        let attached = translationEvents("caption_translation_attached").count
        return Double(attached) / Double(scheduled) * 100
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

    private func format(stats: Stats) -> String {
        guard stats.count > 0 else { return "unavailable" }
        return "\(format(duration: stats.percentile(50))) / \(format(duration: stats.percentile(95))) / \(format(duration: stats.max))"
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
