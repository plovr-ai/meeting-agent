import XCTest

final class MeetingPerformanceAnalysisScriptTests: XCTestCase {
    func testAnalyzeMeetingPerformanceScriptReportsExperienceAndProcessMetrics() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-performance-analysis-\(UUID().uuidString)", isDirectory: true)
        let meetingDirectory = root.appendingPathComponent("meeting", isDirectory: true)
        let eventsURL = meetingDirectory.appendingPathComponent("performance-events.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: meetingDirectory, withIntermediateDirectories: true)
        try fixtureEvents().write(to: eventsURL, atomically: true, encoding: .utf8)

        let result = try runScript(arguments: [meetingDirectory.path])

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("Experience KPIs"))
        XCTAssertTrue(result.stdout.contains("Time to First Live Caption: 0.90s"))
        XCTAssertTrue(result.stdout.contains("Caption Lag p50/p95/max: 1.00s / 1.00s / 1.00s"))
        XCTAssertTrue(result.stdout.contains("Time to First Translation: 2.40s"))
        XCTAssertTrue(result.stdout.contains("Translation Lag p50/p95/max: 2.30s / 2.30s / 2.30s"))
        XCTAssertTrue(result.stdout.contains("Caption Stability: 2.00 updates/final caption"))
        XCTAssertTrue(result.stdout.contains("Translation Success Rate: 100.0%"))
        XCTAssertTrue(result.stdout.contains("Draft Translation Success Rate: unavailable"))
        XCTAssertTrue(result.stdout.contains("Final Translation Success Rate: 100.0%"))
        XCTAssertTrue(result.stdout.contains("Final Visible Attach Rate: 100.0%"))
        XCTAssertTrue(result.stdout.contains("Final Persist-Only Rate: 0.0%"))
        XCTAssertTrue(result.stdout.contains("Final True Failure Rate: 0.0%"))
        XCTAssertTrue(result.stdout.contains("Draft Translation Trigger Rate: unavailable"))
        XCTAssertTrue(result.stdout.contains("Draft Translation Skip Rate: unavailable"))
        XCTAssertTrue(result.stdout.contains("Draft Translation In-Flight Skip Count: 0"))
        XCTAssertTrue(result.stdout.contains("Draft Translation Semantic Boundary Trigger Count: 0"))
        XCTAssertTrue(result.stdout.contains("Draft Translation Max-Wait Trigger Count: 0"))
        XCTAssertTrue(result.stdout.contains("Draft Translation Stale Rate: unavailable"))
        XCTAssertTrue(result.stdout.contains("Time to First Draft Translation: unavailable"))
        XCTAssertTrue(result.stdout.contains("Draft Visible Update Interval p50/p95: unavailable"))
        XCTAssertTrue(result.stdout.contains("Process Metrics"))
        XCTAssertTrue(result.stdout.contains("First caption path: audio sent -> Deepgram response 0.60s"))
        XCTAssertTrue(result.stdout.contains("Translation path p50: scheduled -> started 0.20s"))
    }

    func testAnalyzeMeetingPerformanceScriptReportsDraftTriggerMetrics() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-performance-draft-trigger-analysis-\(UUID().uuidString)", isDirectory: true)
        let eventsURL = root.appendingPathComponent("performance-events.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try draftTriggerFixtureEvents().write(to: eventsURL, atomically: true, encoding: .utf8)

        let result = try runScript(arguments: [eventsURL.path])

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("Draft Translation Success Rate: 66.7%"))
        XCTAssertTrue(result.stdout.contains("Draft Translation Trigger Rate: 75.0%"))
        XCTAssertTrue(result.stdout.contains("Draft Translation Skip Rate: 25.0%"))
        XCTAssertTrue(result.stdout.contains("Draft Translation In-Flight Skip Count: 1"))
        XCTAssertTrue(result.stdout.contains("Draft Translation Semantic Boundary Trigger Count: 1"))
        XCTAssertTrue(result.stdout.contains("Draft Translation Max-Wait Trigger Count: 1"))
        XCTAssertTrue(result.stdout.contains("Draft Translation Stale Rate: 33.3%"))
        XCTAssertTrue(result.stdout.contains("Time to First Draft Translation: 1.50s"))
        XCTAssertTrue(result.stdout.contains("Draft Visible Update Interval p50/p95: 3.00s / 3.00s"))
    }

    func testFinalPersistedTranslationCountsAsFinalSuccess() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-performance-persisted-final-\(UUID().uuidString)", isDirectory: true)
        let eventsURL = root.appendingPathComponent("performance-events.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try [
            event("deepgram_audio_frame_sent", wallTime: "2026-05-01T00:00:00Z"),
            event("caption_turn_visible", wallTime: "2026-05-01T00:00:01Z", audio: 1, segmentID: "segment-1", isFinal: true, textLength: 12),
            event("caption_translation_scheduled", wallTime: "2026-05-01T00:00:02Z", segmentID: "turn-1", isFinal: true, textLength: 12, metadata: [
                "translationKind": "final",
                "translationRequestID": "request-1",
                "sourceSegmentID": "segment-1"
            ]),
            event("caption_translation_persisted", wallTime: "2026-05-01T00:00:03Z", segmentID: "segment-1", isFinal: true, textLength: 4, metadata: [
                "translationKind": "final",
                "translationRequestID": "request-1",
                "sourceSegmentID": "segment-1"
            ])
        ].joined(separator: "\n").appending("\n").write(to: eventsURL, atomically: true, encoding: .utf8)

        let result = try runScript(arguments: [eventsURL.path])

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("Final Translation Success Rate: 100.0%"))
        XCTAssertTrue(result.stdout.contains("Final Visible Attach Rate: 0.0%"))
        XCTAssertTrue(result.stdout.contains("Final Persist-Only Rate: 100.0%"))
        XCTAssertTrue(result.stdout.contains("Final True Failure Rate: 0.0%"))
        XCTAssertTrue(result.stdout.contains("persisted 1"))
    }

    func testAnalyzeMeetingPerformanceScriptExcludesBatchCaptionEventsFromPrimaryLag() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-performance-batch-analysis-\(UUID().uuidString)", isDirectory: true)
        let eventsURL = root.appendingPathComponent("performance-events.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try (fixtureEvents() + batchCaptionEvents()).write(to: eventsURL, atomically: true, encoding: .utf8)

        let result = try runScript(arguments: [eventsURL.path])

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("Caption Lag p50/p95/max: 1.00s / 1.00s / 1.00s"))
        XCTAssertTrue(result.stdout.contains("Batch/Flush Caption Events: 4 excluded from primary caption lag"))
        XCTAssertTrue(result.stdout.contains("Diagnostics"))
        XCTAssertTrue(result.stdout.contains("Caption lag KPI protected: batch/flush visible events excluded"))
    }

    private func runScript(arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift", "scripts/analyze-meeting-performance.swift"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)

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

    private func fixtureEvents() -> String {
        [
            event("deepgram_audio_frame_sent", wallTime: "2026-05-01T00:00:00Z", audio: 0.1, metadata: [
                "pcmBytes": "9600",
                "sampleRate": "48000",
                "channelCount": "1"
            ]),
            event("deepgram_raw_response_received", wallTime: "2026-05-01T00:00:00.600Z", audio: 0.9, isFinal: false, textLength: 5, metadata: [
                "responseStartSeconds": "0",
                "responseDurationSeconds": "0.9",
                "speechFinal": "false"
            ]),
            event("stt_segment_received", wallTime: "2026-05-01T00:00:00.700Z", audio: 0.9, segmentID: "segment-1", isFinal: false, textLength: 5),
            event("caption_turn_visible", wallTime: "2026-05-01T00:00:00.900Z", audio: 0.9, segmentID: "segment-1", isFinal: false, textLength: 5, metadata: [
                "turnID": "turn-1"
            ]),
            event("caption_turn_visible", wallTime: "2026-05-01T00:00:01.200Z", audio: 1.2, segmentID: "segment-1", isFinal: false, textLength: 11, metadata: [
                "turnID": "turn-1"
            ]),
            event("caption_turn_visible", wallTime: "2026-05-01T00:00:02.000Z", audio: 1.0, segmentID: "segment-1", isFinal: true, textLength: 11, metadata: [
                "turnID": "turn-1"
            ]),
            event("caption_translation_scheduled", wallTime: "2026-05-01T00:00:02.100Z", segmentID: "turn-1", isFinal: true, textLength: 11, metadata: [
                "translationRequestID": "translation-1",
                "translationKind": "final"
            ]),
            event("caption_translation_started", wallTime: "2026-05-01T00:00:02.300Z", segmentID: "turn-1", isFinal: true, textLength: 11, metadata: [
                "translationRequestID": "translation-1",
                "translationKind": "final"
            ]),
            event("caption_translation_finished", wallTime: "2026-05-01T00:00:03.100Z", segmentID: "turn-1", isFinal: true, textLength: 11, metadata: [
                "translationRequestID": "translation-1",
                "translationKind": "final"
            ]),
            event("caption_translation_attached", wallTime: "2026-05-01T00:00:03.300Z", segmentID: "turn-1", isFinal: true, textLength: 4, metadata: [
                "translationRequestID": "translation-1",
                "translationKind": "final",
                "sourceSegmentID": "segment-1"
            ])
        ].joined(separator: "\n") + "\n"
    }

    private func batchCaptionEvents() -> String {
        (0..<4).map { index in
            event(
                "caption_turn_visible",
                wallTime: "2026-05-01T00:03:00Z",
                audio: Double(index + 1),
                segmentID: "batch-\(index)",
                isFinal: true,
                textLength: 20,
                metadata: [
                    "turnID": "batch-\(index)",
                    "captionState": "sealed",
                    "boundaryStrength": "soft"
                ]
            )
        }.joined(separator: "\n") + "\n"
    }

    private func draftTriggerFixtureEvents() -> String {
        [
            event("deepgram_audio_frame_sent", wallTime: "2026-05-01T00:00:00Z"),
            event("caption_turn_visible", wallTime: "2026-05-01T00:00:00.500Z", segmentID: "segment-1", isFinal: false, textLength: 10, metadata: [
                "turnID": "turn-1"
            ]),
            event("caption_translation_draft_triggered", wallTime: "2026-05-01T00:00:01.000Z", segmentID: "turn-1", isFinal: false, textLength: 10, metadata: [
                "reason": "initial",
                "wordDelta": "2",
                "characterDelta": "10",
                "hasSemanticBoundary": "false"
            ]),
            event("caption_translation_scheduled", wallTime: "2026-05-01T00:00:01.100Z", segmentID: "turn-1", isFinal: false, textLength: 10, metadata: [
                "translationKind": "draft",
                "translationRequestID": "translation-draft-1"
            ]),
            event("caption_translation_attached", wallTime: "2026-05-01T00:00:02.000Z", segmentID: "turn-1", isFinal: false, textLength: 4, metadata: [
                "translationKind": "draft",
                "translationRequestID": "translation-draft-1"
            ]),
            event("caption_translation_draft_triggered", wallTime: "2026-05-01T00:00:03.000Z", segmentID: "turn-1", isFinal: false, textLength: 20, metadata: [
                "reason": "semantic_boundary",
                "wordDelta": "3",
                "characterDelta": "10",
                "hasSemanticBoundary": "true"
            ]),
            event("caption_translation_scheduled", wallTime: "2026-05-01T00:00:03.100Z", segmentID: "turn-1", isFinal: false, textLength: 20, metadata: [
                "translationKind": "draft",
                "translationRequestID": "translation-draft-2"
            ]),
            event("caption_translation_stale", wallTime: "2026-05-01T00:00:04.000Z", segmentID: "turn-1", isFinal: false, textLength: 20, metadata: [
                "translationKind": "draft",
                "translationRequestID": "translation-draft-2",
                "reason": "draft_no_longer_current"
            ]),
            event("caption_translation_draft_skipped", wallTime: "2026-05-01T00:00:04.200Z", segmentID: "turn-1", isFinal: false, textLength: 22, metadata: [
                "reason": "in_flight",
                "wordDelta": "1",
                "characterDelta": "2",
                "hasSemanticBoundary": "false"
            ]),
            event("caption_translation_draft_triggered", wallTime: "2026-05-01T00:00:04.800Z", segmentID: "turn-1", isFinal: false, textLength: 24, metadata: [
                "reason": "max_wait",
                "wordDelta": "1",
                "characterDelta": "4",
                "hasSemanticBoundary": "false"
            ]),
            event("caption_translation_scheduled", wallTime: "2026-05-01T00:00:04.900Z", segmentID: "turn-1", isFinal: false, textLength: 24, metadata: [
                "translationKind": "draft",
                "translationRequestID": "translation-draft-3"
            ]),
            event("caption_translation_attached", wallTime: "2026-05-01T00:00:05.000Z", segmentID: "turn-1", isFinal: false, textLength: 5, metadata: [
                "translationKind": "draft",
                "translationRequestID": "translation-draft-3"
            ])
        ].joined(separator: "\n") + "\n"
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
        var fields: [String] = [
            #""event":"\#(name)""#,
            #""wallTime":"\#(wallTime)""#,
            #""metadata":\#(metadataJSON(metadata))"#
        ]
        if let audio {
            fields.append(#""audioTimeSeconds":\#(audio)"#)
        }
        if let segmentID {
            fields.append(#""segmentID":"\#(segmentID)""#)
        }
        if let isFinal {
            fields.append(#""isFinal":\#(isFinal)"#)
        }
        if let textLength {
            fields.append(#""textLength":\#(textLength)"#)
        }
        return "{\(fields.joined(separator: ","))}"
    }

    private func metadataJSON(_ metadata: [String: String]) -> String {
        let pairs = metadata
            .sorted { $0.key < $1.key }
            .map { #""\#($0.key)":"\#($0.value)""# }
        return "{\(pairs.joined(separator: ","))}"
    }
}
