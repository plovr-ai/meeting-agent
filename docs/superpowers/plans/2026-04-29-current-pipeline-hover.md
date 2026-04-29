# Current Pipeline Hover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Consolidate current pipeline details and latency summaries into the native tooltip on the Current Pipeline icon.

**Architecture:** Keep the change inside the existing SwiftUI meeting detail view. Use `MeetingRecord.performanceEventsURL` to derive a read-only latency summary from existing `PerformanceEvent` JSONL entries, and format it into the existing `.help(pipelineDebugHelpText)` text.

**Tech Stack:** Swift 5.9, SwiftUI, XCTest source-layout guards, existing `PerformanceEvent` Codable model.

---

### Task 1: Guard The UI Contract

**Files:**
- Modify: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

- [ ] **Step 1: Update the existing metadata layout test**

Change `testCurrentPipelineMovesDebugDetailsBehindHoverIcon` so it expects the pipeline chip to be absent and the tooltip to include pipeline plus latency details:

```swift
XCTAssertTrue(metadataSource.contains("Image(systemName: \"exclamationmark.circle\")"))
XCTAssertTrue(metadataSource.contains(".help(pipelineDebugHelpText)"))
XCTAssertTrue(metadataSource.contains("CommandCenterChip(title: transcriptionStatusText"))
XCTAssertFalse(metadataSource.contains("CommandCenterChip(title: pipelineDisplayName"))
XCTAssertFalse(metadataSource.contains("CommandCenterChip(title: \"Actual STT Source:"))
XCTAssertFalse(metadataSource.contains("CommandCenterChip(title: \"Transcription Link:"))
XCTAssertFalse(metadataSource.contains("CommandCenterChip(title: \"Transcription Model:"))
XCTAssertFalse(metadataSource.contains("CommandCenterChip(title: \"Preflight:"))
XCTAssertTrue(source.contains("\"Pipeline: \\(pipelineDisplayName)\""))
XCTAssertTrue(source.contains("\"Transcript Latency: \\(transcriptLatencyText)\""))
XCTAssertTrue(source.contains("\"Translation Latency: \\(translationLatencyText)\""))
XCTAssertTrue(source.contains("meeting.performanceEventsURL"))
XCTAssertTrue(source.contains("PerformanceEvent.self"))
XCTAssertTrue(source.contains("translationRequestID"))
XCTAssertTrue(source.contains("caption_translation_scheduled"))
XCTAssertTrue(source.contains("caption_translation_attached"))
```

- [ ] **Step 2: Run the focused test and confirm failure**

Run: `swift test --filter MainWindowViewLayoutTests/testCurrentPipelineMovesDebugDetailsBehindHoverIcon`

Expected: FAIL because `CommandCenterChip(title: pipelineDisplayName` is still present and the new tooltip latency rows do not exist.

### Task 2: Expand Tooltip And Remove Visible Pipeline Chip

**Files:**
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift`

- [ ] **Step 1: Remove the visible pipeline chip**

In `private var metadata: some View`, delete this chip from the metadata `HStack`:

```swift
CommandCenterChip(title: pipelineDisplayName, tint: CommandCenterPalette.primary)
```

- [ ] **Step 2: Add pipeline and latency rows to tooltip text**

Replace `pipelineDebugHelpText` with:

```swift
private var pipelineDebugHelpText: String {
    [
        "Pipeline: \(pipelineDisplayName)",
        "Actual STT Source: \(actualTranscriptionSourceText)",
        "Transcription Link: \(transcriptionLinkText)",
        "Transcription Model: \(transcriptionModelText)",
        "Preflight: \(preflightText)",
        "Transcript Latency: \(transcriptLatencyText)",
        "Translation Latency: \(translationLatencyText)"
    ].joined(separator: "\n")
}
```

- [ ] **Step 3: Add latency computed properties**

Add these properties near `pipelineDebugHelpText`:

```swift
private var transcriptLatencyText: String {
    PipelineLatencySummary(meeting: meeting).transcriptLatencyText
}

private var translationLatencyText: String {
    PipelineLatencySummary(meeting: meeting).translationLatencyText
}
```

### Task 3: Implement Read-Only Latency Summary

**Files:**
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift`

