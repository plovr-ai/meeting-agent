# OpenRouter Translation E2E Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add deterministic fixture-backed caption E2E coverage and an opt-in real OpenRouter translation E2E gate.

**Architecture:** Keep default tests offline by extending regression fixture support and UI/performance assertions around existing artifacts. Add a separate `OpenRouterTranslationE2ETests` suite that skips unless explicitly enabled, rebuilds caption turns from fixed Deepgram transcript fixtures, calls real `OpenRouterTextTranslationProvider`, persists temporary translation artifacts, attaches results to the UI projection, and runs the existing analyzer as the final gate.

**Tech Stack:** Swift 5.9, XCTest, Swift Package Manager, existing `MeetingAgentCore` caption/translation runtime, `OpenRouterTextTranslationProvider`, `scripts/analyze-meeting-performance.swift`.

---

## File Structure

- Modify `Tests/MeetingAgentCoreTests/RegressionFixtureSupport.swift`
  - Extend fixture manifest decoding with optional performance and OpenRouter E2E budgets.
  - Add helpers for reading performance events, copying fixture artifacts into temp meeting directories, projecting source captions, attaching translation results, and asserting display-state rows.
- Modify `Tests/MeetingAgentCoreTests/MeetingRegressionFixtureSupportTests.swift`
  - Add decoding coverage for optional manifest budget fields.
  - Add helper tests for CJK detection and fixture temp directory copying.
- Modify `Tests/MeetingAgentCoreTests/MeetingRegressionUIProjectionTests.swift`
  - Keep existing golden UI tests.
  - Add default offline caption-performance assertions for golden fixtures.
- Create `Tests/MeetingAgentCoreTests/OpenRouterTranslationE2ETests.swift`
  - Add opt-in real OpenRouter E2E test.
  - Skip unless `MEETING_AGENT_RUN_OPENROUTER_E2E=1` and `MEETING_AGENT_OPENROUTER_API_KEY` are present.
- Modify fixture manifests under `Tests/MeetingAgentCoreTests/Fixtures/RegressionMeetings/*/manifest.json`
  - Add optional caption budgets.
  - Mark one or more golden fixtures as enabled for OpenRouter translation E2E.

---

### Task 1: Manifest Budgets And Fixture Helpers

**Files:**
- Modify: `Tests/MeetingAgentCoreTests/RegressionFixtureSupport.swift`
- Modify: `Tests/MeetingAgentCoreTests/MeetingRegressionFixtureSupportTests.swift`

- [ ] **Step 1: Write failing tests for optional budget decoding and CJK helper**

Add these tests to `MeetingRegressionFixtureSupportTests`:

```swift
func testManifestDecodesOptionalPerformanceBudgets() throws {
    let data = Data(#"""
    {
      "id": "microsoft-teams-public-preview-en-zh",
      "sourceMeetingID": "D5C47AEC-4E86-4C66-9B61-FEE3D151006C",
      "scenario": "single-speaker-long-no-speech-final",
      "sourceLocale": "en-US",
      "targetLocale": "zh-CN",
      "purpose": "golden",
      "expectedAnalyzerStatus": "pass",
      "expectedFailures": [],
      "captionPerformanceBudgets": {
        "timeToFirstLiveCaptionSeconds": 2.0,
        "captionLagP95Seconds": 3.0,
        "captionStabilityMaxUpdatesPerFinal": 10.0
      },
      "openRouterTranslationE2E": {
        "enabled": true,
        "modelEnvironmentKey": "MEETING_AGENT_OPENROUTER_E2E_MODEL",
        "firstTranslationLatencySeconds": 4.0,
        "stableCoverageFloor": 0.8
      }
    }
    """#.utf8)

    let manifest = try JSONDecoder.meetingAgent.decode(RegressionFixtureManifest.self, from: data)

    XCTAssertEqual(manifest.captionPerformanceBudgets?.timeToFirstLiveCaptionSeconds, 2.0)
    XCTAssertEqual(manifest.captionPerformanceBudgets?.captionLagP95Seconds, 3.0)
    XCTAssertEqual(manifest.captionPerformanceBudgets?.captionStabilityMaxUpdatesPerFinal, 10.0)
    XCTAssertEqual(manifest.openRouterTranslationE2E?.enabled, true)
    XCTAssertEqual(manifest.openRouterTranslationE2E?.modelEnvironmentKey, "MEETING_AGENT_OPENROUTER_E2E_MODEL")
    XCTAssertEqual(manifest.openRouterTranslationE2E?.firstTranslationLatencySeconds, 4.0)
    XCTAssertEqual(manifest.openRouterTranslationE2E?.stableCoverageFloor, 0.8)
}

func testManifestKeepsBudgetFieldsOptional() throws {
    let data = Data(#"""
    {
      "id": "fixture",
      "sourceMeetingID": "meeting",
      "scenario": "scenario",
      "sourceLocale": "en-US",
      "targetLocale": "zh-CN",
      "purpose": "golden",
      "expectedAnalyzerStatus": "pass",
      "expectedFailures": []
    }
    """#.utf8)

    let manifest = try JSONDecoder.meetingAgent.decode(RegressionFixtureManifest.self, from: data)

    XCTAssertNil(manifest.captionPerformanceBudgets)
    XCTAssertNil(manifest.openRouterTranslationE2E)
}

func testTranslationQualityHelperDetectsCJKText() {
    XCTAssertTrue(RegressionTranslationQuality.containsCJK("这是中文翻译"))
    XCTAssertFalse(RegressionTranslationQuality.containsCJK("plain English translation"))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```sh
