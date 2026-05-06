import XCTest

final class DeepgramReconciliationPerformanceScriptTests: XCTestCase {
    func testPerformanceScriptContainsRequiredMetrics() throws {
        let scriptURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("scripts/analyze-deepgram-reconciliation-performance.swift")
        let source = try String(contentsOf: scriptURL, encoding: .utf8)

        for metric in [
            "time_to_first_realtime_caption_seconds",
            "time_to_first_final_transcript_seconds",
            "persisted_interim_segment_count",
            "overlapping_final_audio_range_count",
            "non_overlapping_repeated_text_count",
            "final_transcript_completion_seconds"
        ] {
            XCTAssertTrue(source.contains(metric), "Missing metric: \(metric)")
        }
    }
}