- [ ] **Step 1: Add a private summary helper**

Add a private helper near the other private view support types in `MainWindowView.swift`:

```swift
private struct PipelineLatencySummary {
    let meeting: MeetingRecord

    var transcriptLatencyText: String {
        guard let event = latestTranscriptEvent,
              let latency = latencySeconds(for: event) else {
            return "unavailable"
        }
        return format(seconds: latency)
    }

    var translationLatencyText: String {
        let events = performanceEvents
        if let attached = events.last(where: { $0.event == "caption_translation_attached" }),
           let latency = translationLatencySeconds(for: attached, in: events) {
            return format(seconds: latency)
        }
        if events.contains(where: { $0.event.hasPrefix("caption_translation_") }) {
            return "attach latency unavailable"
        }
        return "unavailable"
    }

    private var latestTranscriptEvent: PerformanceEvent? {
        performanceEvents.last(where: { $0.event == "transcript_segment_written" && $0.audioTimeSeconds != nil })
            ?? performanceEvents.last(where: { $0.event == "stt_segment_received" && $0.audioTimeSeconds != nil })
    }

    private var performanceEvents: [PerformanceEvent] {
        guard let url = meeting.performanceEventsURL,
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return content
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                try? decoder.decode(PerformanceEvent.self, from: Data(line.utf8))
            }
    }

    private func latencySeconds(for event: PerformanceEvent) -> TimeInterval? {
        guard let audioTimeSeconds = event.audioTimeSeconds else {
            return nil
        }
        let expectedWallTime = meeting.startedAt.addingTimeInterval(audioTimeSeconds)
        return max(0, event.wallTime.timeIntervalSince(expectedWallTime))
    }

    private func translationLatencySeconds(for attached: PerformanceEvent, in events: [PerformanceEvent]) -> TimeInterval? {
        let matchingEvents = translationRequestEvents(matching: attached, in: events)
        guard let start = matchingEvents.last(where: { $0.event == "caption_translation_scheduled" })
                ?? matchingEvents.last(where: { $0.event == "caption_translation_started" }) else {
            return nil
        }
        return max(0, attached.wallTime.timeIntervalSince(start.wallTime))
    }

    private func translationRequestEvents(matching attached: PerformanceEvent, in events: [PerformanceEvent]) -> [PerformanceEvent] {
        guard let requestID = attached.metadata["translationRequestID"] else {
            return events.filter { $0.wallTime <= attached.wallTime }
        }
        return events.filter { $0.metadata["translationRequestID"] == requestID }
    }

    private func format(seconds: TimeInterval) -> String {
        if seconds < 1 {
            return "\(Int((seconds * 1_000).rounded())) ms"
        }
        return String(format: "%.1f s", seconds)
    }
}
```

- [ ] **Step 2: Run focused test**

Run: `swift test --filter MainWindowViewLayoutTests/testCurrentPipelineMovesDebugDetailsBehindHoverIcon`

Expected: PASS.

### Task 4: Verify And Commit

**Files:**
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift`
- Modify: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`
- Create: `docs/superpowers/specs/2026-04-29-current-pipeline-hover-design.md`
- Create: `docs/superpowers/plans/2026-04-29-current-pipeline-hover.md`

- [ ] **Step 1: Run full verification**

Run: `make test`

Expected: PASS.

- [ ] **Step 2: Check git status**

Run: `git status --short`

Expected changed files only in the paths listed above.

- [ ] **Step 3: Commit**

```bash
git add Sources/MeetingAgentApp/MainWindowView.swift Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift docs/superpowers/specs/2026-04-29-current-pipeline-hover-design.md docs/superpowers/plans/2026-04-29-current-pipeline-hover.md
git commit -m "feat: move pipeline details into hover (#73)"
```

## Self-Review

- Spec coverage: the plan removes the visible pipeline chip, expands the native tooltip, and adds transcript/translation latency summaries from existing performance events.
- Placeholder scan: no placeholder implementation steps remain.
- Type consistency: `PipelineLatencySummary`, `PerformanceEvent`, and `meeting.performanceEventsURL` match existing project types.