swift test --filter MeetingRegressionFixtureSupportTests
```

Expected: FAIL because `RegressionFixtureManifest` has no `captionPerformanceBudgets` or `openRouterTranslationE2E` fields, and `RegressionTranslationQuality` is undefined.

- [ ] **Step 3: Implement manifest budget types and quality helper**

Update `RegressionFixtureSupport.swift`:

```swift
struct RegressionCaptionPerformanceBudgets: Codable, Equatable {
    var timeToFirstLiveCaptionSeconds: Double?
    var captionLagP95Seconds: Double?
    var captionStabilityMaxUpdatesPerFinal: Double?
}

struct RegressionOpenRouterTranslationE2EConfiguration: Codable, Equatable {
    var enabled: Bool
    var modelEnvironmentKey: String?
    var firstTranslationLatencySeconds: Double?
    var stableCoverageFloor: Double?
}

struct RegressionFixtureManifest: Codable, Equatable {
    var id: String
    var sourceMeetingID: String
    var scenario: String
    var sourceLocale: String
    var targetLocale: String
    var purpose: RegressionFixturePurpose
    var expectedAnalyzerStatus: RegressionAnalyzerStatus
    var expectedFailures: [String]
    var notes: [String]?
    var captionPerformanceBudgets: RegressionCaptionPerformanceBudgets?
    var openRouterTranslationE2E: RegressionOpenRouterTranslationE2EConfiguration?
}

enum RegressionTranslationQuality {
    static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let value = Int(scalar.value)
            return (0x4E00...0x9FFF).contains(value)
                || (0x3040...0x30FF).contains(value)
                || (0xAC00...0xD7AF).contains(value)
        }
    }

    static func normalized(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}
```

- [ ] **Step 4: Add fixture artifact helpers**

Add to `RegressionFixtureFiles` extension:

```swift
static func loadPerformanceEvents(in fixtureURL: URL) throws -> [PerformanceEvent] {
    let text = try String(
        contentsOf: fixtureURL.appendingPathComponent("performance-events.jsonl"),
        encoding: .utf8
    )
    return try text.split(separator: "\n").map {
        try JSONDecoder.meetingAgent.decode(PerformanceEvent.self, from: Data($0.utf8))
    }
}

static func temporaryMeetingDirectory(copying fixtureURL: URL, prefix: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let required = [
        "audio.wav",
        "metadata.json",
        "diagnostics.json",
        "transcript-events.jsonl",
        "transcript.json"
    ]
    for filename in required {
        try FileManager.default.copyItem(
            at: fixtureURL.appendingPathComponent(filename),
            to: root.appendingPathComponent(filename)
        )
    }
    return root
}

