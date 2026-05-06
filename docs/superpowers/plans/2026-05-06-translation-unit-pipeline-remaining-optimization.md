# Translation Unit Pipeline Remaining Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make unit-level translation the active-recording translation path so realtime captions stay non-blocking, live translation stops chasing tiny caption fragments, stop recording produces no late preview publications, and stable final translations are persisted.

**Architecture:** Upgrade the existing `TranslationExperiencePipeline` from a tested prototype into the active translation entry point. `TranslationUnitBuilder` owns lane-stateful unit boundaries, `LiveTranslationScheduler` owns pending-latest preview scheduling, `AccurateTranslationScheduler` owns stable final blocks, and `TranslationResultStore` is the display and persistence query boundary.

**Tech Stack:** Swift 5.9, Swift Package Manager, XCTest, existing MeetingAgentCore types, macOS app ViewModel integration.

---

## File Structure

- Modify: `Sources/MeetingAgentCore/TranslationExperienceModels.swift`
  - Add small result/persistence metadata needed by store and finalization.
- Modify: `Sources/MeetingAgentCore/TranslationUnitBuilder.swift`
  - Convert from per-segment builder to lane-stateful builder with open blocks and explicit flush.
- Modify: `Sources/MeetingAgentCore/LiveTranslationScheduler.swift`
  - Add pending-latest per-lane scheduling and stale/timeout outcomes.
- Modify: `Sources/MeetingAgentCore/AccurateTranslationScheduler.swift`
  - Add retryable final failure records and same-language completion behavior.
- Modify: `Sources/MeetingAgentCore/TranslationResultStore.swift`
  - Add source segment mapping, stable result queries, and hydration from persisted records.
- Create: `Sources/MeetingAgentCore/TranslationResultPersistenceStore.swift`
  - Read/write `translation-results.jsonl`.
- Modify: `Sources/MeetingAgentCore/TranslationExperiencePipeline.swift`
  - Add active-recording apply flow, stop `flushAndFinalize()`, and persistence events.
- Modify: `Sources/MeetingAgentCore/LiveCaptionPipeline.swift`
  - Route active-recording translation through `TranslationExperiencePipeline` behind an internal switch; keep `CaptionTranslationScheduler` for legacy/backfill.
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
  - Stop active draft scheduling through the legacy path and call pipeline finalization on stop.
- Modify/Create tests under `Tests/MeetingAgentCoreTests/`
  - Builder, live scheduler, accurate scheduler, store, persistence, pipeline, and ViewModel integration coverage.

## Scope Notes

This plan implements the selected first implementation scope:

- Persist stable final results and final failure records only.
- Keep live preview results in memory and telemetry; do not write preview results to transcript or `translation-results.jsonl`.
- Populate transcript compatibility fields only for stable final results that map cleanly to one source segment.
- Keep legacy caption translation scheduler available for older meetings, replay, and missing-final backfill.

## Task 1: Make Translation Unit Builder Lane-Stateful

**Files:**
- Modify: `Sources/MeetingAgentCore/TranslationUnitBuilder.swift`
- Modify: `Sources/MeetingAgentCore/TranslationExperienceModels.swift`
- Test: `Tests/MeetingAgentCoreTests/TranslationUnitBuilderTests.swift`

- [ ] **Step 1: Write failing tests for Deepgram protocol semantics**

Add these tests to `Tests/MeetingAgentCoreTests/TranslationUnitBuilderTests.swift`:

```swift
func testIsFinalAdvancesStablePrefixButDoesNotSealBlock() {
    var builder = TranslationUnitBuilder(
        sourceLocale: "en-US",
        targetLocale: "zh-CN",
        configuration: TranslationUnitBuilderConfiguration(minimumLiveWords: 4, unstableTailWords: 1, minimumStableBlockCharacters: 10)
    )
    let segment = TranscriptSegment(
        id: "segment-1",
        speaker: TranscriptSpeaker(identifier: "speaker-1"),
        text: "Select settings and about",
        language: "en-US",
        isFinal: true,
        speechFinal: false,
        createdAt: Date(timeIntervalSince1970: 1)
    )

    let output = builder.apply(segments: [segment], now: Date(timeIntervalSince1970: 2))

    XCTAssertEqual(output.liveUnits.count, 1)
    XCTAssertEqual(output.liveUnits.first?.stablePrefixText, "Select settings and")
    XCTAssertTrue(output.stableBlocks.isEmpty)
}

func testSpeechFinalSealsAccumulatedLaneBlock() {
    var builder = TranslationUnitBuilder(
        sourceLocale: "en-US",
        targetLocale: "zh-CN",
        configuration: TranslationUnitBuilderConfiguration(minimumLiveWords: 4, unstableTailWords: 1, minimumStableBlockCharacters: 10)
    )
    let first = TranscriptSegment(
        id: "segment-1",
        speaker: TranscriptSpeaker(identifier: "speaker-1"),
        text: "Select settings and about",
        language: "en-US",
        isFinal: true,
        speechFinal: false,
        createdAt: Date(timeIntervalSince1970: 1)
    )
    let second = TranscriptSegment(
        id: "segment-2",
        speaker: TranscriptSpeaker(identifier: "speaker-1"),
        text: "then choose public preview.",
        language: "en-US",
        isFinal: true,
        speechFinal: true,
        createdAt: Date(timeIntervalSince1970: 2)
    )

    _ = builder.apply(segments: [first], now: Date(timeIntervalSince1970: 3))
    let output = builder.apply(segments: [first, second], now: Date(timeIntervalSince1970: 4))

    XCTAssertEqual(output.stableBlocks.count, 1)
    XCTAssertEqual(output.stableBlocks.first?.sourceText, "Select settings and about then choose public preview.")
    XCTAssertEqual(output.stableBlocks.first?.sourceSegmentIDs, ["segment-1", "segment-2"])
    XCTAssertEqual(output.stableBlocks.first?.boundaryReason, .providerHardBoundary)
}

func testManualStopFlushSealsOpenBlock() {
    var builder = TranslationUnitBuilder(
        sourceLocale: "en-US",
        targetLocale: "zh-CN",
        configuration: TranslationUnitBuilderConfiguration(minimumLiveWords: 4, unstableTailWords: 1, minimumStableBlockCharacters: 10)
    )
    let segment = TranscriptSegment(
        id: "segment-1",
        speaker: TranscriptSpeaker(identifier: "speaker-1"),
        text: "We should review the rollout status",
        language: "en-US",
        isFinal: true,
        speechFinal: false,
        createdAt: Date(timeIntervalSince1970: 1)
    )

    _ = builder.apply(segments: [segment], now: Date(timeIntervalSince1970: 2))
    let flushed = builder.flushOpenBlocks(now: Date(timeIntervalSince1970: 3))

    XCTAssertEqual(flushed.count, 1)
    XCTAssertEqual(flushed.first?.sourceText, "We should review the rollout status")
    XCTAssertEqual(flushed.first?.boundaryReason, .manualStop)
}
```

- [ ] **Step 2: Run the focused tests and verify failure**

Run:

```bash
swift test --filter TranslationUnitBuilderTests
```

Expected: FAIL because `flushOpenBlocks(now:)` does not exist and the current builder emits final blocks per segment rather than accumulated lane blocks.

- [ ] **Step 3: Add lane state and flush API**

In `Sources/MeetingAgentCore/TranslationUnitBuilder.swift`, replace the per-segment-only state with lane state:

```swift
public struct TranslationUnitBuilderConfiguration: Equatable {
    public var minimumLiveWords: Int
    public var unstableTailWords: Int
    public var minimumStableBlockCharacters: Int
    public var maximumStableBlockCharacters: Int
    public var maximumStableBlockDuration: TimeInterval
    public var pauseBoundaryInterval: TimeInterval

    public init(
        minimumLiveWords: Int = 8,
        unstableTailWords: Int = 1,
        minimumStableBlockCharacters: Int = 24,
        maximumStableBlockCharacters: Int = 220,
        maximumStableBlockDuration: TimeInterval = 12,
        pauseBoundaryInterval: TimeInterval = 1.2
    ) {
        self.minimumLiveWords = max(1, minimumLiveWords)
        self.unstableTailWords = max(0, unstableTailWords)
        self.minimumStableBlockCharacters = max(1, minimumStableBlockCharacters)
        self.maximumStableBlockCharacters = max(self.minimumStableBlockCharacters, maximumStableBlockCharacters)
        self.maximumStableBlockDuration = max(1, maximumStableBlockDuration)
        self.pauseBoundaryInterval = max(0.2, pauseBoundaryInterval)
    }
}

private struct TranslationLaneState: Equatable {
    var segmentIDs: [String] = []
    var segmentTexts: [String] = []
    var firstCreatedAt: Date?
    var lastCreatedAt: Date?
    var lastSeenSegmentID: String?
    var lastLiveSourceText: String = ""
    var revision: Int = 0

    var sourceText: String {
        segmentTexts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    var isEmpty: Bool {
        sourceText.isEmpty
    }
}
```

Add this public flush method:

```swift
public mutating func flushOpenBlocks(now: Date = Date()) -> [StableTranslationBlock] {
    var blocks: [StableTranslationBlock] = []
    for laneID in laneStates.keys.sorted(by: { $0.speakerID < $1.speakerID }) {
        guard let block = sealBlock(for: laneID, reason: .manualStop, now: now) else { continue }
        blocks.append(block)
    }
    return blocks
}
```

- [ ] **Step 4: Implement accumulated block apply behavior**

Update `apply(segments:now:)` so each final segment is appended once to its lane state. Keep interim segments eligible for live units, but do not append interim text to final blocks:

```swift
public mutating func apply(segments: [TranscriptSegment], now: Date = Date()) -> TranslationUnitBuilderOutput {
    var liveUnits: [LiveTranslationUnit] = []
    var stableBlocks: [StableTranslationBlock] = []

    for segment in segments.sorted(by: { $0.createdAt < $1.createdAt }) {
        let laneID = TranslationLaneID(
            speaker: segment.speaker,
            sourceLocale: segment.language ?? sourceLocale,
            targetLocale: targetLocale
        )

        if segment.isFinal {
            appendFinalSegment(segment, laneID: laneID)
            if let reason = boundaryReason(for: segment, laneID: laneID, now: now),
               let block = sealBlock(for: laneID, reason: reason, now: now) {
                stableBlocks.append(block)
            }
        }

        if let liveUnit = liveUnit(for: segment, laneID: laneID, now: now) {
            liveUnits.append(liveUnit)
        }
    }

    return TranslationUnitBuilderOutput(liveUnits: liveUnits, stableBlocks: stableBlocks)
}
```

Implement helpers in the same file:

```swift
private mutating func appendFinalSegment(_ segment: TranscriptSegment, laneID: TranslationLaneID) {
    var state = laneStates[laneID, default: TranslationLaneState()]
    guard state.lastSeenSegmentID != segment.id else {
        laneStates[laneID] = state
        return
    }
    state.segmentIDs.append(segment.id)
    state.segmentTexts.append(segment.text)
    state.firstCreatedAt = state.firstCreatedAt ?? segment.createdAt
    state.lastCreatedAt = segment.createdAt
    state.lastSeenSegmentID = segment.id
    laneStates[laneID] = state
}

private func boundaryReason(for segment: TranscriptSegment, laneID: TranslationLaneID, now: Date) -> StableTranslationBoundaryReason? {
    guard let state = laneStates[laneID], !state.isEmpty else { return nil }
    if segment.speechFinal { return .providerHardBoundary }
    if hasTerminalPunctuation(state.sourceText), state.sourceText.count >= configuration.minimumStableBlockCharacters {
        return .terminalPunctuation
    }
    if state.sourceText.count >= configuration.maximumStableBlockCharacters {
        return .maxLength
    }
    if let firstCreatedAt = state.firstCreatedAt,
       now.timeIntervalSince(firstCreatedAt) >= configuration.maximumStableBlockDuration {
        return .maxDuration
    }
    return nil
}

private mutating func sealBlock(
    for laneID: TranslationLaneID,
    reason: StableTranslationBoundaryReason,
    now: Date
) -> StableTranslationBlock? {
    guard let state = laneStates[laneID] else { return nil }
    let text = state.sourceText
    guard text.count >= configuration.minimumStableBlockCharacters || reason == .manualStop else { return nil }
    guard !fillerLike(text) else {
        laneStates[laneID] = TranslationLaneState()
        return nil
    }
    let block = StableTranslationBlock(
        id: "stable-\(StableTranslationBlock.stableHash([laneID.speakerID, text, String(state.segmentIDs.count)].joined(separator: "\u{1F}")))",
        laneID: laneID,
        sourceText: text,
        sourceSegmentIDs: state.segmentIDs,
        boundaryReason: reason,
        createdAt: state.firstCreatedAt ?? now
    )
    guard emittedStableBlockIDs.insert(block.id).inserted else {
        laneStates[laneID] = TranslationLaneState()
        return nil
    }
    laneStates[laneID] = TranslationLaneState()
    return block
}
```

- [ ] **Step 5: Run tests and commit**

Run:

```bash
swift test --filter TranslationUnitBuilderTests
```

Expected: PASS.

Commit:

```bash
git add Sources/MeetingAgentCore/TranslationUnitBuilder.swift Sources/MeetingAgentCore/TranslationExperienceModels.swift Tests/MeetingAgentCoreTests/TranslationUnitBuilderTests.swift
git commit -m "feat: build lane-stateful translation units"
```

## Task 2: Add Translation Result Store Queries And Persistence Records

**Files:**
- Modify: `Sources/MeetingAgentCore/TranslationExperienceModels.swift`
- Modify: `Sources/MeetingAgentCore/TranslationResultStore.swift`
- Create: `Sources/MeetingAgentCore/TranslationResultPersistenceStore.swift`
- Test: `Tests/MeetingAgentCoreTests/TranslationResultStoreTests.swift`
- Test: `Tests/MeetingAgentCoreTests/TranslationResultPersistenceStoreTests.swift`

- [ ] **Step 1: Write failing store tests**

Create `Tests/MeetingAgentCoreTests/TranslationResultStoreTests.swift`:

```swift
import XCTest
@testable import MeetingAgentCore

final class TranslationResultStoreTests: XCTestCase {
    func testStableFinalOutranksLiveResult() {
        let lane = TranslationLaneID(speaker: .default, sourceLocale: "en-US", targetLocale: "zh-CN")
        var store = TranslationResultStore()

        store.attach(TranslationResult(
            id: "live",
            sourceID: "unit-1",
            laneID: lane,
            sourceText: "We confirm the owner",
            translatedText: "我们确认负责人",
            displayState: .liveFresh,
            createdAt: Date(timeIntervalSince1970: 2),
            sourceCreatedAt: Date(timeIntervalSince1970: 1)
        ))
        store.attach(TranslationResult(
            id: "final",
            sourceID: "block-1",
            laneID: lane,
            sourceText: "We confirm the owner.",
            translatedText: "我们确认负责人。",
            displayState: .stableFinal,
            createdAt: Date(timeIntervalSince1970: 3),
            sourceCreatedAt: Date(timeIntervalSince1970: 1),
            sourceSegmentIDs: ["segment-1"]
        ))

        XCTAssertEqual(store.visibleResult(for: lane)?.id, "final")
        XCTAssertEqual(store.resultsForSourceSegmentIDs(["segment-1"]).map(\.id), ["final"])
    }

    func testHydratesPersistedFinalResult() throws {
        let lane = TranslationLaneID(speaker: .default, sourceLocale: "en-US", targetLocale: "zh-CN")
        let record = TranslationResultPersistenceRecord(
            meetingID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            resultID: "final",
            sourceID: "block-1",
            laneID: lane,
            sourceSegmentIDs: ["segment-1", "segment-2"],
            sourceTextHash: "hash",
            sourceText: "Select settings and about then choose public preview.",
            translatedText: "选择设置和关于，然后选择公共预览。",
            displayState: .stableFinal,
            boundaryReason: .providerHardBoundary,
            providerID: "test",
            createdAt: Date(timeIntervalSince1970: 1),
            finalizedAt: Date(timeIntervalSince1970: 2)
        )

        var store = TranslationResultStore()
        store.hydrate(from: [record])

        XCTAssertEqual(store.visibleResult(for: lane)?.translatedText, "选择设置和关于，然后选择公共预览。")
        XCTAssertEqual(store.resultsForSourceSegmentIDs(["segment-2"]).first?.displayState, .stableFinal)
    }
}
```

