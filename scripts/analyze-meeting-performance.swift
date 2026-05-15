#!/usr/bin/env swift
import Foundation

struct PerformanceEvent: Decodable {
    var event: String
    var wallTime: Date?
    var audioTime: Double?
    var segmentID: String?
    var isFinal: Bool?
    var metadata: [String: String]?

    enum CodingKeys: String, CodingKey {
        case event
        case wallTime
        case audioTime
        case audioTimeSeconds
        case segmentID
        case isFinal
        case metadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        event = try container.decode(String.self, forKey: .event)
        wallTime = try container.decodeIfPresent(String.self, forKey: .wallTime).flatMap(parseISO8601Date)
        audioTime = try container.decodeIfPresent(Double.self, forKey: .audioTime)
            ?? container.decodeIfPresent(Double.self, forKey: .audioTimeSeconds)
        segmentID = try container.decodeIfPresent(String.self, forKey: .segmentID)
        isFinal = try container.decodeIfPresent(Bool.self, forKey: .isFinal)
        metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata)
    }
}

struct Stats {
    var values: [Double]

    var isEmpty: Bool { values.isEmpty }

    func percentile(_ fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * fraction).rounded())))
        return sorted[index]
    }
}

let arguments = CommandLine.arguments.dropFirst()
guard let inputPath = arguments.first else {
    fputs("Usage: scripts/analyze-meeting-performance.swift <meeting-dir-or-performance-events.jsonl>\n", stderr)
    exit(2)
}

let inputURL = URL(fileURLWithPath: inputPath)
let eventsURL: URL
if inputURL.pathExtension == "jsonl" {
    eventsURL = inputURL
} else {
    eventsURL = inputURL.appendingPathComponent("performance-events.jsonl")
}

let fractionalSecondsDateFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

let wholeSecondsDateFormatter = ISO8601DateFormatter()

func parseISO8601Date(_ value: String) -> Date? {
    fractionalSecondsDateFormatter.date(from: value) ?? wholeSecondsDateFormatter.date(from: value)
}

let decoder = JSONDecoder()

let events: [PerformanceEvent]
do {
    let lines = try String(contentsOf: eventsURL, encoding: .utf8)
        .split(separator: "\n")
        .map(String.init)
    events = lines.compactMap { line in
        try? decoder.decode(PerformanceEvent.self, from: Data(line.utf8))
    }
} catch {
    fputs("Failed to read performance events at \(eventsURL.path): \(error)\n", stderr)
    exit(2)
}

func format(duration: Double?) -> String {
    guard let duration else { return "unavailable" }
    return String(format: "%.2fs", duration)
}

func format(percent: Double?) -> String {
    guard let percent else { return "unavailable" }
    return String(format: "%.1f%%", percent)
}

func format(stats: Stats) -> String {
    guard !stats.isEmpty else { return "unavailable" }
    return "\(format(duration: stats.percentile(0.5))) / \(format(duration: stats.percentile(0.95))) / \(format(duration: stats.percentile(1.0)))"
}

func metadata(_ event: PerformanceEvent, _ key: String) -> String? {
    event.metadata?[key]
}

let recordingStartedAt = events.first { $0.event == "recording_started" }?.wallTime
let recordingStoppedAt = events.first { $0.event == "recording_stopped" }?.wallTime
let audioSentEvents = events.filter { $0.event == "deepgram_audio_frame_sent" }
let captionEvents = events.filter { $0.event == "caption_turn_visible" || $0.event == "caption_final_visible" }
let realtimeCaptionEvents = captionEvents.filter { metadata($0, "path") != "replay" && metadata($0, "path") != "batch" && metadata($0, "path") != "flush" }
let finalRealtimeCaptionEvents = realtimeCaptionEvents.filter { $0.isFinal == true }
let batchCaptionCount = captionEvents.filter {
    metadata($0, "path") == "batch" || metadata($0, "path") == "flush"
}.count
let replayCaptionCount = captionEvents.filter { metadata($0, "path") == "replay" }.count

func timeToFirstLiveCaption() -> Double? {
    guard let firstAudio = audioSentEvents.first?.wallTime,
          let firstCaption = realtimeCaptionEvents.first?.wallTime else {
        return nil
    }
    return firstCaption.timeIntervalSince(firstAudio)
}

func captionLagStats() -> Stats {
    let values = realtimeCaptionEvents.compactMap { event -> Double? in
        guard let wallTime = event.wallTime,
              let audioTime = event.audioTime,
              let recordingStartedAt else {
            return nil
        }
        return wallTime.timeIntervalSince(recordingStartedAt) - audioTime
    }
    return Stats(values: values)
}

func captionStability() -> Double? {
    let finalIDs = Set(finalRealtimeCaptionEvents.compactMap(\.segmentID))
    guard !finalIDs.isEmpty else { return nil }
    return Double(realtimeCaptionEvents.count) / Double(finalIDs.count)
}

func captionFinalRate() -> Double? {
    guard !realtimeCaptionEvents.isEmpty else { return nil }
    return Double(finalRealtimeCaptionEvents.count) / Double(realtimeCaptionEvents.count) * 100
}

func postStopCaptionCount() -> Int {
    guard let recordingStoppedAt else { return 0 }
    return captionEvents.filter { event in
        guard let wallTime = event.wallTime else { return false }
        return wallTime > recordingStoppedAt
    }.count
}

var lines: [String] = []
lines.append("Experience KPIs")
lines.append("Time to First Live Caption: \(format(duration: timeToFirstLiveCaption()))")
lines.append("Caption Lag p50/p95/max: \(format(stats: captionLagStats()))")
if let stability = captionStability() {
    lines.append(String(format: "Caption Stability: %.2f updates/final caption", stability))
} else {
    lines.append("Caption Stability: unavailable")
}
lines.append("Final Caption Rate: \(format(percent: captionFinalRate()))")
lines.append("")
lines.append("Process Metrics")
lines.append("Live Caption Visible Events: \(realtimeCaptionEvents.count)")
lines.append("Final Caption Visible Events: \(finalRealtimeCaptionEvents.count)")
if batchCaptionCount > 0 {
    lines.append("Batch/Flush Caption Events: \(batchCaptionCount) excluded from primary caption lag")
}
lines.append("")
lines.append("Replay / Idle Overhead")
lines.append("Replay Caption Visible Events: \(replayCaptionCount)")
lines.append("Post-Stop Caption Events: \(postStopCaptionCount())")

var failures: [String] = []
if realtimeCaptionEvents.isEmpty {
    failures.append("no realtime caption events found")
}
if finalRealtimeCaptionEvents.isEmpty {
    failures.append("no final realtime caption events found")
}

if !failures.isEmpty {
    lines.append("")
    for failure in failures {
        lines.append("Failure: \(failure)")
    }
}

print(lines.joined(separator: "\n"))
exit(failures.isEmpty ? 0 : 1)