static func writeTranslationRecords(
    _ records: [TranslationResultPersistenceRecord],
    to directoryURL: URL
) throws {
    let store = TranslationResultPersistenceStore(directoryURL: directoryURL)
    for record in records {
        try store.append(record)
    }
}
```

- [ ] **Step 5: Run support tests**

Run:

```sh
swift test --filter MeetingRegressionFixtureSupportTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```sh
git add Tests/MeetingAgentCoreTests/RegressionFixtureSupport.swift Tests/MeetingAgentCoreTests/MeetingRegressionFixtureSupportTests.swift
git commit -m "test: extend regression fixture e2e metadata"
```

---

### Task 2: Offline Caption UI And Performance E2E

**Files:**
- Modify: `Tests/MeetingAgentCoreTests/MeetingRegressionUIProjectionTests.swift`
- Modify: `Tests/MeetingAgentCoreTests/Fixtures/RegressionMeetings/microsoft-teams-public-preview-en-zh/manifest.json`
- Modify: `Tests/MeetingAgentCoreTests/Fixtures/RegressionMeetings/microsoft-teams-interpreter-multi-speaker-en-zh/manifest.json`

- [ ] **Step 1: Add caption-performance budget fields to fixture manifests**

Add this object to each golden fixture manifest:

```json
"captionPerformanceBudgets": {
  "timeToFirstLiveCaptionSeconds": 2.5,
  "captionLagP95Seconds": 3.0,
  "captionStabilityMaxUpdatesPerFinal": 10.0
}
```

For `microsoft-teams-public-preview-en-zh`, also add:

```json
"openRouterTranslationE2E": {
  "enabled": true,
  "modelEnvironmentKey": "MEETING_AGENT_OPENROUTER_E2E_MODEL",
  "firstTranslationLatencySeconds": 4.0,
  "stableCoverageFloor": 0.8
}
```

- [ ] **Step 2: Write failing offline performance test**

Add to `MeetingRegressionUIProjectionTests`:

```swift
func testGoldenFixturesMeetCaptionPerformanceBudgets() throws {
    for fixtureURL in try RegressionFixtureFiles.allFixtureDirectories() {
        let manifest = try RegressionFixtureFiles.loadManifest(in: fixtureURL)
        guard manifest.purpose == .golden else { continue }
        let budgets = manifest.captionPerformanceBudgets ?? RegressionCaptionPerformanceBudgets(
            timeToFirstLiveCaptionSeconds: 2.5,
            captionLagP95Seconds: 3.0,
            captionStabilityMaxUpdatesPerFinal: 10.0
        )
        let events = try RegressionFixtureFiles.loadPerformanceEvents(in: fixtureURL)
        let metrics = RegressionCaptionPerformanceMetrics(events: events)

        if let budget = budgets.timeToFirstLiveCaptionSeconds {
            let observed = try XCTUnwrap(metrics.timeToFirstLiveCaptionSeconds, "\(manifest.id) missing first caption metric")
            XCTAssertLessThanOrEqual(observed, budget, "\(manifest.id) first caption latency")
        }
        if let budget = budgets.captionLagP95Seconds {
            let observed = try XCTUnwrap(metrics.captionLagP95Seconds, "\(manifest.id) missing caption lag p95")
            XCTAssertLessThanOrEqual(observed, budget, "\(manifest.id) caption lag p95")
        }
        if let budget = budgets.captionStabilityMaxUpdatesPerFinal {
            let observed = try XCTUnwrap(metrics.captionStabilityUpdatesPerFinal, "\(manifest.id) missing caption stability")
            XCTAssertLessThanOrEqual(observed, budget, "\(manifest.id) caption stability")
        }
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run:

```sh
swift test --filter MeetingRegressionUIProjectionTests/testGoldenFixturesMeetCaptionPerformanceBudgets
```

Expected: FAIL because `RegressionCaptionPerformanceMetrics` is undefined.

- [ ] **Step 4: Implement caption performance metrics helper**

Add to `RegressionFixtureSupport.swift`:

```swift
struct RegressionCaptionPerformanceMetrics: Equatable {
    var timeToFirstLiveCaptionSeconds: Double?
    var captionLagP95Seconds: Double?
    var captionStabilityUpdatesPerFinal: Double?