- [ ] **Step 2: Run focused tests and verify failure**

Run:

```bash
swift test --filter TranslationResultStoreTests
```

Expected: FAIL because `TranslationResultPersistenceRecord`, `sourceSegmentIDs`, `hydrate(from:)`, and `resultsForSourceSegmentIDs(_:)` do not exist.

- [ ] **Step 3: Add persistence record and source IDs**

In `Sources/MeetingAgentCore/TranslationExperienceModels.swift`, extend `TranslationResult` and add the persistence record:

```swift
public struct TranslationResult: Codable, Equatable, Identifiable {
    public var id: String
    public var sourceID: String
    public var laneID: TranslationLaneID
    public var sourceText: String
    public var translatedText: String
    public var displayState: TranslationDisplayState
    public var createdAt: Date
    public var sourceCreatedAt: Date
    public var riskFlags: Set<TranslationRiskFlag>
    public var sourceSegmentIDs: [String]

    public init(
        id: String,
        sourceID: String,
        laneID: TranslationLaneID,
        sourceText: String,
        translatedText: String,
        displayState: TranslationDisplayState,
        createdAt: Date,
        sourceCreatedAt: Date,
        riskFlags: Set<TranslationRiskFlag> = [],
        sourceSegmentIDs: [String] = []
    ) {
        self.id = id
        self.sourceID = sourceID
        self.laneID = laneID
        self.sourceText = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.translatedText = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayState = displayState
        self.createdAt = createdAt
        self.sourceCreatedAt = sourceCreatedAt
        self.riskFlags = riskFlags
        self.sourceSegmentIDs = sourceSegmentIDs
    }
}

public struct TranslationResultPersistenceRecord: Codable, Equatable, Identifiable {
    public var id: String { resultID }
    public var meetingID: UUID
    public var resultID: String
    public var sourceID: String
    public var laneID: TranslationLaneID
    public var sourceSegmentIDs: [String]
    public var sourceTextHash: String
    public var sourceText: String
    public var translatedText: String
    public var displayState: TranslationDisplayState
    public var boundaryReason: StableTranslationBoundaryReason?
    public var providerID: String
    public var createdAt: Date
    public var finalizedAt: Date?

    public init(
        meetingID: UUID,
        resultID: String,
        sourceID: String,
        laneID: TranslationLaneID,
        sourceSegmentIDs: [String],
        sourceTextHash: String,
        sourceText: String,
        translatedText: String,
        displayState: TranslationDisplayState,
        boundaryReason: StableTranslationBoundaryReason?,
        providerID: String,
        createdAt: Date,
        finalizedAt: Date?
    ) {
        self.meetingID = meetingID
        self.resultID = resultID
        self.sourceID = sourceID
        self.laneID = laneID
        self.sourceSegmentIDs = sourceSegmentIDs
        self.sourceTextHash = sourceTextHash
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.displayState = displayState
        self.boundaryReason = boundaryReason
        self.providerID = providerID
        self.createdAt = createdAt
        self.finalizedAt = finalizedAt
    }
}
```

- [ ] **Step 4: Add store hydration and source mapping**

In `Sources/MeetingAgentCore/TranslationResultStore.swift`, add indexes:

```swift
public struct TranslationResultStore: Equatable {
    private var resultsByLane: [TranslationLaneID: [TranslationResult]] = [:]
    private var resultIDsBySourceSegmentID: [String: Set<String>] = [:]
    private var resultsByID: [String: TranslationResult] = [:]

    public init() {}

    public mutating func attach(_ result: TranslationResult) {
        var laneResults = resultsByLane[result.laneID, default: []]
        laneResults.removeAll { $0.id == result.id }
        laneResults.append(result)
        laneResults.sort {
            if $0.displayState.priority == $1.displayState.priority {
                return $0.createdAt < $1.createdAt
            }
            return $0.displayState.priority < $1.displayState.priority
        }
        resultsByLane[result.laneID] = laneResults
        resultsByID[result.id] = result
        for sourceSegmentID in result.sourceSegmentIDs {
            resultIDsBySourceSegmentID[sourceSegmentID, default: []].insert(result.id)
        }
    }

    public mutating func hydrate(from records: [TranslationResultPersistenceRecord]) {
        for record in records {
            attach(TranslationResult(
                id: record.resultID,
                sourceID: record.sourceID,
                laneID: record.laneID,
                sourceText: record.sourceText,
                translatedText: record.translatedText,
                displayState: record.displayState,
                createdAt: record.finalizedAt ?? record.createdAt,
                sourceCreatedAt: record.createdAt,
                sourceSegmentIDs: record.sourceSegmentIDs
            ))
        }
    }

    public func stableResults(forMeetingID meetingID: UUID? = nil) -> [TranslationResult] {
        resultsByID.values
            .filter { $0.displayState == .stableFinal }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func resultsForSourceSegmentIDs(_ ids: [String]) -> [TranslationResult] {
        let resultIDs = ids.reduce(into: Set<String>()) { partial, id in
            partial.formUnion(resultIDsBySourceSegmentID[id, default: []])
        }
        return resultIDs.compactMap { resultsByID[$0] }.sorted { $0.createdAt < $1.createdAt }
    }
}
```

- [ ] **Step 5: Add JSONL persistence store tests**

Create `Tests/MeetingAgentCoreTests/TranslationResultPersistenceStoreTests.swift`:

```swift
import XCTest
@testable import MeetingAgentCore

final class TranslationResultPersistenceStoreTests: XCTestCase {
    func testAppendsAndReadsTranslationResultRecords() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("translation-result-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = TranslationResultPersistenceStore(directoryURL: directory)
        let meetingID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let lane = TranslationLaneID(speaker: .default, sourceLocale: "en-US", targetLocale: "zh-CN")
        let record = TranslationResultPersistenceRecord(
            meetingID: meetingID,
            resultID: "final",
            sourceID: "block-1",
            laneID: lane,
            sourceSegmentIDs: ["segment-1"],
            sourceTextHash: "hash",
            sourceText: "We approve the launch.",
            translatedText: "我们批准发布。",
            displayState: .stableFinal,
            boundaryReason: .terminalPunctuation,
            providerID: "test",
            createdAt: Date(timeIntervalSince1970: 1),
            finalizedAt: Date(timeIntervalSince1970: 2)
        )

        try store.append(record)
        let records = try store.load()

        XCTAssertEqual(records, [record])
    }
}
```

- [ ] **Step 6: Implement JSONL store**

Create `Sources/MeetingAgentCore/TranslationResultPersistenceStore.swift`:

```swift
import Foundation

public struct TranslationResultPersistenceStore {
    public let fileURL: URL

    public init(directoryURL: URL) {
        self.fileURL = directoryURL.appendingPathComponent("translation-results.jsonl")
    }

    public func append(_ record: TranslationResultPersistenceRecord) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        var line = data
        line.append(0x0A)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.close()
        } else {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try line.write(to: fileURL, options: .atomic)
        }
    }

    public func load() throws -> [TranslationResultPersistenceRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try text
            .split(separator: "\n")
            .map { line in
                try decoder.decode(TranslationResultPersistenceRecord.self, from: Data(line.utf8))
            }
    }
}
```

- [ ] **Step 7: Run tests and commit**

Run:

```bash
swift test --filter TranslationResultStoreTests
swift test --filter TranslationResultPersistenceStoreTests
```

Expected: PASS.

Commit:

```bash
git add Sources/MeetingAgentCore/TranslationExperienceModels.swift Sources/MeetingAgentCore/TranslationResultStore.swift Sources/MeetingAgentCore/TranslationResultPersistenceStore.swift Tests/MeetingAgentCoreTests/TranslationResultStoreTests.swift Tests/MeetingAgentCoreTests/TranslationResultPersistenceStoreTests.swift
git commit -m "feat: persist stable translation results"
```

## Task 3: Implement Pending-Latest Live Translation Scheduling

**Files:**
- Modify: `Sources/MeetingAgentCore/LiveTranslationScheduler.swift`
- Test: `Tests/MeetingAgentCoreTests/LiveTranslationSchedulerTests.swift`

- [ ] **Step 1: Write failing pending-latest test**

Add this test to `Tests/MeetingAgentCoreTests/LiveTranslationSchedulerTests.swift`:

```swift
func testInFlightLaneKeepsOnlyLatestPendingUnit() async {
    let lane = TranslationLaneID(speaker: .default, sourceLocale: "en-US", targetLocale: "zh-CN")
    let provider = LiveRecordingTranslationProvider(translations: [
        "unit-1": "第一版",
        "unit-3": "第三版"
    ])
    provider.delayNanoseconds = 100_000_000
    var scheduler = LiveTranslationScheduler(
        provider: provider,
        configuration: LiveTranslationSchedulerConfiguration(maxConcurrentRequests: 1, maxCallsPerMinute: 10, draftTimeoutNanoseconds: 1_000_000_000)
    )
    let first = LiveTranslationUnit(id: "unit-1", laneID: lane, stablePrefixText: "We confirm the initial owner", sourceSegmentIDs: ["segment-1"], revision: 1, createdAt: Date(), deadline: Date().addingTimeInterval(4))
    let second = LiveTranslationUnit(id: "unit-2", laneID: lane, stablePrefixText: "We confirm the initial owner and rollout", sourceSegmentIDs: ["segment-1"], revision: 2, createdAt: Date(), deadline: Date().addingTimeInterval(4))
    let third = LiveTranslationUnit(id: "unit-3", laneID: lane, stablePrefixText: "We confirm the initial owner and rollout date", sourceSegmentIDs: ["segment-1"], revision: 3, createdAt: Date(), deadline: Date().addingTimeInterval(4))

    async let firstUpdates = scheduler.schedule([first])
    _ = await scheduler.schedule([second])
    _ = await scheduler.schedule([third])
    let completed = await firstUpdates
    let drained = await scheduler.drainPending()

    XCTAssertEqual(provider.requests.map(\.id), ["unit-1", "unit-3"])
    XCTAssertEqual((completed + drained).last?.sourceID, "unit-3")
}
```

Update `LiveRecordingTranslationProvider` in the test file to support delay:

```swift
var delayNanoseconds: UInt64 = 0

func translate(transcript: TranscriptDocument, options: TranslationOptions) async throws -> TranslatedTranscript {
    if delayNanoseconds > 0 {
        try? await Task.sleep(nanoseconds: delayNanoseconds)
    }
    let segment = transcript.segments[0]
    requests.append(Request(id: segment.id, sourceText: segment.text))
    return TranslatedTranscript(
        sourceLocale: options.sourceLocale,
        targetLocale: options.targetLocale,
        segments: [
            BilingualSubtitleSegment(
                id: segment.id,
                sourceText: segment.text,
                targetText: translations[segment.id] ?? "translated \(segment.text)"
            )
        ],
        provenance: PipelineProvenance(profileID: "test-live", successfulProviders: ["test-live"])
    )
}
```

- [ ] **Step 2: Run focused test and verify failure**

Run:

```bash
swift test --filter LiveTranslationSchedulerTests/testInFlightLaneKeepsOnlyLatestPendingUnit
```

Expected: FAIL because `drainPending()` does not exist and current scheduler does not model in-flight lane state.

- [ ] **Step 3: Add lane state and pending latest**

In `Sources/MeetingAgentCore/LiveTranslationScheduler.swift`, add:

```swift
private struct LiveTranslationLaneState {
    var inFlightUnitID: String?
    var pendingLatestUnit: LiveTranslationUnit?
    var lastVisibleSourcePrefix: String = ""
    var lastRequestedSourcePrefix: String = ""
}

private var laneStates: [TranslationLaneID: LiveTranslationLaneState] = [:]
```

Update `schedule(_:)` to record latest pending when a lane is in flight:

```swift
public mutating func schedule(_ units: [LiveTranslationUnit]) async -> [TranslationResult] {
    var results: [TranslationResult] = []

    for unit in units {
        var state = laneStates[unit.laneID, default: LiveTranslationLaneState()]
        if state.inFlightUnitID != nil {
            state.pendingLatestUnit = unit
            laneStates[unit.laneID] = state
            continue
        }
        if let result = await scheduleImmediately(unit, state: &state) {
            results.append(result)
        }
        laneStates[unit.laneID] = state
    }

    return results
}
```

Move existing per-unit translation logic into:

```swift
private mutating func scheduleImmediately(
    _ unit: LiveTranslationUnit,
    state: inout LiveTranslationLaneState
) async -> TranslationResult? {
    let cacheKey = CacheKey(laneID: unit.laneID, sourceText: unit.stablePrefixText)
    if let cachedResult = cachedResultByLaneAndPrefix[cacheKey] {
        return cachedResult.rebased(to: unit, createdAt: now())
    }

    pruneRequestTimes()
    guard requestTimes.count < configuration.maxCallsPerMinute else {
        return disabledBudgetResult(for: unit)
    }

    guard state.lastRequestedSourcePrefix != unit.stablePrefixText else {
        return nil
    }

    requestTimes.append(now())
    state.lastRequestedSourcePrefix = unit.stablePrefixText
    state.inFlightUnitID = unit.id
    let result = await translate(unit)
    state.inFlightUnitID = nil
    if result.displayState == .liveFresh {
        state.lastVisibleSourcePrefix = unit.stablePrefixText
        cachedResultByLaneAndPrefix[cacheKey] = result
    }
    return result
}
```

- [ ] **Step 4: Add drainPending**

Add to `LiveTranslationScheduler`:

```swift
public mutating func drainPending() async -> [TranslationResult] {
    var results: [TranslationResult] = []
    let lanes = laneStates.keys
    for lane in lanes {
        guard var state = laneStates[lane],
              state.inFlightUnitID == nil,
              let pending = state.pendingLatestUnit
        else { continue }
        state.pendingLatestUnit = nil
        if let result = await scheduleImmediately(pending, state: &state) {
            results.append(result)
        }
        laneStates[lane] = state
    }
    return results
}
```

- [ ] **Step 5: Run tests and commit**

Run:

```bash
swift test --filter LiveTranslationSchedulerTests
```

Expected: PASS.

Commit:

```bash
git add Sources/MeetingAgentCore/LiveTranslationScheduler.swift Tests/MeetingAgentCoreTests/LiveTranslationSchedulerTests.swift
git commit -m "feat: schedule live translations by latest pending unit"
```

## Task 4: Final Translation Scheduler Produces Persistable Stable Results

**Files:**
- Modify: `Sources/MeetingAgentCore/AccurateTranslationScheduler.swift`
- Test: `Tests/MeetingAgentCoreTests/AccurateTranslationSchedulerTests.swift`

- [ ] **Step 1: Write failing accurate scheduler tests**

Create `Tests/MeetingAgentCoreTests/AccurateTranslationSchedulerTests.swift`:

```swift
import XCTest
@testable import MeetingAgentCore

final class AccurateTranslationSchedulerTests: XCTestCase {
    func testStableBlockTranslatesToStableFinalWithSourceSegments() async {
        let lane = TranslationLaneID(speaker: .default, sourceLocale: "en-US", targetLocale: "zh-CN")
        let provider = AccurateRecordingTranslationProvider(translations: ["block-1": "我们批准发布。"])
        var scheduler = AccurateTranslationScheduler(provider: provider)
        let block = StableTranslationBlock(
            id: "block-1",
            laneID: lane,
            sourceText: "We approved the launch.",
            sourceSegmentIDs: ["segment-1"],
            boundaryReason: .terminalPunctuation,
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let results = await scheduler.translate([block])

        XCTAssertEqual(results.first?.displayState, .stableFinal)
        XCTAssertEqual(results.first?.translatedText, "我们批准发布。")
        XCTAssertEqual(results.first?.sourceSegmentIDs, ["segment-1"])
    }

    func testFailureReturnsRecoverableFinalResultWithSourceSegments() async {
        let lane = TranslationLaneID(speaker: .default, sourceLocale: "en-US", targetLocale: "zh-CN")
        let provider = FailingAccurateTranslationProvider()
        var scheduler = AccurateTranslationScheduler(provider: provider, configuration: AccurateTranslationSchedulerConfiguration(retryCount: 0))
        let block = StableTranslationBlock(
            id: "block-1",
            laneID: lane,
            sourceText: "We approved the launch.",
            sourceSegmentIDs: ["segment-1"],
            boundaryReason: .terminalPunctuation,
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let results = await scheduler.translate([block])

        XCTAssertEqual(results.first?.displayState, .failedRecoverable)
        XCTAssertEqual(results.first?.sourceSegmentIDs, ["segment-1"])
    }
}
```

Add local providers:

```swift
private final class AccurateRecordingTranslationProvider: TextTranslationProvider {
    let translations: [String: String]
    init(translations: [String: String]) { self.translations = translations }

    var descriptor: ProviderDescriptor {
        ProviderDescriptor(id: "test-accurate", displayName: "Test Accurate", capability: .textTranslation, executionMode: .hosted, supportedSourceLocales: ["*"], supportedTargetLocales: ["*"], requiresNetwork: false, requiresAPIKey: false)
    }

    func translate(transcript: TranscriptDocument, options: TranslationOptions) async throws -> TranslatedTranscript {
        let segment = transcript.segments[0]
        return TranslatedTranscript(
            sourceLocale: options.sourceLocale,
            targetLocale: options.targetLocale,
            segments: [BilingualSubtitleSegment(id: segment.id, sourceText: segment.text, targetText: translations[segment.id] ?? "translated")],
            provenance: PipelineProvenance(profileID: "test-accurate", successfulProviders: ["test-accurate"])
        )
    }
}

private final class FailingAccurateTranslationProvider: TextTranslationProvider {
    var descriptor: ProviderDescriptor {
        ProviderDescriptor(id: "test-accurate-failing", displayName: "Test Accurate Failing", capability: .textTranslation, executionMode: .hosted, supportedSourceLocales: ["*"], supportedTargetLocales: ["*"], requiresNetwork: false, requiresAPIKey: false)
    }

    func translate(transcript: TranscriptDocument, options: TranslationOptions) async throws -> TranslatedTranscript {
        throw NSError(domain: "translation", code: 1)
    }
}
```

- [ ] **Step 2: Run focused tests and verify failure**

Run:

```bash
swift test --filter AccurateTranslationSchedulerTests
```

Expected: FAIL because `TranslationResult` currently returned by accurate scheduler lacks source segment IDs.

- [ ] **Step 3: Attach source segment IDs in accurate results**

In `Sources/MeetingAgentCore/AccurateTranslationScheduler.swift`, set `sourceSegmentIDs` in all `TranslationResult` initializers:

```swift
return TranslationResult(
    id: "\(block.id)-stable-result",
    sourceID: block.id,
    laneID: block.laneID,
    sourceText: block.sourceText,
    translatedText: translated.segments.first?.targetText ?? "",
    displayState: .stableFinal,
    createdAt: now(),
    sourceCreatedAt: block.createdAt,
    sourceSegmentIDs: block.sourceSegmentIDs
)
```

For failure results:

```swift
return TranslationResult(
    id: "\(block.id)-stable-failed",
    sourceID: block.id,
    laneID: block.laneID,
    sourceText: block.sourceText,
    translatedText: "",
    displayState: .failedRecoverable,
    createdAt: now(),
    sourceCreatedAt: block.createdAt,
    sourceSegmentIDs: block.sourceSegmentIDs
)
```

- [ ] **Step 4: Run tests and commit**

Run:

```bash
swift test --filter AccurateTranslationSchedulerTests
swift test --filter TranslationExperiencePipelineTests
```

Expected: PASS.

Commit:

```bash
git add Sources/MeetingAgentCore/AccurateTranslationScheduler.swift Tests/MeetingAgentCoreTests/AccurateTranslationSchedulerTests.swift
git commit -m "feat: return stable final translation results"
```

## Task 5: Add Pipeline Stop Finalization And Persistence Events

**Files:**
- Modify: `Sources/MeetingAgentCore/TranslationExperiencePipeline.swift`
- Test: `Tests/MeetingAgentCoreTests/TranslationExperiencePipelineTests.swift`

- [ ] **Step 1: Write failing pipeline tests**

Add to `Tests/MeetingAgentCoreTests/TranslationExperiencePipelineTests.swift`:

```swift
func testFlushAndFinalizePersistsStableFinalOnly() async {
    let provider = PipelineTranslationProvider(translations: [
        "stable-expected": "我们会复查上线状态。"
    ])
    var persisted: [TranslationResultPersistenceRecord] = []
    var pipeline = TranslationExperiencePipeline(
        meetingID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        sourceLocale: "en-US",
        targetLocale: "zh-CN",
        liveProvider: provider,
        accurateProvider: provider,
        persistFinalResult: { record in persisted.append(record) }
    )
    let segment = TranscriptSegment(
        id: "segment-1",
        text: "We should review the rollout status",
        language: "en-US",
        isFinal: true,
        speechFinal: false,
        createdAt: Date(timeIntervalSince1970: 1)
    )

    _ = await pipeline.apply(segments: [segment], now: Date(timeIntervalSince1970: 2))
    let snapshot = await pipeline.flushAndFinalize(now: Date(timeIntervalSince1970: 3))

    XCTAssertTrue(snapshot.liveResults.isEmpty)
    XCTAssertEqual(snapshot.stableResults.count, 1)
    XCTAssertEqual(persisted.count, 1)
    XCTAssertEqual(persisted.first?.displayState, .stableFinal)
    XCTAssertEqual(persisted.first?.sourceSegmentIDs, ["segment-1"])
}
```

Update `PipelineTranslationProvider.translate` so manual stop blocks can use deterministic translations without knowing the generated stable hash:

```swift
let target = translations[segment.id] ?? translations["stable-expected"] ?? "translated"
```

- [ ] **Step 2: Run focused test and verify failure**

