import XCTest

final class MeetingPerformanceAnalysisScriptTests: XCTestCase {
    func testAnalyzeMeetingPerformanceScriptReportsCaptionOnlyMetrics() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-performance-analysis-\(UUID().uuidString)", isDirectory: true)
        let meetingDirectory = root.appendingPathComponent("meeting", isDirectory: true)
        let eventsURL = meetingDirectory.appendingPathComponent("performance-events.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: meetingDirectory, withIntermediateDirectories: true)
        try [
            event("recording_started", wallTime: "2026-05-01T00:00:00Z"),
            event("deepgram_audio_frame_sent", wallTime: "2026-05-01T00:00:00Z"),
            event("caption_turn_visible", wallTime: "2026-05-01T00:00:00.900Z", audio: 0.1, segmentID: "turn-1", isFinal: false, textLength: 8, metadata: [
                "path": "realtime"
            ]),
            event("caption_turn_visible", wallTime: "2026-05-01T00:00:02.000Z", audio: 1.0, segmentID: "turn-1", isFinal: true, textLength: 20, metadata: [
                "path": "realtime"
            ]),
            event("caption_turn_visible", wallTime: "2026-05-01T00:00:03.000Z", audio: 2.0, segmentID: "turn-2", isFinal: true, textLength: 12, metadata: [
                "path": "realtime"
            ])
        ].joined(separator: "\n").appending("\n").write(to: eventsURL, atomically: true, encoding: .utf8)

        let result = try runScript(arguments: [meetingDirectory.path])

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("Experience KPIs"))
        XCTAssertTrue(result.stdout.contains("Time to First Live Caption: 0.90s"))
        XCTAssertTrue(result.stdout.contains("Caption Lag p50/p95/max: 1.00s / 1.00s / 1.00s"))
        XCTAssertTrue(result.stdout.contains("Caption Stability: 1.50 updates/final caption"))
        XCTAssertTrue(result.stdout.contains("Final Caption Rate: 66.7%"))
        XCTAssertFalse(result.stdout.contains("Translation"))
    }

    func testAnalyzeMeetingPerformanceScriptExcludesBatchAndReplayCaptionEvents() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-performance-replay-analysis-\(UUID().uuidString)", isDirectory: true)
        let eventsURL = root.appendingPathComponent("performance-events.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try [
            event("recording_started", wallTime: "2026-05-01T00:00:00Z"),
            event("deepgram_audio_frame_sent", wallTime: "2026-05-01T00:00:00Z"),
            event("caption_turn_visible", wallTime: "2026-05-01T00:00:01Z", audio: 1, segmentID: "turn-1", isFinal: true, textLength: 12, metadata: [
                "path": "realtime"
            ]),
            event("recording_stopped", wallTime: "2026-05-01T00:00:02Z"),
            event("caption_turn_visible", wallTime: "2026-05-01T00:00:03Z", audio: 1, segmentID: "turn-1", isFinal: true, textLength: 12, metadata: [
                "path": "replay"
            ]),
            event("caption_turn_visible", wallTime: "2026-05-01T00:00:04Z", audio: 4, segmentID: "batch-1", isFinal: true, textLength: 18, metadata: [
                "path": "batch"
            ])
        ].joined(separator: "\n").appending("\n").write(to: eventsURL, atomically: true, encoding: .utf8)

        let result = try runScript(arguments: [eventsURL.path])

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("Live Caption Visible Events: 1"))
        XCTAssertTrue(result.stdout.contains("Batch/Flush Caption Events: 1 excluded from primary caption lag"))
        XCTAssertTrue(result.stdout.contains("Replay Caption Visible Events: 1"))
        XCTAssertTrue(result.stdout.contains("Post-Stop Caption Events: 2"))
    }

    func testAnalyzeMeetingPerformanceScriptFailsWithoutRealtimeCaptions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-performance-empty-\(UUID().uuidString)", isDirectory: true)
        let eventsURL = root.appendingPathComponent("performance-events.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try event("recording_started", wallTime: "2026-05-01T00:00:00Z")
            .appending("\n")
            .write(to: eventsURL, atomically: true, encoding: .utf8)

        let result = try runScript(arguments: [eventsURL.path])

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stdout.contains("Failure: no realtime caption events found"))
        XCTAssertTrue(result.stdout.contains("Failure: no final realtime caption events found"))
    }

    private func runScript(arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.currentDirectoryURL = RegressionFixtureFiles.repositoryRoot
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift", "scripts/analyze-meeting-performance.swift"] + arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }

    private func event(
        _ name: String,
        wallTime: String,
        audio: Double? = nil,
        segmentID: String? = nil,
        isFinal: Bool? = nil,
        textLength: Int? = nil,
        metadata: [String: String] = [:]
    ) -> String {
        var object: [String: Any] = [
            "event": name,
            "wallTime": wallTime
        ]
        if let audio {
            object["audioTime"] = audio
        }
        if let segmentID {
            object["segmentID"] = segmentID
        }
        if let isFinal {
            object["isFinal"] = isFinal
        }
        if let textLength {
            object["textLength"] = textLength
        }
        if !metadata.isEmpty {
            object["metadata"] = metadata
        }
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }
}