    init(events: [PerformanceEvent]) {
        let sorted = events.sorted { $0.wallTime < $1.wallTime }
        let firstAudio = sorted.first { $0.event == "deepgram_audio_frame_sent" }?.wallTime
        let firstRealtimeCaption = sorted.first {
            $0.event == "caption_turn_visible" && $0.metadata["path"] != "replay"
        }?.wallTime
        if let firstAudio, let firstRealtimeCaption {
            timeToFirstLiveCaptionSeconds = max(0, firstRealtimeCaption.timeIntervalSince(firstAudio))
        }

        let realtimeCaptionLags = sorted.compactMap { event -> Double? in
            guard event.event == "caption_turn_visible",
                  event.metadata["path"] != "replay",
                  event.metadata["path"] != "batch",
                  event.metadata["path"] != "flush",
                  let audioTime = event.audioTimeSeconds
            else {
                return nil
            }
            guard let firstAudio else { return nil }
            let elapsed = event.wallTime.timeIntervalSince(firstAudio)
            return max(0, elapsed - audioTime)
        }
        captionLagP95Seconds = Self.percentile(realtimeCaptionLags, percentile: 0.95)

        let realtimeVisible = sorted.filter {
            $0.event == "caption_turn_visible" && $0.metadata["path"] != "replay"
        }
        let finalCount = realtimeVisible.filter { $0.isFinal == true }.count
        if finalCount > 0 {
            captionStabilityUpdatesPerFinal = Double(realtimeVisible.count) / Double(finalCount)
        }
    }

    private static func percentile(_ values: [Double], percentile: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = Int((Double(sorted.count - 1) * percentile).rounded(.up))
        return sorted[min(max(index, 0), sorted.count - 1)]
    }
}
```

- [ ] **Step 5: Run UI projection tests**

Run:

```sh
swift test --filter MeetingRegressionUIProjectionTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```sh
git add Tests/MeetingAgentCoreTests/MeetingRegressionUIProjectionTests.swift Tests/MeetingAgentCoreTests/RegressionFixtureSupport.swift Tests/MeetingAgentCoreTests/Fixtures/RegressionMeetings/*/manifest.json
git commit -m "test: assert fixture caption ui performance"
```

---

### Task 3: Opt-In Real OpenRouter Translation E2E

**Files:**
- Create: `Tests/MeetingAgentCoreTests/OpenRouterTranslationE2ETests.swift`
- Modify: `Tests/MeetingAgentCoreTests/RegressionFixtureSupport.swift`

- [ ] **Step 1: Write skipped-by-default E2E test**

Create `OpenRouterTranslationE2ETests.swift`:

```swift
import XCTest
@testable import MeetingAgentCore

final class OpenRouterTranslationE2ETests: XCTestCase {
    @MainActor
    func testRealOpenRouterTranslationProjectsOntoFixtureCaptionUIAndPassesAnalyzer() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MEETING_AGENT_RUN_OPENROUTER_E2E"] == "1" else {
            throw XCTSkip("Set MEETING_AGENT_RUN_OPENROUTER_E2E=1 to run paid OpenRouter translation E2E")
        }
        guard let apiKey = OpenRouterChatConfiguration.normalized(environment["MEETING_AGENT_OPENROUTER_API_KEY"]) else {
            throw XCTSkip("Set MEETING_AGENT_OPENROUTER_API_KEY to run OpenRouter translation E2E")
        }
        let model = OpenRouterChatConfiguration.normalized(environment["MEETING_AGENT_OPENROUTER_E2E_MODEL"])
            ?? "google/gemini-2.5-flash"
        let fixtures = try RegressionFixtureFiles.openRouterTranslationE2EFixtureDirectories()
        XCTAssertFalse(fixtures.isEmpty, "At least one golden fixture should opt into OpenRouter translation E2E")

        for fixtureURL in fixtures {
            try await runOpenRouterE2E(
                fixtureURL: fixtureURL,
                apiKey: apiKey,
                model: model
            )
        }
    }
}
```

- [ ] **Step 2: Run skipped test**

Run:

```sh
swift test --filter OpenRouterTranslationE2ETests
```