Run:

```bash
swift test --filter TranslationExperiencePipelineTests/testFlushAndFinalizePersistsStableFinalOnly
```

Expected: FAIL because the pipeline has no `meetingID`, no `persistFinalResult`, and no `flushAndFinalize(now:)`.

- [ ] **Step 3: Extend pipeline initializer and snapshot**

In `Sources/MeetingAgentCore/TranslationExperiencePipeline.swift`, update the struct:

```swift
public struct TranslationExperiencePipeline {
    private let meetingID: UUID
    private var unitBuilder: TranslationUnitBuilder
    private var liveScheduler: LiveTranslationScheduler
    private var accurateScheduler: AccurateTranslationScheduler
    private var resultStore = TranslationResultStore()
    private let persistFinalResult: ((TranslationResultPersistenceRecord) -> Void)?

    public init(
        meetingID: UUID = UUID(),
        sourceLocale: String,
        targetLocale: String,
        liveProvider: TextTranslationProvider,
        accurateProvider: TextTranslationProvider,
        persistFinalResult: ((TranslationResultPersistenceRecord) -> Void)? = nil
    ) {
        self.meetingID = meetingID
        self.unitBuilder = TranslationUnitBuilder(sourceLocale: sourceLocale, targetLocale: targetLocale)
        self.liveScheduler = LiveTranslationScheduler(provider: liveProvider)
        self.accurateScheduler = AccurateTranslationScheduler(provider: accurateProvider)
        self.persistFinalResult = persistFinalResult
    }
}
```

- [ ] **Step 4: Add final persistence conversion**

Add helper in `TranslationExperiencePipeline`:

```swift
private func persistenceRecord(
    for result: TranslationResult,
    boundaryReason: StableTranslationBoundaryReason?,
    providerID: String,
    finalizedAt: Date
) -> TranslationResultPersistenceRecord? {
    guard result.displayState == .stableFinal || result.displayState == .failedRecoverable else { return nil }
    return TranslationResultPersistenceRecord(
        meetingID: meetingID,
        resultID: result.id,
        sourceID: result.sourceID,
        laneID: result.laneID,
        sourceSegmentIDs: result.sourceSegmentIDs,
        sourceTextHash: StableTranslationBlock.stableHash(result.sourceText),
        sourceText: result.sourceText,
        translatedText: result.translatedText,
        displayState: result.displayState,
        boundaryReason: boundaryReason,
        providerID: providerID,
        createdAt: result.sourceCreatedAt,
        finalizedAt: finalizedAt
    )
}
```

- [ ] **Step 5: Add flushAndFinalize**

Add:

```swift
public mutating func flushAndFinalize(now: Date = Date()) async -> TranslationExperiencePipelineSnapshot {
    let blocks = unitBuilder.flushOpenBlocks(now: now)
    let stableResults = await accurateScheduler.translate(blocks)
    for result in stableResults {
        resultStore.attach(result)
        if let record = persistenceRecord(
            for: result,
            boundaryReason: blocks.first(where: { $0.id == result.sourceID })?.boundaryReason,
            providerID: "accurate",
            finalizedAt: now
        ) {
            persistFinalResult?(record)
        }
    }
    let lanes = Set(stableResults.map(\.laneID))
    let visibleResults = lanes.compactMap { resultStore.visibleResult(for: $0) }
    return TranslationExperiencePipelineSnapshot(
        liveResults: [],
        stableResults: stableResults,
        visibleResults: visibleResults
    )
}
```

- [ ] **Step 6: Persist final results during apply**

In `apply(segments:now:)`, after accurate stable results are attached, persist stable final/failure records:

```swift
for result in stableResults {
    if let record = persistenceRecord(
        for: result,
        boundaryReason: units.stableBlocks.first(where: { $0.id == result.sourceID })?.boundaryReason,
        providerID: "accurate",
        finalizedAt: now
    ) {
        persistFinalResult?(record)
    }
}
```

- [ ] **Step 7: Run tests and commit**

Run:

```bash
swift test --filter TranslationExperiencePipelineTests
```

Expected: PASS.

Commit:

```bash
git add Sources/MeetingAgentCore/TranslationExperiencePipeline.swift Tests/MeetingAgentCoreTests/TranslationExperiencePipelineTests.swift
git commit -m "feat: finalize unit translations on stop"
```

## Task 6: Route Active Recording Translation Through Unit Pipeline

**Files:**
- Modify: `Sources/MeetingAgentCore/LiveCaptionPipeline.swift`
- Modify: `Sources/MeetingAgentCore/RealtimeCaptionSession.swift`
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Test: `Tests/MeetingAgentCoreTests/LiveCaptionPipelineTests.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] **Step 1: Write failing integration test for disabling legacy active draft scheduling**

Add a test near existing live caption translation tests in `Tests/MeetingAgentCoreTests/LiveCaptionPipelineTests.swift`:

```swift
func testActiveRecordingUnitTranslationDoesNotUseCaptionDraftScheduler() async {
    let provider = RecordingCaptionTranslationProvider()
    var pipeline = LiveCaptionPipeline(
        translationProvider: provider,
        translationMode: .unitPipelineActiveRecording
    )
    let segment = TranscriptSegment(
        id: "segment-1",
        text: "Select settings and about",
        language: "en-US",
        isFinal: false,
        createdAt: Date(timeIntervalSince1970: 1)
    )

    _ = pipeline.apply(TranscriptDocument(segments: [segment]), source: .realtime)
    _ = await pipeline.scheduleLivePendingTranslations()

    XCTAssertTrue(provider.requests.isEmpty)
}
```

Add enum expectation to the test by referencing the implementation planned in Step 3.

- [ ] **Step 2: Run focused test and verify failure**

Run:

```bash
swift test --filter LiveCaptionPipelineTests/testActiveRecordingUnitTranslationDoesNotUseCaptionDraftScheduler
```

Expected: FAIL because `translationMode` and `.unitPipelineActiveRecording` do not exist.

- [ ] **Step 3: Add internal translation mode**

In `Sources/MeetingAgentCore/LiveCaptionPipeline.swift`, add:

```swift
public enum LiveCaptionTranslationMode: Equatable {
    case legacyCaptionScheduler
    case unitPipelineActiveRecording
}
```

Add stored property:

```swift
private let translationMode: LiveCaptionTranslationMode
```

Update initializer:

```swift
public init(
    translationProvider: TextTranslationProvider? = nil,
    performanceEventLogger: PerformanceEventLogger? = nil,
    persistTranslation: ((CaptionTranslationAttachmentTarget, String, Bool) -> Bool)? = nil,
    translationMode: LiveCaptionTranslationMode = .legacyCaptionScheduler
) {
    self.translationMode = translationMode
    ...
}
```

- [ ] **Step 4: Gate legacy scheduling in active recording mode**

In `scheduleLivePendingTranslations()`, add before calling `translationScheduler.liveTranslationUpdates(for:)`:

```swift
guard translationMode == .legacyCaptionScheduler else {
    return snapshot()
}
```

This keeps legacy behavior available and prevents active recording from firing caption-turn draft translations once the unit pipeline is wired from the ViewModel.

- [ ] **Step 5: Add ViewModel pipeline owner**

In `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`, add properties:

```swift
private var translationExperiencePipeline: TranslationExperiencePipeline?
private var translationResultPersistenceStore: TranslationResultPersistenceStore?
```

When a meeting recording starts and a translation provider is available, create:

```swift
let persistenceStore = TranslationResultPersistenceStore(directoryURL: meetingDirectoryURL)
translationResultPersistenceStore = persistenceStore
translationExperiencePipeline = TranslationExperiencePipeline(
    meetingID: meetingID,
    sourceLocale: speechConfiguration.localeIdentifier,
    targetLocale: speechConfiguration.targetLocaleIdentifier,
    liveProvider: translationProvider,
    accurateProvider: translationProvider,
    persistFinalResult: { record in
        try? persistenceStore.append(record)
    }
)
```

Create the pipeline at the same point where the current recording session creates `liveCaptionPipeline`. Use the selected meeting ID from the new `MeetingRecord`, the meeting directory URL returned by the recording persistence store, `speechConfiguration.localeIdentifier`, `speechConfiguration.targetLocaleIdentifier`, and the already-resolved `translationProvider`.

- [ ] **Step 6: Feed transcript updates to the unit pipeline without blocking captions**

After realtime caption display has applied transcript updates, schedule unit translation in a detached task guarded by generation:

```swift
if var pipeline = translationExperiencePipeline {
    let document = currentTranscriptDocument
    Task { [weak self] in
        let snapshot = await pipeline.apply(segments: document.segments)
        await MainActor.run {
            guard let self else { return }
            self.translationExperiencePipeline = pipeline
            self.applyTranslationExperienceSnapshot(snapshot)
        }
    }
}
```

Implement `applyTranslationExperienceSnapshot(_:)` to update only translation overlay state. It must not mutate source caption text and must not clear existing translation when `snapshot.visibleResults` is empty.

- [ ] **Step 7: Run focused integration tests and commit**

Run:

```bash
swift test --filter LiveCaptionPipelineTests/testActiveRecordingUnitTranslationDoesNotUseCaptionDraftScheduler
swift test --filter TranslationExperiencePipelineTests
```

Expected: PASS.

Commit:

```bash
git add Sources/MeetingAgentCore/LiveCaptionPipeline.swift Sources/MeetingAgentCore/RealtimeCaptionSession.swift Sources/MeetingAgentCore/MeetingAgentViewModel.swift Tests/MeetingAgentCoreTests/LiveCaptionPipelineTests.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift
git commit -m "feat: route active translations through unit pipeline"
```

## Task 7: Stop Preview Publication And Finalize Units

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Modify: `Sources/MeetingAgentCore/TranslationExperiencePipeline.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] **Step 1: Write failing stop test**

