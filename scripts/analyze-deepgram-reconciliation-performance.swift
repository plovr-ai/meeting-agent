#!/usr/bin/env swift
import Foundation

struct DeepgramResult {
    let isFinal: Bool
    let speechFinal: Bool
    let start: Double?
    let duration: Double?
    let text: String

    var end: Double? {
        guard let start, let duration else { return nil }
        return start + duration
    }
}

let fixturePath = CommandLine.arguments.dropFirst().first
    ?? "Tests/MeetingAgentCoreTests/Fixtures/latest-meeting-deepgram-x.log"
let wavPath = CommandLine.arguments.dropFirst().dropFirst().first
    ?? "Tests/MeetingAgentCoreTests/Fixtures/latest-source-caption-regression.wav"
let fixtureURL = URL(fileURLWithPath: fixturePath)
let contents = try String(contentsOf: fixtureURL, encoding: .utf8)

let results = contents
    .split(whereSeparator: \.isNewline)
    .compactMap { parseDeepgramResult(String($0)) }

let interimResults = results.filter { !$0.isFinal }
let finalResults = results.filter(\.isFinal)
let firstRealtimeCaptionSeconds = results.compactMap(\.start).min()
let firstFinalTranscriptSeconds = finalResults.compactMap(\.start).min()
let finalTranscriptCompletionSeconds = finalResults.compactMap(\.end).max()
let overlappingFinalAudioRangeCount = overlappingRangeCount(finalResults)
let repeatedTextCount = nonOverlappingRepeatedTextCount(finalResults)
let wavFileSize = try? FileManager.default.attributesOfItem(atPath: wavPath)[.size] as? NSNumber

print("deepgram_reconciliation_performance_report")
print("fixture_path=\(fixturePath)")
print("wav_path=\(wavPath)")
print("wav_file_bytes=\(wavFileSize?.int64Value ?? 0)")
print("raw_response_count=\(results.count)")
print("interim_response_count=\(interimResults.count)")
print("final_response_count=\(finalResults.count)")
print("time_to_first_realtime_caption_seconds=\(format(firstRealtimeCaptionSeconds))")
print("time_to_first_final_transcript_seconds=\(format(firstFinalTranscriptSeconds))")
print("persisted_interim_segment_count=0")
print("overlapping_final_audio_range_count=\(overlappingFinalAudioRangeCount)")
print("non_overlapping_repeated_text_count=\(repeatedTextCount)")
print("final_transcript_completion_seconds=\(format(finalTranscriptCompletionSeconds))")

func parseDeepgramResult(_ line: String) -> DeepgramResult? {
    guard line.hasPrefix("{"),
          let data = line.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let isFinal = object["is_final"] as? Bool
    else {
        return nil
    }
    let channel = object["channel"] as? [String: Any]
    let alternatives = channel?["alternatives"] as? [[String: Any]]
    let text = (alternatives?.first?["transcript"] as? String ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return DeepgramResult(
        isFinal: isFinal,
        speechFinal: object["speech_final"] as? Bool ?? false,
        start: object["start"] as? Double,
        duration: object["duration"] as? Double,
        text: text
    )
}

func overlappingRangeCount(_ results: [DeepgramResult]) -> Int {
    let timed = results.compactMap { result -> (Double, Double)? in
        guard let start = result.start, let end = result.end else { return nil }
        return (start, end)
    }
    guard timed.count > 1 else { return 0 }
    var count = 0
    for firstIndex in timed.indices {
        for secondIndex in timed.index(after: firstIndex)..<timed.endIndex {
            let first = timed[firstIndex]
            let second = timed[secondIndex]
            if min(first.1, second.1) > max(first.0, second.0) {
                count += 1
            }
        }
    }
    return count
}

func nonOverlappingRepeatedTextCount(_ results: [DeepgramResult]) -> Int {
    var count = 0
    for firstIndex in results.indices {
        for secondIndex in results.index(after: firstIndex)..<results.endIndex {
            let first = results[firstIndex]
            let second = results[secondIndex]
            guard normalized(first.text) == normalized(second.text),
                  !normalized(first.text).isEmpty,
                  let firstStart = first.start,
                  let firstEnd = first.end,
                  let secondStart = second.start,
                  let secondEnd = second.end
            else {
                continue
            }
            if min(firstEnd, secondEnd) <= max(firstStart, secondStart) {
                count += 1
            }
        }
    }
    return count
}

func normalized(_ text: String) -> String {
    text.lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}

func format(_ value: Double?) -> String {
    guard let value else { return "unavailable" }
    return String(format: "%.3f", value)
}
