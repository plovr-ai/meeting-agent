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

    func testAnalyzeMeetingPerformanceScriptReportsVisibleTranslationContinuityMetrics() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-performance-visible-translation-\(UUID().uuidString)", isDirectory: true)
        let eventsURL = root.appendingPathComponent("performance-events.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try visibleTranslationFixtureEvents().write(to: eventsURL, atomically: true, encoding: .utf8)

        let result = try runScript(arguments: [eventsURL.path])

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("Time to First Visible Translation: 2.00s"))
        XCTAssertTrue(result.stdout.contains("Visible Translation Coverage:"))
        XCTAssertTrue(result.stdout.contains("Visible Translation Gap p50/p95/max:"))
        XCTAssertTrue(result.stdout.contains("Exact Draft Attach Rate: 50.0%"))
        XCTAssertTrue(result.stdout.contains("Approximate Draft Attach Rate: 50.0%"))
        XCTAssertTrue(result.stdout.contains("Hidden Draft Stale Rate: 33.3%"))
        XCTAssertTrue(result.stdout.contains("Draft Translation Carry Forward Count: 1"))
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

    func testAnalyzeMeetingPerformanceScriptSeparatesReplayAndPostStopEvents() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-performance-replay-analysis-\(UUID().uuidString)", isDirectory: true)
        let eventsURL = root.appendingPathComponent("performance-events.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try [
            event("recording_started", wallTime: "2026-05-01T00:00:00Z"),
            event("deepgram_audio_frame_sent", wallTime: "2026-05-01T00:00:00Z"),
            event("caption_turn_visible", wallTime: "2026-05-01T00:00:01Z", audio: 1, segmentID: "draft-1", isFinal: false, textLength: 5, metadata: [
                "path": "realtime",
                "turnID": "turn-1"
            ]),
            event("caption_turn_visible", wallTime: "2026-05-01T00:00:02Z", audio: 2, segmentID: "final-1", isFinal: true, textLength: 12, metadata: [
                "path": "realtime",
                "turnID": "turn-1"
            ]),
            event("caption_translation_scheduled", wallTime: "2026-05-01T00:00:02.100Z", segmentID: "turn-1", isFinal: true, textLength: 12, metadata: [
                "translationKind": "final",
                "translationRequestID": "translation-1"
            ]),
            event("caption_translation_attached", wallTime: "2026-05-01T00:00:03Z", segmentID: "turn-1", isFinal: true, textLength: 4, metadata: [
                "translationKind": "final",
                "translationRequestID": "translation-1",
                "sourceSegmentID": "final-1"
            ]),
            event("recording_stopped", wallTime: "2026-05-01T00:00:04Z"),
            event("caption_turn_visible", wallTime: "2026-05-01T00:00:05Z", audio: 2, segmentID: "final-1", isFinal: true, textLength: 12, metadata: [
                "path": "replay",
                "turnID": "turn-1"
            ]),
            event("caption_turn_visible", wallTime: "2026-05-01T00:00:06Z", audio: 6, segmentID: "replay-draft", isFinal: false, textLength: 20, metadata: [
                "path": "replay",
                "turnID": "turn-replay"
            ]),
            event("caption_translation_scheduled", wallTime: "2026-05-01T00:00:07Z", segmentID: "turn-replay", isFinal: false, textLength: 20, metadata: [
                "translationKind": "draft",
                "translationRequestID": "translation-replay"
            ])
        ].joined(separator: "\n").appending("\n").write(to: eventsURL, atomically: true, encoding: .utf8)

        let result = try runScript(arguments: [eventsURL.path])

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("Caption Stability: 1.00 updates/final caption"))
        XCTAssertTrue(result.stdout.contains("Translation Success Rate: 100.0%"))
        XCTAssertTrue(result.stdout.contains("Replay / Idle Overhead"))
        XCTAssertTrue(result.stdout.contains("Replay Caption Visible Events: 2"))
        XCTAssertTrue(result.stdout.contains("Post-Stop Translation Events: 1"))
    }

    func testAnalyzeMeetingPerformanceScriptReportsTranslationExperienceV2Metrics() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-performance-translation-v2-\(UUID().uuidString)", isDirectory: true)
        let eventsURL = root.appendingPathComponent("performance-events.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try [
            event("deepgram_audio_frame_sent", wallTime: "2026-05-06T00:00:00Z", audio: 0.1),
            event("translation_live_result_visible", wallTime: "2026-05-06T00:00:02Z", segmentID: "unit-1", isFinal: false, textLength: 8, metadata: [
                "translationState": "liveFresh",
                "translationRequestID": "live-1",
                "sourceCreatedAt": "2026-05-06T00:00:01Z"
            ]),
            event("translation_live_request_started", wallTime: "2026-05-06T00:00:01Z", segmentID: "unit-1", isFinal: false, textLength: 20, metadata: [
                "translationRequestID": "live-1"
            ]),
            event("translation_stable_result_visible", wallTime: "2026-05-06T00:00:05Z", segmentID: "block-1", isFinal: true, textLength: 12, metadata: [
                "translationState": "stableFinal",
                "translationRequestID": "stable-1"
            ])
        ].joined(separator: "\n").appending("\n").write(to: eventsURL, atomically: true, encoding: .utf8)

        let result = try runScript(arguments: [eventsURL.path])

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("Translation Experience V2"))
        XCTAssertTrue(result.stdout.contains("Time to First Live Translation: 2.00s"))
        XCTAssertTrue(result.stdout.contains("Live Translation Calls: 1"))
        XCTAssertTrue(result.stdout.contains("Stable Translation Success Count: 1"))
    }

    func testAnalyzeMeetingPerformanceScriptReportsUnitTranslationPipelineMetrics() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-performance-unit-translation-\(UUID().uuidString)", isDirectory: true)
        let eventsURL = root.appendingPathComponent("performance-events.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try [
            event("recording_started", wallTime: "2026-05-06T00:00:00Z"),
            event("deepgram_audio_frame_sent", wallTime: "2026-05-06T00:00:00Z", audio: 0.1),
            event("translation_unit_live_scheduled", wallTime: "2026-05-06T00:00:01Z", segmentID: "unit-1", isFinal: false, textLength: 32, metadata: [
                "translationKind": "live",
                "sourceSegmentIDs": "segment-1"
            ]),
            event("translation_unit_live_stale", wallTime: "2026-05-06T00:00:02Z", segmentID: "unit-2", isFinal: false, textLength: 36, metadata: [
                "translationKind": "live",
                "reason": "pending_replaced",
                "sourceSegmentIDs": "segment-1"
            ]),
            event("recording_stopped", wallTime: "2026-05-06T00:00:03Z"),
            event("translation_unit_final_persisted", wallTime: "2026-05-06T00:00:04Z", segmentID: "block-1", isFinal: true, textLength: 12, metadata: [
                "translationKind": "final",
                "translationState": "stableFinal",
                "resultID": "stable-1",
                "sourceSegmentIDs": "segment-1"
            ]),
            event("translation_unit_final_persisted", wallTime: "2026-05-06T00:00:04Z", segmentID: "block-1", isFinal: true, textLength: 12, metadata: [
                "translationKind": "final",
                "translationState": "stableFinal",
                "resultID": "stable-1",
                "sourceSegmentIDs": "segment-1"
            ]),
            event("translation_preview_dropped_after_stop", wallTime: "2026-05-06T00:00:05Z", segmentID: "unit-3", isFinal: false, textLength: 0),
            event("translation_unit_live_dropped_after_stop", wallTime: "2026-05-06T00:00:06Z", segmentID: "unit-4", isFinal: false, textLength: 18, metadata: [
                "translationKind": "live"
            ]),
            event("translation_runtime_snapshot", wallTime: "2026-05-06T00:00:07Z", metadata: [
                "path": "stop",
                "state": "stopped",
                "liveResultCount": "0",
                "stableResultCount": "1",
                "visibleResultCount": "1",
                "droppedResultCount": "1"
            ]),
            event("translation_runtime_snapshot", wallTime: "2026-05-06T00:00:08Z", metadata: [
                "path": "realtime",
                "state": "active",
                "liveResultCount": "1",
                "stableResultCount": "1",
                "visibleResultCount": "1",
                "droppedResultCount": "0"
            ])
        ].joined(separator: "\n").appending("\n").write(to: eventsURL, atomically: true, encoding: .utf8)

        let result = try runScript(arguments: [eventsURL.path])

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("Unit Translation Pipeline"))
        XCTAssertTrue(result.stdout.contains("Live Unit Scheduled Count: 1"))
        XCTAssertTrue(result.stdout.contains("Live Unit Stale Count: 1"))
        XCTAssertTrue(result.stdout.contains("Live Unit Dropped After Stop Count: 1"))
        XCTAssertTrue(result.stdout.contains("Stable Unit Persisted Count: 2"))
        XCTAssertTrue(result.stdout.contains("Preview Dropped After Stop Count: 1"))
        XCTAssertTrue(result.stdout.contains("Preview Published After Stop Count: 0"))
        XCTAssertTrue(result.stdout.contains("Translation Runtime Snapshot Count: 2"))
        XCTAssertTrue(result.stdout.contains("Translation Runtime Stop Snapshot Count: 1"))
        XCTAssertTrue(result.stdout.contains("Post-Stop Runtime Realtime Snapshot Count: 1"))
        XCTAssertTrue(result.stdout.contains("Translation Runtime Dropped Result Count: 1"))
        XCTAssertTrue(result.stdout.contains("Stable Unit Unique Result Count: 1"))
        XCTAssertTrue(result.stdout.contains("Stable Unit Duplicate Persist Count: 1"))
        XCTAssertTrue(result.stdout.contains("Post-Stop Unit Translation Events: 3"))
    }

    func testAnalyzeMeetingPerformanceScriptFailsE2EValidationWhenUnitTranslationNeverCallsProvider() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-performance-e2e-missing-provider-\(UUID().uuidString)", isDirectory: true)
        let meetingDirectory = root.appendingPathComponent("meeting", isDirectory: true)
        let eventsURL = meetingDirectory.appendingPathComponent("performance-events.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: meetingDirectory, withIntermediateDirectories: true)
        try [
            event("recording_started", wallTime: "2026-05-06T00:00:00Z"),
            event("deepgram_audio_frame_sent", wallTime: "2026-05-06T00:00:00Z", audio: 0),
            event("caption_turn_visible", wallTime: "2026-05-06T00:00:01Z", audio: 1, segmentID: "segment-1", isFinal: false, textLength: 48, metadata: [
                "path": "realtime",
                "turnID": "turn-1"
            ]),
            event("translation_runtime_snapshot", wallTime: "2026-05-06T00:00:01.100Z", metadata: [
                "path": "realtime",
                "state": "active",
                "liveResultCount": "0",
                "stableResultCount": "0",
                "visibleResultCount": "0",
                "droppedResultCount": "0"
            ]),
            event("translation_unit_live_scheduled", wallTime: "2026-05-06T00:00:01.200Z", segmentID: "segment-1-live-1", isFinal: false, textLength: 42, metadata: [
                "translationKind": "live",
                "sourceSegmentIDs": "segment-1"
            ]),
            event("recording_stopped", wallTime: "2026-05-06T00:00:03Z"),
            event("translation_runtime_snapshot", wallTime: "2026-05-06T00:00:03.100Z", metadata: [
                "path": "stop",
                "state": "stopped",
                "liveResultCount": "0",
                "stableResultCount": "0",
                "visibleResultCount": "0",
                "droppedResultCount": "0"
            ])
        ].joined(separator: "\n").appending("\n").write(to: eventsURL, atomically: true, encoding: .utf8)

        let result = try runScript(arguments: [meetingDirectory.path])

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("End-to-End Translation Validation"))
        XCTAssertTrue(result.stdout.contains("E2E Translation Status: FAIL"))
        XCTAssertTrue(result.stdout.contains("Provider Calls Started: 0"))
        XCTAssertTrue(result.stdout.contains("Provider Calls Finished: 0"))
        XCTAssertTrue(result.stdout.contains("Translation Result Store Records: 0"))
        XCTAssertTrue(result.stdout.contains("Failure: unit translations were scheduled but no provider call was observed"))
    }

    func testAnalyzeMeetingPerformanceScriptPassesE2EValidationWhenProviderOverlayAndStoreSucceed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-performance-e2e-pass-\(UUID().uuidString)", isDirectory: true)
        let meetingDirectory = root.appendingPathComponent("meeting", isDirectory: true)
        let eventsURL = meetingDirectory.appendingPathComponent("performance-events.jsonl")
        let resultsURL = meetingDirectory.appendingPathComponent("translation-results.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: meetingDirectory, withIntermediateDirectories: true)
        try [
            event("recording_started", wallTime: "2026-05-06T00:00:00Z"),
            event("deepgram_audio_frame_sent", wallTime: "2026-05-06T00:00:00Z", audio: 0),
            event("caption_turn_visible", wallTime: "2026-05-06T00:00:01Z", audio: 1, segmentID: "segment-1", isFinal: false, textLength: 48, metadata: [
                "path": "realtime",
                "turnID": "turn-1"
            ]),
            event("translation_unit_live_scheduled", wallTime: "2026-05-06T00:00:01.100Z", segmentID: "segment-1-live-1", isFinal: false, textLength: 42, metadata: [
                "translationKind": "live",
                "sourceSegmentIDs": "segment-1"
            ]),
            event("translation_provider_call_started", wallTime: "2026-05-06T00:00:01.200Z", segmentID: "segment-1-live-1", isFinal: false, textLength: 42, metadata: [
                "translationKind": "live",
                "providerID": "test-provider",
                "sourceSegmentIDs": "segment-1"
            ]),
            event("translation_provider_call_finished", wallTime: "2026-05-06T00:00:01.800Z", segmentID: "segment-1-live-1", isFinal: false, textLength: 12, metadata: [
                "translationKind": "live",
                "providerID": "test-provider",
                "sourceSegmentIDs": "segment-1"
            ]),
            event("translation_live_result_visible", wallTime: "2026-05-06T00:00:01.900Z", segmentID: "segment-1-live-1", isFinal: false, textLength: 12, metadata: [
                "translationState": "liveFresh",
                "sourceSegmentIDs": "segment-1"
            ]),
            event("caption_translation_overlay_published", wallTime: "2026-05-06T00:00:02Z", segmentID: "segment-1", isFinal: false, textLength: 12, metadata: [
                "path": "realtime"
            ]),
            event("translation_unit_final_persisted", wallTime: "2026-05-06T00:00:03Z", segmentID: "stable-1", isFinal: true, textLength: 12, metadata: [
                "translationKind": "final",
                "translationState": "stableFinal",
                "resultID": "stable-1-result",
                "sourceSegmentIDs": "segment-1"
            ]),
            event("recording_stopped", wallTime: "2026-05-06T00:00:04Z")
        ].joined(separator: "\n").appending("\n").write(to: eventsURL, atomically: true, encoding: .utf8)
        try #"{"resultID":"stable-1-result","translatedText":"通过"}"#.appending("\n")
            .write(to: resultsURL, atomically: true, encoding: .utf8)

        let result = try runScript(arguments: [meetingDirectory.path])

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("E2E Translation Status: PASS"))
        XCTAssertTrue(result.stdout.contains("Provider Calls Started: 1"))
        XCTAssertTrue(result.stdout.contains("Provider Calls Finished: 1"))
        XCTAssertTrue(result.stdout.contains("Translation Overlay Published Events: 1"))
        XCTAssertTrue(result.stdout.contains("Translation Result Store Records: 1"))
        XCTAssertFalse(result.stdout.contains("Failure:"))
    }

    func testAnalyzeMeetingPerformanceScriptFailsE2EValidationForSlowFirstTranslationAndLowCoverage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-performance-e2e-slow-low-coverage-\(UUID().uuidString)", isDirectory: true)
        let meetingDirectory = root.appendingPathComponent("meeting", isDirectory: true)
        let eventsURL = meetingDirectory.appendingPathComponent("performance-events.jsonl")
        let resultsURL = meetingDirectory.appendingPathComponent("translation-results.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: meetingDirectory, withIntermediateDirectories: true)
        try [
            event("recording_started", wallTime: "2026-05-06T00:00:00Z"),
            event("deepgram_audio_frame_sent", wallTime: "2026-05-06T00:00:00Z", audio: 0),
            event("caption_turn_visible", wallTime: "2026-05-06T00:00:01Z", audio: 1, segmentID: "segment-1", isFinal: true, textLength: 48, metadata: [
                "path": "realtime",
                "turnID": "turn-1",
                "sourceSegmentIDs": "segment-1"
            ]),
            event("caption_turn_visible", wallTime: "2026-05-06T00:00:03Z", audio: 3, segmentID: "segment-2", isFinal: true, textLength: 46, metadata: [
                "path": "realtime",
                "turnID": "turn-2",
                "sourceSegmentIDs": "segment-2"
            ]),
            event("caption_turn_visible", wallTime: "2026-05-06T00:00:05Z", audio: 5, segmentID: "segment-3", isFinal: true, textLength: 44, metadata: [
                "path": "realtime",
                "turnID": "turn-3",
                "sourceSegmentIDs": "segment-3"
            ]),
            event("translation_unit_live_scheduled", wallTime: "2026-05-06T00:00:01.200Z", segmentID: "segment-1-live-1", isFinal: false, textLength: 42, metadata: [
                "translationKind": "live",
                "sourceSegmentIDs": "segment-1"
            ]),
            event("translation_provider_call_started", wallTime: "2026-05-06T00:00:01.300Z", segmentID: "segment-1-live-1", isFinal: false, textLength: 42, metadata: [
                "translationKind": "live",
                "sourceSegmentIDs": "segment-1"
            ]),
            event("translation_provider_call_finished", wallTime: "2026-05-06T00:00:08.000Z", segmentID: "segment-1-live-1", isFinal: false, textLength: 12, metadata: [
                "translationKind": "live",
                "sourceSegmentIDs": "segment-1"
            ]),
            event("translation_live_result_visible", wallTime: "2026-05-06T00:00:08.100Z", segmentID: "segment-1-live-1", isFinal: false, textLength: 12, metadata: [
                "translationState": "liveFresh",
                "sourceSegmentIDs": "segment-1"
            ]),
            event("caption_translation_overlay_published", wallTime: "2026-05-06T00:00:08.200Z", segmentID: "segment-1", isFinal: false, textLength: 12, metadata: [
                "path": "realtime",
                "sourceSegmentIDs": "segment-1"
            ]),
            event("translation_unit_final_persisted", wallTime: "2026-05-06T00:00:09Z", segmentID: "stable-1", isFinal: true, textLength: 12, metadata: [
                "translationKind": "final",
                "translationState": "stableFinal",
                "resultID": "stable-1-result",
                "sourceSegmentIDs": "segment-1"
            ]),
            event("recording_stopped", wallTime: "2026-05-06T00:00:12Z")
        ].joined(separator: "\n").appending("\n").write(to: eventsURL, atomically: true, encoding: .utf8)
        try #"{"resultID":"stable-1-result","sourceSegmentIDs":["segment-1"],"translatedText":"第一段"}"#.appending("\n")
            .write(to: resultsURL, atomically: true, encoding: .utf8)

        let result = try runScript(arguments: ["--assert-translation-e2e", meetingDirectory.path])

        XCTAssertEqual(result.status, 1)
        XCTAssertTrue(result.stdout.contains("E2E Translation Status: FAIL"))
        XCTAssertTrue(result.stdout.contains("First Live Translation Latency: 8.10s"))
        XCTAssertTrue(result.stdout.contains("Stable Translation Coverage: 33.3%"))
        XCTAssertTrue(result.stdout.contains("Failure: first live translation exceeded latency budget"))
        XCTAssertTrue(result.stdout.contains("Failure: stable translations did not cover realtime final caption turns"))
    }

    func testAnalyzeMeetingPerformanceScriptCanFailProcessForE2EValidationFailure() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-performance-e2e-assert-\(UUID().uuidString)", isDirectory: true)
        let meetingDirectory = root.appendingPathComponent("meeting", isDirectory: true)
        let eventsURL = meetingDirectory.appendingPathComponent("performance-events.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: meetingDirectory, withIntermediateDirectories: true)
        try [
            event("recording_started", wallTime: "2026-05-06T00:00:00Z"),
            event("caption_turn_visible", wallTime: "2026-05-06T00:00:01Z", segmentID: "segment-1", isFinal: false, textLength: 30, metadata: [
                "path": "realtime"
            ]),
            event("translation_unit_live_scheduled", wallTime: "2026-05-06T00:00:02Z", segmentID: "unit-1", isFinal: false, textLength: 24, metadata: [
                "translationKind": "live"
            ])
        ].joined(separator: "\n").appending("\n").write(to: eventsURL, atomically: true, encoding: .utf8)

        let result = try runScript(arguments: ["--assert-translation-e2e", meetingDirectory.path])

        XCTAssertEqual(result.status, 1)
        XCTAssertTrue(result.stdout.contains("E2E Translation Status: FAIL"))
    }

    func testAnalyzeMeetingPerformanceScriptCanPassProcessForE2EValidationSuccess() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-performance-e2e-assert-pass-\(UUID().uuidString)", isDirectory: true)
        let meetingDirectory = root.appendingPathComponent("meeting", isDirectory: true)
        let eventsURL = meetingDirectory.appendingPathComponent("performance-events.jsonl")
        let resultsURL = meetingDirectory.appendingPathComponent("translation-results.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: meetingDirectory, withIntermediateDirectories: true)
        try [
            event("recording_started", wallTime: "2026-05-06T00:00:00Z"),
            event("caption_turn_visible", wallTime: "2026-05-06T00:00:01Z", segmentID: "segment-1", isFinal: false, textLength: 30, metadata: [
                "path": "realtime"
            ]),
            event("translation_unit_live_scheduled", wallTime: "2026-05-06T00:00:02Z", segmentID: "unit-1", isFinal: false, textLength: 24, metadata: [
                "translationKind": "live"
            ]),
            event("translation_provider_call_started", wallTime: "2026-05-06T00:00:02.100Z", segmentID: "unit-1", isFinal: false, textLength: 24, metadata: [
                "translationKind": "live"
            ]),
            event("translation_provider_call_finished", wallTime: "2026-05-06T00:00:02.400Z", segmentID: "unit-1", isFinal: false, textLength: 8, metadata: [
                "translationKind": "live"
            ]),
            event("translation_live_result_visible", wallTime: "2026-05-06T00:00:02.500Z", segmentID: "unit-1", isFinal: false, textLength: 8),
            event("recording_stopped", wallTime: "2026-05-06T00:00:03Z")
        ].joined(separator: "\n").appending("\n").write(to: eventsURL, atomically: true, encoding: .utf8)
        try #"{"resultID":"unit-1","translatedText":"完成"}"#.appending("\n")
            .write(to: resultsURL, atomically: true, encoding: .utf8)

        let result = try runScript(arguments: ["--assert-translation-e2e", meetingDirectory.path])

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("E2E Translation Status: PASS"))
    }

    func testAnalyzeMeetingPerformanceScriptPassesSpeakerIdentificationE2EWhenIdentityBecomesVisible() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-performance-speaker-identity-e2e-pass-\(UUID().uuidString)", isDirectory: true)
        let meetingDirectory = root.appendingPathComponent("meeting", isDirectory: true)
        let eventsURL = meetingDirectory.appendingPathComponent("performance-events.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: meetingDirectory, withIntermediateDirectories: true)
        try [
            event("recording_started", wallTime: "2026-05-06T00:00:00Z"),
            event("caption_turn_visible", wallTime: "2026-05-06T00:00:01Z", segmentID: "segment-1", isFinal: true, textLength: 30, metadata: [
                "path": "realtime",
                "speakerID": "deepgram-speaker-1",
                "sourceSegmentIDs": "segment-1"
            ]),
            event("speaker_identity_scheduled", wallTime: "2026-05-06T00:00:01.100Z", segmentID: "deepgram-speaker-1", metadata: [
                "speakerID": "deepgram-speaker-1",
                "sourceSegmentIDs": "segment-1"
            ]),
            event("speaker_identity_embedding_started", wallTime: "2026-05-06T00:00:01.200Z", segmentID: "deepgram-speaker-1", metadata: [
                "speakerID": "deepgram-speaker-1"
            ]),
            event("speaker_identity_embedding_finished", wallTime: "2026-05-06T00:00:01.700Z", segmentID: "deepgram-speaker-1", metadata: [
                "speakerID": "deepgram-speaker-1",
                "durationSeconds": "3.00"
            ]),
            event("speaker_identity_resolved", wallTime: "2026-05-06T00:00:01.800Z", segmentID: "deepgram-speaker-1", metadata: [
                "speakerID": "deepgram-speaker-1",
                "decision": "matched",
                "displayLabel": "Allan",
                "confidence": "0.94"
            ]),
            event("speaker_identity_label_visible", wallTime: "2026-05-06T00:00:01.900Z", segmentID: "deepgram-speaker-1", metadata: [
                "speakerID": "deepgram-speaker-1",
                "displayLabel": "Allan",
                "visibleTurnCount": "1"
            ]),
            event("recording_stopped", wallTime: "2026-05-06T00:00:03Z")
        ].joined(separator: "\n").appending("\n").write(to: eventsURL, atomically: true, encoding: .utf8)

        let result = try runScript(arguments: ["--assert-speaker-identification-e2e", meetingDirectory.path])

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("E2E Speaker Identification Status: PASS"))
        XCTAssertTrue(result.stdout.contains("Speaker Identity Scheduled Events: 1"))
        XCTAssertTrue(result.stdout.contains("Speaker Identity Label Visible Events: 1"))
        XCTAssertTrue(result.stdout.contains("First Speaker Identity Visible Latency: 0.90s"))
        XCTAssertFalse(result.stdout.contains("Failure: speaker"))
    }

    func testAnalyzeMeetingPerformanceScriptFailsSpeakerIdentificationE2EWhenIdentityNeverBecomesVisible() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-performance-speaker-identity-e2e-fail-\(UUID().uuidString)", isDirectory: true)
        let meetingDirectory = root.appendingPathComponent("meeting", isDirectory: true)
        let eventsURL = meetingDirectory.appendingPathComponent("performance-events.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: meetingDirectory, withIntermediateDirectories: true)
        try [
            event("recording_started", wallTime: "2026-05-06T00:00:00Z"),
            event("caption_turn_visible", wallTime: "2026-05-06T00:00:01Z", segmentID: "segment-1", isFinal: true, textLength: 30, metadata: [
                "path": "realtime",
                "speakerID": "deepgram-speaker-1",
                "sourceSegmentIDs": "segment-1"
            ]),
            event("speaker_identity_scheduled", wallTime: "2026-05-06T00:00:01.100Z", segmentID: "deepgram-speaker-1", metadata: [
                "speakerID": "deepgram-speaker-1",
                "sourceSegmentIDs": "segment-1"
            ]),
            event("speaker_identity_embedding_started", wallTime: "2026-05-06T00:00:01.200Z", segmentID: "deepgram-speaker-1", metadata: [
                "speakerID": "deepgram-speaker-1"
            ]),
            event("speaker_identity_embedding_finished", wallTime: "2026-05-06T00:00:01.700Z", segmentID: "deepgram-speaker-1", metadata: [
                "speakerID": "deepgram-speaker-1"
            ]),
            event("speaker_identity_resolved", wallTime: "2026-05-06T00:00:01.800Z", segmentID: "deepgram-speaker-1", metadata: [
                "speakerID": "deepgram-speaker-1",
                "decision": "matched",
                "displayLabel": "Allan",
                "confidence": "0.94"
            ]),
            event("recording_stopped", wallTime: "2026-05-06T00:00:03Z")
        ].joined(separator: "\n").appending("\n").write(to: eventsURL, atomically: true, encoding: .utf8)

        let result = try runScript(arguments: ["--assert-speaker-identification-e2e", meetingDirectory.path])

        XCTAssertEqual(result.status, 1)
        XCTAssertTrue(result.stdout.contains("E2E Speaker Identification Status: FAIL"))
        XCTAssertTrue(result.stdout.contains("Speaker Identity Label Visible Events: 0"))
        XCTAssertTrue(result.stdout.contains("Failure: speaker identity resolved but never became visible"))
    }

    func testAnalyzeMeetingPerformanceScriptFailsE2EValidationForProjectionMismatch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-performance-e2e-projection-\(UUID().uuidString)", isDirectory: true)
        let meetingDirectory = root.appendingPathComponent("meeting", isDirectory: true)
        let eventsURL = meetingDirectory.appendingPathComponent("performance-events.jsonl")
        let resultsURL = meetingDirectory.appendingPathComponent("translation-results.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: meetingDirectory, withIntermediateDirectories: true)
        try [
            event("recording_started", wallTime: "2026-05-06T00:00:00Z"),
            event("caption_turn_visible", wallTime: "2026-05-06T00:00:01Z", segmentID: "segment-1", isFinal: true, textLength: 30, metadata: [
                "path": "realtime",
                "sourceSegmentIDs": "segment-1"
            ]),
            event("translation_provider_call_started", wallTime: "2026-05-06T00:00:02Z", segmentID: "block-1", isFinal: true, textLength: 60, metadata: [
                "translationKind": "final"
            ]),
            event("translation_provider_call_finished", wallTime: "2026-05-06T00:00:03Z", segmentID: "block-1", isFinal: true, textLength: 20, metadata: [
                "translationKind": "final"
            ]),
            event("translation_unit_final_persisted", wallTime: "2026-05-06T00:00:03.100Z", segmentID: "block-1", isFinal: true, textLength: 20, metadata: [
                "translationKind": "final",
                "translationState": "stableFinal",
                "resultID": "stable-1",
                "sourceSegmentIDs": "segment-1,segment-2"
            ]),
            event("translation_unit_projection_mismatch", wallTime: "2026-05-06T00:00:03.200Z", segmentID: "block-1", isFinal: true, textLength: 20, metadata: [
                "translationKind": "final",
                "resultID": "stable-1",
                "sourceSegmentIDs": "segment-1,segment-2",
                "turnSourceSegmentIDs": "segment-1"
            ]),
            event("recording_stopped", wallTime: "2026-05-06T00:00:04Z")
        ].joined(separator: "\n").appending("\n").write(to: eventsURL, atomically: true, encoding: .utf8)
        try #"{"resultID":"stable-1","translatedText":"错位翻译"}"#.appending("\n")
            .write(to: resultsURL, atomically: true, encoding: .utf8)

        let result = try runScript(arguments: ["--assert-translation-e2e", meetingDirectory.path])

        XCTAssertEqual(result.status, 1)
        XCTAssertTrue(result.stdout.contains("E2E Translation Status: FAIL"))
        XCTAssertTrue(result.stdout.contains("Translation Projection Mismatch Events: 1"))
        XCTAssertTrue(result.stdout.contains("Failure: stable translation projection mismatched visible caption turns"))
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

    private func visibleTranslationFixtureEvents() -> String {
        [
            event("deepgram_audio_frame_sent", wallTime: "2026-05-01T00:00:00Z"),
            event("caption_turn_visible", wallTime: "2026-05-01T00:00:00Z", segmentID: "segment-1", isFinal: false, textLength: 32, metadata: [
                "turnID": "turn-1"
            ]),
            event("caption_translation_scheduled", wallTime: "2026-05-01T00:00:01.000Z", segmentID: "turn-1", isFinal: false, textLength: 32, metadata: [
                "translationKind": "draft",
                "translationRequestID": "draft-1"
            ]),
            event("caption_translation_exact_attached", wallTime: "2026-05-01T00:00:02.000Z", segmentID: "turn-1", isFinal: false, textLength: 10, metadata: [
                "translationKind": "draft",
                "translationRequestID": "draft-1",
                "translationFreshness": "fresh",
                "sourceLagMilliseconds": "0"
            ]),
            event("caption_translation_carried_forward", wallTime: "2026-05-01T00:00:03.000Z", segmentID: "turn-1", isFinal: false, textLength: 10, metadata: [
                "translationKind": "draft",
                "translationFreshness": "carried",
                "sourceLagMilliseconds": "1000"
            ]),
            event("caption_translation_scheduled", wallTime: "2026-05-01T00:00:04.000Z", segmentID: "turn-1", isFinal: false, textLength: 58, metadata: [
                "translationKind": "draft",
                "translationRequestID": "draft-2"
            ]),
            event("caption_translation_approximate_attached", wallTime: "2026-05-01T00:00:05.000Z", segmentID: "turn-1", isFinal: false, textLength: 18, metadata: [
                "translationKind": "draft",
                "translationRequestID": "draft-2",
                "translationFreshness": "approximate",
                "sourceLagMilliseconds": "1500"
            ]),
            event("caption_translation_scheduled", wallTime: "2026-05-01T00:00:06.000Z", segmentID: "turn-1", isFinal: false, textLength: 60, metadata: [
                "translationKind": "draft",
                "translationRequestID": "draft-3"
            ]),
            event("caption_translation_hidden_stale", wallTime: "2026-05-01T00:00:07.000Z", segmentID: "turn-1", isFinal: false, textLength: 0, metadata: [
                "translationKind": "draft",
                "translationRequestID": "draft-3",
                "attachDecision": "hidden_stale",
                "attachRejectReason": "low_similarity"
            ]),
            event("caption_turn_visible", wallTime: "2026-05-01T00:00:08.000Z", segmentID: "segment-1", isFinal: true, textLength: 64, metadata: [
                "turnID": "turn-1"
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