Add to `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`:

```swift
func testStopRecordingFinalizesUnitTranslationsAndPublishesNoLatePreview() async throws {
    let provider = SlowRecordingTranslationProvider()
    let viewModel = MeetingAgentViewModel.testInstance(
        translationProvider: provider,
        liveCaptionPipelineUsesUnitTranslation: true
    )

    try await viewModel.startTestRecording()
    viewModel.injectTranscriptSegment(TranscriptSegment(
        id: "segment-1",
        text: "We should review the rollout status",
        language: "en-US",
        isFinal: true,
        speechFinal: false,
        createdAt: Date(timeIntervalSince1970: 1)
    ))
    await viewModel.stopRecording()
    provider.finishDelayedPreview()
    try await Task.sleep(nanoseconds: 50_000_000)

    XCTAssertEqual(viewModel.performanceEventCount(named: "translation_preview_published_after_stop"), 0)
    XCTAssertTrue(viewModel.persistedTranslationResults.contains { $0.displayState == .stableFinal })
}
```

Add the test seam below to `MeetingAgentViewModelTests.swift` if the file does not already expose equivalent helpers:

```swift
private extension MeetingAgentViewModel {
    static func testInstance(
        translationProvider: TextTranslationProvider,
        liveCaptionPipelineUsesUnitTranslation: Bool
    ) -> MeetingAgentViewModel {
        MeetingAgentViewModel(
            translationProviderOverride: translationProvider,
            liveCaptionPipelineUsesUnitTranslation: liveCaptionPipelineUsesUnitTranslation
        )
    }

    func startTestRecording() async throws {
        try await startRecording()
    }

    func injectTranscriptSegment(_ segment: TranscriptSegment) {
        applyTestTranscriptDocument(TranscriptDocument(segments: [segment]))
    }

    func performanceEventCount(named eventName: String) -> Int {
        testPerformanceEvents.filter { $0.event == eventName }.count
    }

    var persistedTranslationResults: [TranslationResultPersistenceRecord] {
        testPersistedTranslationResults
    }
}
```

Add these internal initializer parameters to `MeetingAgentViewModel.init` with default values so production call sites remain unchanged:

```swift
translationProviderOverride: TextTranslationProvider? = nil,
liveCaptionPipelineUsesUnitTranslation: Bool = false,
testPerformanceEventSink: ((PerformanceEvent) -> Void)? = nil,
testPersistedTranslationResultSink: ((TranslationResultPersistenceRecord) -> Void)? = nil
```

When `translationProviderOverride` is non-nil, use it instead of resolving the app-configured translation provider. When `liveCaptionPipelineUsesUnitTranslation` is true, construct `LiveCaptionPipeline` with `.unitPipelineActiveRecording`.

- [ ] **Step 2: Run focused test and verify failure**

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testStopRecordingFinalizesUnitTranslationsAndPublishesNoLatePreview
```

Expected: FAIL because stop does not call unit finalization and there is no generation guard for late preview publication.

- [ ] **Step 3: Add translation generation guard**

In `MeetingAgentViewModel`, add:

```swift
private var activeTranslationExperienceGeneration = 0
private var translationPreviewClosed = false
```

When recording starts:

```swift
activeTranslationExperienceGeneration += 1
translationPreviewClosed = false
```

When stop begins:

```swift
activeTranslationExperienceGeneration += 1
translationPreviewClosed = true
```

In async preview snapshot publication:

```swift
let generation = activeTranslationExperienceGeneration
Task { [weak self] in
    let snapshot = await pipeline.apply(segments: document.segments)
    await MainActor.run {
        guard let self,
              generation == self.activeTranslationExperienceGeneration,
              !self.translationPreviewClosed
        else {
            self?.performanceEventLogger?.log("translation_preview_dropped_after_stop")
            return
        }
        self.translationExperiencePipeline = pipeline
        self.applyTranslationExperienceSnapshot(snapshot)
    }
}
```

- [ ] **Step 4: Call flushAndFinalize on stop**

In the stop-recording flow after caption/transcript flushing and before final UI hydration completes:

```swift
if var pipeline = translationExperiencePipeline {
    let snapshot = await pipeline.flushAndFinalize()
    translationExperiencePipeline = pipeline
    applyTranslationExperienceSnapshot(snapshot)
}
```

Update `applyTranslationExperienceSnapshot(_:)` so the generation guard is applied only before live preview publication. The method must always attach `stableFinal` results from `flushAndFinalize()` even when `translationPreviewClosed == true`.

- [ ] **Step 5: Run focused tests and commit**

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testStopRecordingFinalizesUnitTranslationsAndPublishesNoLatePreview
swift test --filter TranslationExperiencePipelineTests
```

Expected: PASS.

Commit:

```bash
git add Sources/MeetingAgentCore/MeetingAgentViewModel.swift Sources/MeetingAgentCore/TranslationExperiencePipeline.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift
git commit -m "fix: finalize unit translations on recording stop"
```