Expected: PASS with `XCTSkip` when env vars are absent.

- [ ] **Step 3: Add fixture selection helper**

Add to `RegressionFixtureFiles`:

```swift
static func openRouterTranslationE2EFixtureDirectories() throws -> [URL] {
    try allFixtureDirectories().filter { fixtureURL in
        let manifest = try loadManifest(in: fixtureURL)
        return manifest.purpose == .golden
            && manifest.openRouterTranslationE2E?.enabled == true
    }
}
```

- [ ] **Step 4: Add source caption projection helper**

Add to `RegressionFixtureFiles`:

```swift
@MainActor
static func projectSourceCaptionTurns(
    transcript: TranscriptDocument,
    manifest: RegressionFixtureManifest,
    performanceEventLogger: PerformanceEventLogger?
) async -> LiveCaptionPipelineSnapshot {
    let pipeline = LiveCaptionPipeline(
        sourceLocale: manifest.sourceLocale,
        targetLocale: manifest.targetLocale,
        translationProvider: nil,
        performanceEventLogger: performanceEventLogger,
        translationMode: .unitPipelineActiveRecording
    )
    var accumulator = TranscriptSegmentAccumulator()
    var snapshot = LiveCaptionPipelineSnapshot(turns: [], captionHealth: .idle, translationHealth: .idle)
    for segment in transcript.segments where segment.isFinal {
        let result = accumulator.apply(.upsert(segment))
        snapshot = await pipeline.apply(result)
    }
    snapshot = pipeline.flushCaptionsOnly(reason: .manualStop)
    return snapshot
}
```

- [ ] **Step 5: Add translation E2E runner to the test file**

Add below the test method:

```swift
@MainActor
private func runOpenRouterE2E(
    fixtureURL: URL,
    apiKey: String,
    model: String,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws {
    let manifest = try RegressionFixtureFiles.loadManifest(in: fixtureURL)
    let transcript = try RegressionFixtureFiles.loadTranscript(in: fixtureURL)
    let tempMeeting = try RegressionFixtureFiles.temporaryMeetingDirectory(
        copying: fixtureURL,
        prefix: "openrouter-e2e-\(manifest.id)"
    )
    defer { try? FileManager.default.removeItem(at: tempMeeting) }

    let logger = PerformanceEventLogger(url: tempMeeting.appendingPathComponent("performance-events.jsonl"))
    logger.log("recording_started")
    logger.log("deepgram_audio_frame_sent", audioTimeSeconds: 0)
    let captionSnapshot = await RegressionFixtureFiles.projectSourceCaptionTurns(
        transcript: transcript,
        manifest: manifest,
        performanceEventLogger: logger
    )

    var persisted: [TranslationResultPersistenceRecord] = []
    let provider = OpenRouterTextTranslationProvider(
        configuration: OpenRouterChatConfiguration(apiKey: apiKey, model: model)
    )
    var pipeline = TranslationExperiencePipeline(
        meetingID: UUID(uuidString: manifest.sourceMeetingID) ?? UUID(),
        sourceLocale: manifest.sourceLocale,
        targetLocale: manifest.targetLocale,
        liveProvider: provider,
        accurateProvider: provider,
        performanceEventLogger: logger,
        persistFinalResult: { persisted.append($0) }
    )

    let stableSnapshot = await pipeline.apply(segments: transcript.segments.filter(\.isFinal))
    let finalSnapshot = await pipeline.flushAndFinalize()
    let stableResults = stableSnapshot.stableResults + finalSnapshot.stableResults
    try RegressionFixtureFiles.writeTranslationRecords(persisted, to: tempMeeting)

    let overlayPipeline = LiveCaptionPipeline(
        sourceLocale: manifest.sourceLocale,
        targetLocale: manifest.targetLocale,
        translationProvider: nil,
        performanceEventLogger: logger,
        translationMode: .unitPipelineActiveRecording
    )
    _ = overlayPipeline.replayCaptionsOnly(transcript)
    _ = overlayPipeline.flushCaptionsOnly(reason: .manualStop)
    let overlaySnapshot = overlayPipeline.attachTranslationResults(stableResults)
    logger.log("caption_translation_overlay_published", metadata: [
        "path": "realtime",
        "turnCount": String(overlaySnapshot.turns.count)
    ])
    for result in stableResults {
        logger.log(
            "translation_stable_result_visible",
            segmentID: result.sourceID,
            isFinal: true,
            textLength: result.translatedText.count,
            metadata: [
                "path": "realtime",
                "translationState": result.displayState.rawValue,
                "translationRequestID": result.id,
                "sourceSegmentIDs": result.sourceSegmentIDs.joined(separator: ",")
            ]
        )
    }
    logger.log("recording_stopped")

    try assertTranslatedCaptionUI(
        fixtureID: manifest.id,
        captionSnapshot: captionSnapshot,
        overlaySnapshot: overlaySnapshot,
        stableResults: stableResults,
        targetLocale: manifest.targetLocale,
        file: file,
        line: line
    )

    let analyzer = try RegressionFixtureFiles.runAnalyzer(tempMeeting)
    XCTAssertEqual(analyzer.status, 0, "\(manifest.id) analyzer output:\n\(analyzer.stdout)\n\(analyzer.stderr)", file: file, line: line)
}
```