## Task 8: Hydrate Stable Final Results For Meeting Detail

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Modify: `Sources/MeetingAgentCore/RecordingTranscriptPersistenceStore.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] **Step 1: Write failing hydration test**

Add:

```swift
func testReopenedMeetingHydratesStableTranslationResultsWithoutProviderRequest() async throws {
    let meetingID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let directory = try makeTemporaryMeetingDirectory(meetingID: meetingID)
    let store = TranslationResultPersistenceStore(directoryURL: directory)
    let lane = TranslationLaneID(speaker: .default, sourceLocale: "en-US", targetLocale: "zh-CN")
    try store.append(TranslationResultPersistenceRecord(
        meetingID: meetingID,
        resultID: "final",
        sourceID: "block-1",
        laneID: lane,
        sourceSegmentIDs: ["segment-1"],
        sourceTextHash: "hash",
        sourceText: "We approved the launch.",
        translatedText: "我们批准发布。",
        displayState: .stableFinal,
        boundaryReason: .terminalPunctuation,
        providerID: "test",
        createdAt: Date(timeIntervalSince1970: 1),
        finalizedAt: Date(timeIntervalSince1970: 2)
    ))
    let provider = RecordingCaptionTranslationProvider()
    let viewModel = MeetingAgentViewModel.testInstance(
        translationProvider: provider,
        liveCaptionPipelineUsesUnitTranslation: true
    )

    try await viewModel.openMeetingForTest(meetingID: meetingID, directoryURL: directory)

    XCTAssertTrue(provider.requests.isEmpty)
    XCTAssertEqual(viewModel.visibleTranslationTextForTest(sourceSegmentID: "segment-1"), "我们批准发布。")
}
```

- [ ] **Step 2: Run focused test and verify failure**

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testReopenedMeetingHydratesStableTranslationResultsWithoutProviderRequest
```

Expected: FAIL because meeting hydration does not load `translation-results.jsonl`.

- [ ] **Step 3: Load persisted translation results during meeting selection**

In meeting selection/opening code:

```swift
let translationStore = TranslationResultPersistenceStore(directoryURL: meetingDirectoryURL)
let records = (try? translationStore.load()) ?? []
var resultStore = TranslationResultStore()
resultStore.hydrate(from: records)
applyHydratedTranslationResults(resultStore)
```

Add:

```swift
private func applyHydratedTranslationResults(_ store: TranslationResultStore) {
    for turn in liveCaptionTurns {
        let results = store.resultsForSourceSegmentIDs(turn.sourceSegmentIDs)
        guard let result = results.max(by: { $0.displayState.priority < $1.displayState.priority }) else { continue }
        liveCaptionStore.attachTranslation(
            result.translatedText,
            toTurnID: turn.id,
            freshness: .fresh,
            sourceText: result.sourceText,
            sourceCreatedAt: result.sourceCreatedAt,
            visibleUpdatedAt: result.createdAt
        )
        if result.displayState == .stableFinal {
            liveCaptionStore.markTranslationFinal(forTurnID: turn.id)
        }
    }
    publishLiveCaptionSnapshot()
}
```

Add `applyHydratedTranslationResults(_:)` next to the existing live-caption snapshot publication helpers in `MeetingAgentViewModel`. The method mutates the same caption store that `applyTranslationExperienceSnapshot(_:)` mutates, then publishes one caption snapshot.

- [ ] **Step 4: Run hydration tests and commit**

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testReopenedMeetingHydratesStableTranslationResultsWithoutProviderRequest
```

Expected: PASS.

Commit:

```bash
git add Sources/MeetingAgentCore/MeetingAgentViewModel.swift Sources/MeetingAgentCore/RecordingTranscriptPersistenceStore.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift
git commit -m "feat: hydrate stable translation results"
```

## Task 9: Add Performance Regression Assertions

**Files:**
- Modify: `Tests/MeetingAgentCoreTests/MeetingPerformanceAnalysisScriptTests.swift`
- Modify: `scripts/analyze-meeting-performance.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingPerformanceAnalysisScriptTests.swift`

- [ ] **Step 1: Add analyzer expectations for unit translation metrics**

Extend existing analyzer fixture tests to assert these metrics from the latest meeting/performance replay:

```swift
XCTAssertEqual(report.postStopPreviewEventCount, 0)
XCTAssertGreaterThanOrEqual(report.finalTranslationPersistedCoverage, 0.9)
XCTAssertLessThanOrEqual(report.liveTranslationCallsPerMinute, 15)
XCTAssertGreaterThanOrEqual(report.visibleTranslationCoverage, 0.9)
```

- [ ] **Step 2: Run analyzer tests and verify failure**

Run:

```bash
swift test --filter MeetingPerformanceAnalysisScriptTests
```

Expected: FAIL because the report model does not expose unit translation metrics.

- [ ] **Step 3: Add metrics to analyzer output**

In the existing analyzer script/model, add counters for:

```text
translation_unit_live_scheduled
translation_unit_live_stale
translation_unit_final_persisted
translation_preview_dropped_after_stop
translation_preview_published_after_stop
```

Compute:

```text
postStopPreviewEventCount = translation_preview_published_after_stop count after recording_stopped
finalTranslationPersistedCoverage = stable final persisted count / stable block count
liveTranslationCallsPerMinute = live scheduled count / meeting duration minutes
```

- [ ] **Step 4: Run analyzer tests and commit**

Run:

```bash
swift test --filter MeetingPerformanceAnalysisScriptTests
```

Expected: PASS.

Commit:

```bash
git add Tests/MeetingAgentCoreTests/MeetingPerformanceAnalysisScriptTests.swift scripts/analyze-meeting-performance.swift
git commit -m "test: measure unit translation performance"
```

## Task 10: Full Verification And Performance Comparison

**Files:**
- No source files should change unless verification exposes a bug.

- [ ] **Step 1: Run focused translation test suite**

Run:

```bash
swift test --filter TranslationUnitBuilderTests
swift test --filter LiveTranslationSchedulerTests
swift test --filter AccurateTranslationSchedulerTests
swift test --filter TranslationResultStoreTests
swift test --filter TranslationExperiencePipelineTests
```

Expected: PASS for every command.

- [ ] **Step 2: Run ViewModel and live caption focused tests**

Run:

```bash
swift test --filter LiveCaptionPipelineTests
swift test --filter MeetingAgentViewModelTests
```

Expected: PASS.

- [ ] **Step 3: Run required project test entrypoint**

Run:

```bash
make test
```

Expected: PASS with the repository coverage gate satisfied.

- [ ] **Step 4: Run performance comparison on regression wav/latest meeting**

Run the existing performance analysis command used by the repository for meeting artifacts and regression wav fixtures. Capture these values in the implementation summary:

```text
Caption Lag p50/p95/max
Time to First Translation
Translation Lag p50/p95/max
Visible Translation Coverage
Live Translation Calls Per Minute
Post-Stop Preview Events
Final Translation Persisted Coverage
Stale Visible Translation Rate
```

Expected:

```text
Caption p50/p95: no regression from previous main
Live Translation Calls Per Minute: <= 15
Post-Stop Preview Events: 0
Final Translation Persisted Coverage: >= 90%
Visible Translation Coverage: >= 90%
Stale Visible Translation Rate: < 10%
```

- [ ] **Step 5: Commit verification fixes only if needed**

When verification exposes a bug, write a focused failing test, fix the bug, rerun the relevant focused command, then rerun `make test`.

Commit format:

```bash
git add Sources/MeetingAgentCore Tests/MeetingAgentCoreTests scripts/analyze-meeting-performance.swift
git commit -m "fix: stabilize unit translation verification"
```

## Self-Review Checklist

- Spec coverage:
  - Unit-level active translation is covered by Tasks 1, 5, 6, and 7.
  - Non-blocking captions are covered by Tasks 6 and 10.
  - No fragmented tiny translation requests are covered by Tasks 1 and 3.
  - Stable final persistence is covered by Tasks 2, 4, 5, and 8.
  - Stop preview cancellation is covered by Task 7.
  - Performance proof is covered by Tasks 9 and 10.
- Placeholder scan:
  - This plan has no placeholder sections and no open-ended implementation steps.
- Type consistency:
  - `TranslationResultPersistenceRecord`, `sourceSegmentIDs`, `hydrate(from:)`, `resultsForSourceSegmentIDs(_:)`, and `flushAndFinalize(now:)` are introduced before tasks use them in integration.