- [ ] **Step 6: Add UI translation assertion helper**

Add below the runner:

```swift
@MainActor
private func assertTranslatedCaptionUI(
    fixtureID: String,
    captionSnapshot: LiveCaptionPipelineSnapshot,
    overlaySnapshot: LiveCaptionPipelineSnapshot,
    stableResults: [TranslationResult],
    targetLocale: String,
    file: StaticString,
    line: UInt
) throws {
    XCTAssertFalse(captionSnapshot.turns.isEmpty, "\(fixtureID) should project source captions", file: file, line: line)
    XCTAssertFalse(stableResults.isEmpty, "\(fixtureID) should receive stable translation results", file: file, line: line)
    let translatedTurns = overlaySnapshot.turns.filter {
        $0.translatedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
    XCTAssertFalse(translatedTurns.isEmpty, "\(fixtureID) should show translated turns", file: file, line: line)
    for turn in translatedTurns {
        let translatedText = try XCTUnwrap(turn.translatedText, "\(fixtureID) translated text", file: file, line: line)
        XCTAssertNotEqual(
            RegressionTranslationQuality.normalized(translatedText),
            RegressionTranslationQuality.normalized(turn.originalText),
            "\(fixtureID) translation should not equal source",
            file: file,
            line: line
        )
        if targetLocale.lowercased().hasPrefix("zh") {
            XCTAssertTrue(
                RegressionTranslationQuality.containsCJK(translatedText),
                "\(fixtureID) zh-CN translation should contain CJK characters: \(translatedText)",
                file: file,
                line: line
            )
        }
        let both = LiveCaptionDisplayState(turn: turn, secondLanguageEnabled: true, displayMode: .both)
        guard case .translated(let primaryText, let sourceText) = both else {
            XCTFail("\(fixtureID) bilingual display should be translated for \(turn.sourceSegmentIDs)", file: file, line: line)
            continue
        }
        XCTAssertEqual(primaryText, translatedText, file: file, line: line)
        XCTAssertEqual(sourceText, turn.originalText, file: file, line: line)

        let translationOnly = LiveCaptionDisplayState(turn: turn, secondLanguageEnabled: true, displayMode: .translationOnly)
        guard case .translated(let translationPrimary, let translationSource) = translationOnly else {
            XCTFail("\(fixtureID) translation-only display should be translated for \(turn.sourceSegmentIDs)", file: file, line: line)
            continue
        }
        XCTAssertEqual(translationPrimary, translatedText, file: file, line: line)
        XCTAssertNil(translationSource, file: file, line: line)
    }
}
```

- [ ] **Step 7: Run skipped test again**

Run:

```sh
swift test --filter OpenRouterTranslationE2ETests
```

Expected: PASS with skip when env vars are absent.

- [ ] **Step 8: Run real OpenRouter E2E when credentials are available**

Run:

```sh
MEETING_AGENT_RUN_OPENROUTER_E2E=1 \
MEETING_AGENT_OPENROUTER_API_KEY="$MEETING_AGENT_OPENROUTER_API_KEY" \
MEETING_AGENT_OPENROUTER_E2E_MODEL="${MEETING_AGENT_OPENROUTER_E2E_MODEL:-google/gemini-2.5-flash}" \
swift test --filter OpenRouterTranslationE2ETests
```

Expected with valid credentials: PASS. Expected without credentials: skip from Step 7 already proves default behavior.

- [ ] **Step 9: Commit**

```sh
git add Tests/MeetingAgentCoreTests/OpenRouterTranslationE2ETests.swift Tests/MeetingAgentCoreTests/RegressionFixtureSupport.swift Tests/MeetingAgentCoreTests/Fixtures/RegressionMeetings/*/manifest.json
git commit -m "test: add opt-in openrouter translation e2e"
```

---

### Task 4: Full Verification

**Files:**
- No new files.

- [ ] **Step 1: Run default regression tests**

Run:

```sh
swift test --filter MeetingRegressionFixtureSupportTests
swift test --filter MeetingRegressionUIProjectionTests
swift test --filter MeetingRegressionFixtureAnalyzerTests
swift test --filter OpenRouterTranslationE2ETests
```

Expected:

- support tests pass,
- UI projection tests pass,
- analyzer fixture tests pass,
- OpenRouter E2E suite passes by skipping when opt-in env vars are absent.

- [ ] **Step 2: Run full required test gate**

Run:

```sh
make test
```

Expected:

- all XCTest tests pass,
- coverage gate passes,
- no OpenRouter network call occurs unless explicitly enabled.

- [ ] **Step 3: Run opt-in E2E if API key is configured**

Run:

```sh
MEETING_AGENT_RUN_OPENROUTER_E2E=1 \
MEETING_AGENT_OPENROUTER_API_KEY="$MEETING_AGENT_OPENROUTER_API_KEY" \
MEETING_AGENT_OPENROUTER_E2E_MODEL="${MEETING_AGENT_OPENROUTER_E2E_MODEL:-google/gemini-2.5-flash}" \
swift test --filter OpenRouterTranslationE2ETests
```

Expected:

- provider calls start and finish,
- temp analyzer returns status 0,
- translated UI turns are not pending,
- zh-CN translated text contains CJK characters,
- no `translation_unit_projection_mismatch` event is emitted.

- [ ] **Step 4: Check git status**

Run:

```sh
git status --short
```

Expected:

- only files touched by this plan and pre-existing unrelated user files are present.

- [ ] **Step 5: Final commit**

If Task 1-3 commits were not made independently, commit all E2E work:

```sh
git add Tests/MeetingAgentCoreTests/RegressionFixtureSupport.swift Tests/MeetingAgentCoreTests/MeetingRegressionFixtureSupportTests.swift Tests/MeetingAgentCoreTests/MeetingRegressionUIProjectionTests.swift Tests/MeetingAgentCoreTests/OpenRouterTranslationE2ETests.swift Tests/MeetingAgentCoreTests/Fixtures/RegressionMeetings/*/manifest.json
git commit -m "test: add fixture-backed openrouter translation e2e"
```

Expected: commit succeeds without including `.env` or unrelated local changes.

---

## Self-Review

Spec coverage:

- Fixed wav and Deepgram outputs: Task 2 and Task 3 use existing fixture artifacts and do not call STT.
- Offline caption UI and performance: Task 2 adds default UI/performance assertions.
- Real OpenRouter translation: Task 3 adds opt-in `OpenRouterTranslationE2ETests`.
- Translation UI correctness: Task 3 validates bilingual and translation-only display state.
- Translation performance and projection: Task 3 runs the analyzer and checks visible/persisted projection through generated artifacts.
- Default `make test` remains offline: Task 3 skips unless env vars are present; Task 4 verifies default behavior.

Placeholder scan:

- No deferred implementation markers are present.
- Each task includes exact files, test code, implementation code, commands, and expected outcomes.

Type consistency:

- New manifest properties match `RegressionFixtureManifest` field names.
- `RegressionTranslationQuality` is used consistently by support tests and OpenRouter E2E tests.
- `RegressionCaptionPerformanceMetrics` field names match the offline performance test.
