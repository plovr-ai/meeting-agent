# Translation Experience Architecture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a two-layer translation architecture that optimizes live translation for immediate understanding and stable translation for accurate meeting records.

**Architecture:** Add translation units and result state as a new boundary between transcript/caption state and provider calls. Live translation consumes stable prefixes with lane-based budgets; accurate translation consumes stable semantic blocks with richer context and authoritative persistence. Existing caption translation remains available as a legacy path until the new schedulers are wired and verified.

**Tech Stack:** Swift 5.9, Swift Package Manager, XCTest, existing `TextTranslationProvider`, `PerformanceEventLogger`, `TranscriptSegment`, and `LiveCaptionTurn` types.

---

## Scope Check

The approved spec covers two implementation surfaces: the isolated translation experience core and the later live-caption/UI/storage wiring. This plan implements the isolated core, telemetry metrics, and facade first. The wiring work should get a second full plan after this core API passes `make test`, because it touches active recording behavior, selected-meeting replay, persistence, and legacy scheduler retirement.

## File Structure

- Create `Sources/MeetingAgentCore/TranslationExperienceModels.swift`
  - Defines `LiveTranslationUnit`, `StableTranslationBlock`, `TranslationRiskFlag`, `TranslationDisplayState`, `TranslationResult`, `TranslationLaneID`, and budget/configuration types.
- Create `Sources/MeetingAgentCore/TranslationUnitBuilder.swift`
  - Converts transcript segments and current caption turns into live units and stable blocks.
- Create `Sources/MeetingAgentCore/LiveTranslationScheduler.swift`
  - Handles live lane scheduling, cache lookup, in-flight suppression, stale classification, and call budgets.
- Create `Sources/MeetingAgentCore/AccurateTranslationScheduler.swift`
  - Handles stable block translation, retries, timeout policy, and authoritative result production.
- Create `Sources/MeetingAgentCore/TranslationContextStore.swift`
  - Stores rolling stable context, glossary/key terms, speaker labels, and context hashes.
- Create `Sources/MeetingAgentCore/TranslationResultStore.swift`
  - Stores live and stable results separately and projects the visible translation state.
- Modify `Sources/MeetingAgentCore/LiveCaptionPipeline.swift`
  - Add optional new translation pipeline hooks while keeping legacy `CaptionTranslationScheduler` behavior available.
- Modify `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
  - Wire new translation result projection into live caption state after the schedulers are ready.
- Modify `scripts/analyze-meeting-performance.swift`
  - Add experience-first live/stable translation metrics and post-stop separation.
- Add tests:
  - `Tests/MeetingAgentCoreTests/TranslationExperienceModelsTests.swift`
  - `Tests/MeetingAgentCoreTests/TranslationUnitBuilderTests.swift`
  - `Tests/MeetingAgentCoreTests/LiveTranslationSchedulerTests.swift`
  - `Tests/MeetingAgentCoreTests/AccurateTranslationSchedulerTests.swift`
  - `Tests/MeetingAgentCoreTests/TranslationContextStoreTests.swift`
  - `Tests/MeetingAgentCoreTests/TranslationResultStoreTests.swift`
  - Update `Tests/MeetingAgentCoreTests/MeetingPerformanceAnalysisScriptTests.swift`

## Task 1: Add Translation Experience Models

**Files:**
- Create: `Sources/MeetingAgentCore/TranslationExperienceModels.swift`
- Test: `Tests/MeetingAgentCoreTests/TranslationExperienceModelsTests.swift`

- [ ] **Step 1: Write model tests**

Create `Tests/MeetingAgentCoreTests/TranslationExperienceModelsTests.swift`:

```swift
import XCTest
@testable import MeetingAgentCore

final class TranslationExperienceModelsTests: XCTestCase {
    func testLaneIDNormalizesLocaleAndSpeaker() {
        let lane = TranslationLaneID(
            speaker: TranscriptSpeaker(identifier: " speaker-1 ", label: "Alice"),
            sourceLocale: "en_US",
            targetLocale: "zh_CN"
        )

        XCTAssertEqual(lane.speakerID, "speaker-1")
        XCTAssertEqual(lane.sourceLocale, "en-US")
        XCTAssertEqual(lane.targetLocale, "zh-CN")
    }

    func testDisplayPriorityPrefersStableFinal() {
        XCTAssertGreaterThan(TranslationDisplayState.stableFinal.priority, TranslationDisplayState.liveFresh.priority)
        XCTAssertGreaterThan(TranslationDisplayState.liveFresh.priority, TranslationDisplayState.liveLagging.priority)
        XCTAssertGreaterThan(TranslationDisplayState.liveLagging.priority, TranslationDisplayState.liveCarried.priority)
        XCTAssertGreaterThan(TranslationDisplayState.liveCarried.priority, TranslationDisplayState.pending.priority)
    }

    func testLiveUnitTrimsStablePrefixAndTail() {
        let unit = LiveTranslationUnit(
            id: "unit-1",
            laneID: TranslationLaneID(speaker: .default, sourceLocale: "en-US", targetLocale: "zh-CN"),
            stablePrefixText: "  We should confirm the owner  ",
            unstableTailText: " today ",
            sourceSegmentIDs: ["segment-1"],
            contextBefore: "Earlier: launch plan.",
            revision: 2,
            createdAt: Date(timeIntervalSince1970: 10),
            deadline: Date(timeIntervalSince1970: 14),
            riskFlags: [.commitment]
        )

        XCTAssertEqual(unit.stablePrefixText, "We should confirm the owner")
        XCTAssertEqual(unit.unstableTailText, "today")
        XCTAssertEqual(unit.riskFlags, [.commitment])
        XCTAssertFalse(unit.isEmpty)
    }

    func testStableBlockComputesHashesFromSourceAndContext() {
        let lane = TranslationLaneID(speaker: .default, sourceLocale: "en-US", targetLocale: "zh-CN")
        let block = StableTranslationBlock(
            id: "block-1",
            laneID: lane,
            sourceText: "We approved the launch date.",
            sourceSegmentIDs: ["segment-1"],
            previousBlockSummary: "Team discussed launch readiness.",
            meetingGoalContext: "Confirm launch readiness.",
            keyTerms: [MeetingKeyTerm(id: "launch", value: "launch", translationHint: "上线")],
            boundaryReason: .terminalPunctuation,
            createdAt: Date(timeIntervalSince1970: 20)
        )

        XCTAssertFalse(block.sourceTextHash.isEmpty)
        XCTAssertFalse(block.contextHash.isEmpty)
        XCTAssertNotEqual(block.sourceTextHash, block.contextHash)
    }
}
```

- [ ] **Step 2: Run tests and verify failure**

Run:

```bash
swift test --filter TranslationExperienceModelsTests
```

Expected: build fails because `TranslationLaneID`, `TranslationDisplayState`, `LiveTranslationUnit`, `StableTranslationBlock`, and `TranslationRiskFlag` do not exist.

- [ ] **Step 3: Add model implementation**

Create `Sources/MeetingAgentCore/TranslationExperienceModels.swift`:

```swift
import Foundation

public enum TranslationRiskFlag: String, Codable, Equatable, Hashable, CaseIterable {
    case number
    case dateOrTime
    case negation
    case commitment
    case namedEntity
    case speakerChanged
    case localeChanged
}

public enum StableTranslationBoundaryReason: String, Codable, Equatable {
    case providerHardBoundary
    case speakerChanged
    case terminalPunctuation
    case pause
    case maxDuration
    case maxLength
    case manualStop
}

public enum TranslationDisplayState: String, Codable, Equatable {
    case none
    case pending
    case liveFresh
    case liveLagging
    case liveCarried
    case stableFinal
    case failedRecoverable
    case disabledBudget

    public var priority: Int {
        switch self {
        case .stableFinal: return 70
        case .liveFresh: return 60
        case .liveLagging: return 50
        case .liveCarried: return 40
        case .pending: return 30
        case .failedRecoverable: return 20
        case .disabledBudget: return 10
        case .none: return 0
        }
    }
}

public struct TranslationLaneID: Codable, Equatable, Hashable {
    public var speakerID: String
    public var sourceLocale: String
    public var targetLocale: String

    public init(speaker: TranscriptSpeaker, sourceLocale: String, targetLocale: String) {
        self.speakerID = speaker.identifier?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "default"
        self.sourceLocale = Self.normalizedLocale(sourceLocale)
        self.targetLocale = Self.normalizedLocale(targetLocale)
    }

    static func normalizedLocale(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "_", with: "-")
    }
}

public struct LiveTranslationUnit: Codable, Equatable, Identifiable {
    public var id: String
    public var laneID: TranslationLaneID
    public var stablePrefixText: String
    public var unstableTailText: String
    public var sourceSegmentIDs: [String]
    public var contextBefore: String
    public var revision: Int
    public var createdAt: Date
    public var deadline: Date
    public var riskFlags: Set<TranslationRiskFlag>

    public var isEmpty: Bool {
        stablePrefixText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public init(
        id: String,
        laneID: TranslationLaneID,
        stablePrefixText: String,
        unstableTailText: String = "",
        sourceSegmentIDs: [String],
        contextBefore: String = "",
        revision: Int,
        createdAt: Date,
        deadline: Date,
        riskFlags: Set<TranslationRiskFlag> = []
    ) {
        self.id = id
        self.laneID = laneID
        self.stablePrefixText = stablePrefixText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.unstableTailText = unstableTailText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sourceSegmentIDs = sourceSegmentIDs
        self.contextBefore = contextBefore.trimmingCharacters(in: .whitespacesAndNewlines)
        self.revision = revision
        self.createdAt = createdAt
        self.deadline = deadline
        self.riskFlags = riskFlags
    }
}

public struct StableTranslationBlock: Codable, Equatable, Identifiable {
    public var id: String
    public var laneID: TranslationLaneID
    public var sourceText: String
    public var sourceSegmentIDs: [String]
    public var previousBlockSummary: String
    public var meetingGoalContext: String
    public var keyTerms: [MeetingKeyTerm]
    public var boundaryReason: StableTranslationBoundaryReason
    public var createdAt: Date
    public var sourceTextHash: String
    public var contextHash: String

    public init(
        id: String,
        laneID: TranslationLaneID,
        sourceText: String,
        sourceSegmentIDs: [String],
        previousBlockSummary: String = "",
        meetingGoalContext: String = "",
        keyTerms: [MeetingKeyTerm] = [],
        boundaryReason: StableTranslationBoundaryReason,
        createdAt: Date
    ) {
        self.id = id
        self.laneID = laneID
        self.sourceText = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sourceSegmentIDs = sourceSegmentIDs
        self.previousBlockSummary = previousBlockSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        self.meetingGoalContext = meetingGoalContext.trimmingCharacters(in: .whitespacesAndNewlines)
        self.keyTerms = keyTerms
        self.boundaryReason = boundaryReason
        self.createdAt = createdAt
        self.sourceTextHash = Self.stableHash(self.sourceText)
        self.contextHash = Self.stableHash([
            self.previousBlockSummary,
            self.meetingGoalContext,
            keyTerms.map { "\($0.value)=\($0.translationHint ?? "")" }.joined(separator: "|")
        ].joined(separator: "\u{1F}"))
    }

    static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

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

    public init(
        id: String,
        sourceID: String,
        laneID: TranslationLaneID,
        sourceText: String,
        translatedText: String,
        displayState: TranslationDisplayState,
        createdAt: Date,
        sourceCreatedAt: Date,
        riskFlags: Set<TranslationRiskFlag> = []
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
    }
}

extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
```

- [ ] **Step 4: Run tests and verify pass**

Run:

```bash
swift test --filter TranslationExperienceModelsTests
```

Expected: all `TranslationExperienceModelsTests` pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingAgentCore/TranslationExperienceModels.swift Tests/MeetingAgentCoreTests/TranslationExperienceModelsTests.swift
git commit -m "Add translation experience models"
```

## Task 2: Add Translation Context Store

**Files:**
- Create: `Sources/MeetingAgentCore/TranslationContextStore.swift`
- Test: `Tests/MeetingAgentCoreTests/TranslationContextStoreTests.swift`

- [ ] **Step 1: Write context store tests**

Create `Tests/MeetingAgentCoreTests/TranslationContextStoreTests.swift`:

```swift
import XCTest
@testable import MeetingAgentCore

final class TranslationContextStoreTests: XCTestCase {
    func testContextIncludesRecentStableBlocksAndGlossary() {
        var store = TranslationContextStore(maxRecentBlocks: 2)
        let lane = TranslationLaneID(speaker: TranscriptSpeaker(identifier: "speaker-1", label: "Alice"), sourceLocale: "en-US", targetLocale: "zh-CN")
        store.updateMeetingGoal("Confirm the launch owner")
        store.updateKeyTerms([MeetingKeyTerm(id: "ga", value: "GA", translationHint: "正式发布")])
        store.recordStableTranslation(sourceText: "We reviewed launch risk.", translatedText: "我们审查了上线风险。", laneID: lane)
        store.recordStableTranslation(sourceText: "Alice owns follow-up.", translatedText: "Alice 负责跟进。", laneID: lane)

        let context = store.context(for: lane)

        XCTAssertEqual(context.meetingGoalContext, "Confirm the launch owner")
        XCTAssertEqual(context.keyTerms.map(\.value), ["GA"])
        XCTAssertEqual(context.recentBlocks.count, 2)
        XCTAssertTrue(context.promptSummary.contains("We reviewed launch risk."))
        XCTAssertFalse(context.contextHash.isEmpty)
    }

    func testContextHashChangesWhenGlossaryChanges() {
        var store = TranslationContextStore(maxRecentBlocks: 2)
        let lane = TranslationLaneID(speaker: .default, sourceLocale: "en-US", targetLocale: "zh-CN")
        let original = store.context(for: lane).contextHash

        store.updateKeyTerms([MeetingKeyTerm(id: "api", value: "API", translationHint: "接口")])

        XCTAssertNotEqual(original, store.context(for: lane).contextHash)
    }
}
```

- [ ] **Step 2: Run tests and verify failure**

Run:

```bash
swift test --filter TranslationContextStoreTests
```

Expected: build fails because `TranslationContextStore` does not exist.

- [ ] **Step 3: Implement context store**

Create `Sources/MeetingAgentCore/TranslationContextStore.swift`:

```swift
import Foundation

public struct TranslationRecentBlock: Codable, Equatable {
    public var sourceText: String
    public var translatedText: String
    public var laneID: TranslationLaneID
    public var createdAt: Date
}

public struct TranslationContext: Codable, Equatable {
    public var recentBlocks: [TranslationRecentBlock]
    public var meetingGoalContext: String
    public var keyTerms: [MeetingKeyTerm]
    public var promptSummary: String
    public var contextHash: String
}

public struct TranslationContextStore: Equatable {
    private var maxRecentBlocks: Int
    private var meetingGoalContext: String = ""
    private var keyTerms: [MeetingKeyTerm] = []
    private var recentBlocksByLane: [TranslationLaneID: [TranslationRecentBlock]] = [:]
    private var now: () -> Date

    public init(maxRecentBlocks: Int = 2, now: @escaping () -> Date = Date.init) {
        self.maxRecentBlocks = max(1, maxRecentBlocks)
        self.now = now
    }

    public static func == (lhs: TranslationContextStore, rhs: TranslationContextStore) -> Bool {
        lhs.maxRecentBlocks == rhs.maxRecentBlocks
            && lhs.meetingGoalContext == rhs.meetingGoalContext
            && lhs.keyTerms == rhs.keyTerms
            && lhs.recentBlocksByLane == rhs.recentBlocksByLane
    }

    public mutating func updateMeetingGoal(_ value: String) {
        meetingGoalContext = value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public mutating func updateKeyTerms(_ terms: [MeetingKeyTerm]) {
        keyTerms = terms
    }

    public mutating func recordStableTranslation(sourceText: String, translatedText: String, laneID: TranslationLaneID) {
        let block = TranslationRecentBlock(
            sourceText: sourceText.trimmingCharacters(in: .whitespacesAndNewlines),
            translatedText: translatedText.trimmingCharacters(in: .whitespacesAndNewlines),
            laneID: laneID,
            createdAt: now()
        )
        var blocks = recentBlocksByLane[laneID, default: []]
        blocks.append(block)
        if blocks.count > maxRecentBlocks {
            blocks.removeFirst(blocks.count - maxRecentBlocks)
        }
        recentBlocksByLane[laneID] = blocks
    }

    public func context(for laneID: TranslationLaneID) -> TranslationContext {
        let recentBlocks = recentBlocksByLane[laneID, default: []]
        let summary = recentBlocks.map {
            "Source: \($0.sourceText)\nTranslation: \($0.translatedText)"
        }.joined(separator: "\n\n")
        let hashInput = [
            meetingGoalContext,
            keyTerms.map { "\($0.value)=\($0.translationHint ?? "")" }.joined(separator: "|"),
            summary
        ].joined(separator: "\u{1F}")
        return TranslationContext(
            recentBlocks: recentBlocks,
            meetingGoalContext: meetingGoalContext,
            keyTerms: keyTerms,
            promptSummary: summary,
            contextHash: StableTranslationBlock.stableHash(hashInput)
        )
    }
}
```

- [ ] **Step 4: Run tests and verify pass**

Run:

```bash
swift test --filter TranslationContextStoreTests
```

Expected: all `TranslationContextStoreTests` pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingAgentCore/TranslationContextStore.swift Tests/MeetingAgentCoreTests/TranslationContextStoreTests.swift
git commit -m "Add translation context store"
```

## Task 3: Add Translation Result Store

**Files:**
- Create: `Sources/MeetingAgentCore/TranslationResultStore.swift`
- Test: `Tests/MeetingAgentCoreTests/TranslationResultStoreTests.swift`

- [ ] **Step 1: Write result store tests**

Create `Tests/MeetingAgentCoreTests/TranslationResultStoreTests.swift`:

```swift
import XCTest
@testable import MeetingAgentCore

final class TranslationResultStoreTests: XCTestCase {
    func testStableFinalOverridesLiveResult() {
        let lane = TranslationLaneID(speaker: .default, sourceLocale: "en-US", targetLocale: "zh-CN")
        var store = TranslationResultStore()
        store.attach(TranslationResult(
            id: "live-1",
            sourceID: "unit-1",
            laneID: lane,
            sourceText: "We approve",
            translatedText: "我们批准",
            displayState: .liveFresh,
            createdAt: Date(timeIntervalSince1970: 2),
            sourceCreatedAt: Date(timeIntervalSince1970: 1)
        ))
        store.attach(TranslationResult(
            id: "stable-1",
            sourceID: "block-1",
            laneID: lane,
            sourceText: "We approve the launch.",
            translatedText: "我们批准上线。",
            displayState: .stableFinal,
            createdAt: Date(timeIntervalSince1970: 4),
            sourceCreatedAt: Date(timeIntervalSince1970: 3)
        ))

        let projection = store.visibleResult(for: lane)

        XCTAssertEqual(projection?.translatedText, "我们批准上线。")
        XCTAssertEqual(projection?.displayState, .stableFinal)
    }

    func testHighRiskLiveResultDoesNotCarryForward() {
        let lane = TranslationLaneID(speaker: .default, sourceLocale: "en-US", targetLocale: "zh-CN")
        var store = TranslationResultStore()
        store.attach(TranslationResult(
            id: "live-1",
            sourceID: "unit-1",
            laneID: lane,
            sourceText: "Budget is 10 percent",
            translatedText: "预算是 10%",
            displayState: .liveFresh,
            createdAt: Date(timeIntervalSince1970: 2),
            sourceCreatedAt: Date(timeIntervalSince1970: 1),
            riskFlags: [.number]
        ))

        XCTAssertNil(store.carriedForwardResult(for: lane, currentRiskFlags: [.number]))
        XCTAssertNotNil(store.carriedForwardResult(for: lane, currentRiskFlags: []))
    }
}
```

- [ ] **Step 2: Run tests and verify failure**

Run:

```bash
swift test --filter TranslationResultStoreTests
```

Expected: build fails because `TranslationResultStore` does not exist.

- [ ] **Step 3: Implement result store**

Create `Sources/MeetingAgentCore/TranslationResultStore.swift`:

```swift
import Foundation

public struct TranslationResultStore: Equatable {
    private var resultsByLane: [TranslationLaneID: [TranslationResult]] = [:]

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
    }

    public func visibleResult(for laneID: TranslationLaneID) -> TranslationResult? {
        resultsByLane[laneID]?.max {
            if $0.displayState.priority == $1.displayState.priority {
                return $0.createdAt < $1.createdAt
            }
            return $0.displayState.priority < $1.displayState.priority
        }
    }

    public func carriedForwardResult(
        for laneID: TranslationLaneID,
        currentRiskFlags: Set<TranslationRiskFlag>
    ) -> TranslationResult? {
        guard currentRiskFlags.isDisjoint(with: TranslationResultStore.nonCarryForwardRiskFlags) else {
            return nil
        }
        guard var result = visibleResult(for: laneID),
              result.displayState == .liveFresh || result.displayState == .liveLagging
        else {
            return nil
        }
        result.displayState = .liveCarried
        return result
    }

    static let nonCarryForwardRiskFlags: Set<TranslationRiskFlag> = [
        .number,
        .dateOrTime,
        .negation,
        .commitment,
        .namedEntity,
        .speakerChanged,
        .localeChanged
    ]
}
```

- [ ] **Step 4: Run tests and verify pass**

Run:

```bash
swift test --filter TranslationResultStoreTests
```

Expected: all `TranslationResultStoreTests` pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingAgentCore/TranslationResultStore.swift Tests/MeetingAgentCoreTests/TranslationResultStoreTests.swift
git commit -m "Add translation result store"
```

## Task 4: Add Translation Unit Builder

**Files:**
- Create: `Sources/MeetingAgentCore/TranslationUnitBuilder.swift`
- Test: `Tests/MeetingAgentCoreTests/TranslationUnitBuilderTests.swift`

- [ ] **Step 1: Write unit builder tests**

Create `Tests/MeetingAgentCoreTests/TranslationUnitBuilderTests.swift`:

```swift
import XCTest
@testable import MeetingAgentCore

final class TranslationUnitBuilderTests: XCTestCase {
    func testInterimChurnUpdatesLiveUnitWithoutStableBlock() {
        var builder = TranslationUnitBuilder(sourceLocale: "en-US", targetLocale: "zh-CN")
        let createdAt = Date(timeIntervalSince1970: 1)
        let segment = TranscriptSegment(
            id: "segment-1",
            speaker: TranscriptSpeaker(identifier: "speaker-1"),
            text: "We should confirm the launch owner today",
            language: "en-US",
            isFinal: false,
            createdAt: createdAt
        )

        let output = builder.apply(segments: [segment], now: Date(timeIntervalSince1970: 2))

        XCTAssertEqual(output.liveUnits.count, 1)
        XCTAssertEqual(output.liveUnits.first?.stablePrefixText, "We should confirm the launch owner")
        XCTAssertEqual(output.liveUnits.first?.unstableTailText, "today")
        XCTAssertTrue(output.stableBlocks.isEmpty)
    }

    func testSpeechFinalCreatesStableBlock() {
        var builder = TranslationUnitBuilder(sourceLocale: "en-US", targetLocale: "zh-CN")
        let segment = TranscriptSegment(
            id: "segment-1",
            speaker: TranscriptSpeaker(identifier: "speaker-1"),
            text: "We approved the launch date.",
            language: "en-US",
            isFinal: true,
            speechFinal: true
        )

        let output = builder.apply(segments: [segment], now: Date(timeIntervalSince1970: 2))

        XCTAssertEqual(output.stableBlocks.count, 1)
        XCTAssertEqual(output.stableBlocks.first?.sourceText, "We approved the launch date.")
        XCTAssertEqual(output.stableBlocks.first?.boundaryReason, .providerHardBoundary)
    }

    func testTerminalPunctuationCreatesStableBlockWithoutSpeechFinal() {
        var builder = TranslationUnitBuilder(sourceLocale: "en-US", targetLocale: "zh-CN")
        let segment = TranscriptSegment(
            id: "segment-1",
            speaker: TranscriptSpeaker(identifier: "speaker-1"),
            text: "We approved the launch date.",
            language: "en-US",
            isFinal: true,
            speechFinal: false
        )

        let output = builder.apply(segments: [segment], now: Date(timeIntervalSince1970: 2))

        XCTAssertEqual(output.stableBlocks.count, 1)
        XCTAssertEqual(output.stableBlocks.first?.boundaryReason, .terminalPunctuation)
    }

    func testRiskFlagsDetectNumbersAndNegation() {
        var builder = TranslationUnitBuilder(sourceLocale: "en-US", targetLocale: "zh-CN")
        let segment = TranscriptSegment(id: "segment-1", text: "We cannot approve 30 percent today", language: "en-US", isFinal: false)

        let output = builder.apply(segments: [segment], now: Date(timeIntervalSince1970: 2))

        XCTAssertTrue(output.liveUnits.first?.riskFlags.contains(.number) == true)
        XCTAssertTrue(output.liveUnits.first?.riskFlags.contains(.negation) == true)
    }
}
```

- [ ] **Step 2: Run tests and verify failure**

Run:

```bash
swift test --filter TranslationUnitBuilderTests
```

Expected: build fails because `TranslationUnitBuilder` does not exist.

- [ ] **Step 3: Implement unit builder**

Create `Sources/MeetingAgentCore/TranslationUnitBuilder.swift`:

```swift
import Foundation

public struct TranslationUnitBuilderOutput: Equatable {
    public var liveUnits: [LiveTranslationUnit]
    public var stableBlocks: [StableTranslationBlock]
}

public struct TranslationUnitBuilderConfiguration: Equatable {
    public var minimumLiveWords: Int
    public var unstableTailWords: Int
    public var minimumStableBlockCharacters: Int

    public init(minimumLiveWords: Int = 6, unstableTailWords: Int = 1, minimumStableBlockCharacters: Int = 24) {
        self.minimumLiveWords = minimumLiveWords
        self.unstableTailWords = unstableTailWords
        self.minimumStableBlockCharacters = minimumStableBlockCharacters
    }
}

public struct TranslationUnitBuilder {
    private let sourceLocale: String
    private let targetLocale: String
    private let configuration: TranslationUnitBuilderConfiguration
    private var emittedStableBlockIDs = Set<String>()
    private var revisionsBySegmentID: [String: Int] = [:]

    public init(
        sourceLocale: String,
        targetLocale: String,
        configuration: TranslationUnitBuilderConfiguration = TranslationUnitBuilderConfiguration()
    ) {
        self.sourceLocale = sourceLocale
        self.targetLocale = targetLocale
        self.configuration = configuration
    }

    public mutating func apply(segments: [TranscriptSegment], now: Date = Date()) -> TranslationUnitBuilderOutput {
        var liveUnits: [LiveTranslationUnit] = []
        var stableBlocks: [StableTranslationBlock] = []

        for segment in segments {
            let laneID = TranslationLaneID(
                speaker: segment.speaker,
                sourceLocale: segment.language ?? sourceLocale,
                targetLocale: targetLocale
            )
            if let liveUnit = liveUnit(for: segment, laneID: laneID, now: now) {
                liveUnits.append(liveUnit)
            }
            if let stableBlock = stableBlock(for: segment, laneID: laneID) {
                stableBlocks.append(stableBlock)
            }
        }

        return TranslationUnitBuilderOutput(liveUnits: liveUnits, stableBlocks: stableBlocks)
    }

    private mutating func liveUnit(for segment: TranscriptSegment, laneID: TranslationLaneID, now: Date) -> LiveTranslationUnit? {
        let words = segment.text.split { $0.isWhitespace || $0.isNewline }.map(String.init)
        guard words.count >= configuration.minimumLiveWords else { return nil }
        let stableCount = max(1, words.count - configuration.unstableTailWords)
        let stablePrefix = words.prefix(stableCount).joined(separator: " ")
        let unstableTail = words.dropFirst(stableCount).joined(separator: " ")
        revisionsBySegmentID[segment.id, default: 0] += 1
        return LiveTranslationUnit(
            id: "\(segment.id)-live-\(revisionsBySegmentID[segment.id, default: 0])",
            laneID: laneID,
            stablePrefixText: stablePrefix,
            unstableTailText: unstableTail,
            sourceSegmentIDs: [segment.id],
            revision: revisionsBySegmentID[segment.id, default: 0],
            createdAt: segment.createdAt,
            deadline: now.addingTimeInterval(4),
            riskFlags: riskFlags(in: segment.text)
        )
    }

    private mutating func stableBlock(for segment: TranscriptSegment, laneID: TranslationLaneID) -> StableTranslationBlock? {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard segment.isFinal, text.count >= configuration.minimumStableBlockCharacters else { return nil }
        let reason: StableTranslationBoundaryReason?
        if segment.speechFinal {
            reason = .providerHardBoundary
        } else if hasTerminalPunctuation(text) {
            reason = .terminalPunctuation
        } else {
            reason = nil
        }
        guard let reason else { return nil }
        let blockID = "\(segment.id)-stable-\(StableTranslationBlock.stableHash(text))"
        guard emittedStableBlockIDs.insert(blockID).inserted else { return nil }
        return StableTranslationBlock(
            id: blockID,
            laneID: laneID,
            sourceText: text,
            sourceSegmentIDs: [segment.id],
            boundaryReason: reason,
            createdAt: segment.createdAt
        )
    }

    private func hasTerminalPunctuation(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return [".", "?", "!", "。", "？", "！"].contains(String(last))
    }

    private func riskFlags(in text: String) -> Set<TranslationRiskFlag> {
        let lowercased = text.lowercased()
        var flags: Set<TranslationRiskFlag> = []
        if lowercased.rangeOfCharacter(from: .decimalDigits) != nil {
            flags.insert(.number)
        }
        if lowercased.contains("cannot") || lowercased.contains("can't") || lowercased.contains(" not ") || lowercased.hasPrefix("not ") {
            flags.insert(.negation)
        }
        if lowercased.contains("will") || lowercased.contains("must") || lowercased.contains("approved") || lowercased.contains("blocked") {
            flags.insert(.commitment)
        }
        return flags
    }
}
```

- [ ] **Step 4: Run tests and verify pass**

Run:

```bash
swift test --filter TranslationUnitBuilderTests
```

Expected: all `TranslationUnitBuilderTests` pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingAgentCore/TranslationUnitBuilder.swift Tests/MeetingAgentCoreTests/TranslationUnitBuilderTests.swift
git commit -m "Add translation unit builder"
```

## Task 5: Add Live Translation Scheduler

**Files:**
- Create: `Sources/MeetingAgentCore/LiveTranslationScheduler.swift`
- Test: `Tests/MeetingAgentCoreTests/LiveTranslationSchedulerTests.swift`

- [ ] **Step 1: Write scheduler tests**

Create `Tests/MeetingAgentCoreTests/LiveTranslationSchedulerTests.swift`:

```swift
import XCTest
@testable import MeetingAgentCore

@MainActor
final class LiveTranslationSchedulerTests: XCTestCase {
    func testSchedulesOneLiveRequestPerLane() async {
        let lane = TranslationLaneID(speaker: .default, sourceLocale: "en-US", targetLocale: "zh-CN")
        let provider = LiveRecordingTranslationProvider(translations: ["unit-1": "我们确认负责人"])
        var scheduler = LiveTranslationScheduler(provider: provider, configuration: LiveTranslationSchedulerConfiguration(draftTimeoutNanoseconds: 1_000_000_000))

        let unit = LiveTranslationUnit(id: "unit-1", laneID: lane, stablePrefixText: "We confirm the owner", sourceSegmentIDs: ["segment-1"], revision: 1, createdAt: Date(), deadline: Date().addingTimeInterval(4))
        let updates = await scheduler.schedule([unit])

        XCTAssertEqual(await provider.requests.map(\.sourceText), ["We confirm the owner"])
        XCTAssertEqual(updates.first?.translatedText, "我们确认负责人")
        XCTAssertEqual(updates.first?.displayState, .liveFresh)
    }

    func testBudgetDisablesExtraLiveRequests() async {
        let lane = TranslationLaneID(speaker: .default, sourceLocale: "en-US", targetLocale: "zh-CN")
        let provider = LiveRecordingTranslationProvider(translations: [:])
        var scheduler = LiveTranslationScheduler(
            provider: provider,
            configuration: LiveTranslationSchedulerConfiguration(maxCallsPerMinute: 1, draftTimeoutNanoseconds: 1_000_000_000)
        )
        let first = LiveTranslationUnit(id: "unit-1", laneID: lane, stablePrefixText: "We confirm the owner", sourceSegmentIDs: ["segment-1"], revision: 1, createdAt: Date(), deadline: Date().addingTimeInterval(4))
        let second = LiveTranslationUnit(id: "unit-2", laneID: lane, stablePrefixText: "We confirm the launch owner", sourceSegmentIDs: ["segment-1"], revision: 2, createdAt: Date(), deadline: Date().addingTimeInterval(4))

        _ = await scheduler.schedule([first])
        let updates = await scheduler.schedule([second])

        XCTAssertEqual(await provider.requests.count, 1)
        XCTAssertEqual(updates.first?.displayState, .disabledBudget)
    }

    func testHighRiskUnitDoesNotLagAttachOlderText() async {
        let lane = TranslationLaneID(speaker: .default, sourceLocale: "en-US", targetLocale: "zh-CN")
        let provider = LiveRecordingTranslationProvider(translations: ["unit-1": "预算是 10%"])
        var scheduler = LiveTranslationScheduler(provider: provider)
        let unit = LiveTranslationUnit(
            id: "unit-1",
            laneID: lane,
            stablePrefixText: "Budget is 10 percent",
            sourceSegmentIDs: ["segment-1"],
            revision: 1,
            createdAt: Date(),
            deadline: Date().addingTimeInterval(4),
            riskFlags: [.number]
        )

        let updates = await scheduler.schedule([unit])

        XCTAssertEqual(updates.first?.displayState, .liveFresh)
        XCTAssertEqual(updates.first?.riskFlags, [.number])
    }
}

private actor LiveRecordingTranslationProvider: TextTranslationProvider {
    nonisolated let descriptor = ProviderDescriptor(
        id: "test-live",
        displayName: "Test Live",
        capability: .textTranslation,
        executionMode: .hosted,
        supportedSourceLocales: ["*"],
        supportedTargetLocales: ["*"],
        requiresNetwork: false,
        requiresAPIKey: false
    )
    private let translations: [String: String]
    private(set) var requests: [(id: String, sourceText: String)] = []

    init(translations: [String: String]) {
        self.translations = translations
    }

    nonisolated func translate(transcript: TranscriptDocument, options: TranslationOptions) async throws -> TranslatedTranscript {
        let segment = transcript.segments[0]
        await record(id: segment.id, sourceText: segment.text)
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

    private func record(id: String, sourceText: String) {
        requests.append((id, sourceText))
    }
}
```

- [ ] **Step 2: Run tests and verify failure**

Run:

```bash
swift test --filter LiveTranslationSchedulerTests
```

Expected: build fails because `LiveTranslationScheduler` does not exist.

- [ ] **Step 3: Implement scheduler**

Create `Sources/MeetingAgentCore/LiveTranslationScheduler.swift`:

```swift
import Foundation

public struct LiveTranslationSchedulerConfiguration: Equatable {
    public var maxConcurrentRequests: Int
    public var maxCallsPerMinute: Int
    public var draftTimeoutNanoseconds: UInt64

    public init(maxConcurrentRequests: Int = 2, maxCallsPerMinute: Int = 12, draftTimeoutNanoseconds: UInt64 = 4_000_000_000) {
        self.maxConcurrentRequests = max(1, maxConcurrentRequests)
        self.maxCallsPerMinute = max(1, maxCallsPerMinute)
        self.draftTimeoutNanoseconds = draftTimeoutNanoseconds
    }
}

public struct LiveTranslationScheduler {
    private let provider: TextTranslationProvider
    private let configuration: LiveTranslationSchedulerConfiguration
    private var requestTimes: [Date] = []
    private var lastRequestedPrefixByLane: [TranslationLaneID: String] = [:]
    private var now: () -> Date

    public init(
        provider: TextTranslationProvider,
        configuration: LiveTranslationSchedulerConfiguration = LiveTranslationSchedulerConfiguration(),
        now: @escaping () -> Date = Date.init
    ) {
        self.provider = provider
        self.configuration = configuration
        self.now = now
    }

    public mutating func schedule(_ units: [LiveTranslationUnit]) async -> [TranslationResult] {
        var results: [TranslationResult] = []
        for unit in units {
            pruneRequestTimes()
            guard requestTimes.count < configuration.maxCallsPerMinute else {
                results.append(disabledBudgetResult(for: unit))
                continue
            }
            guard lastRequestedPrefixByLane[unit.laneID] != unit.stablePrefixText else {
                continue
            }
            requestTimes.append(now())
            lastRequestedPrefixByLane[unit.laneID] = unit.stablePrefixText
            if let result = await translate(unit) {
                results.append(result)
            }
        }
        return results
    }

    private mutating func pruneRequestTimes() {
        let cutoff = now().addingTimeInterval(-60)
        requestTimes.removeAll { $0 < cutoff }
    }

    private func disabledBudgetResult(for unit: LiveTranslationUnit) -> TranslationResult {
        TranslationResult(
            id: "\(unit.id)-budget",
            sourceID: unit.id,
            laneID: unit.laneID,
            sourceText: unit.stablePrefixText,
            translatedText: "",
            displayState: .disabledBudget,
            createdAt: now(),
            sourceCreatedAt: unit.createdAt,
            riskFlags: unit.riskFlags
        )
    }

    private func translate(_ unit: LiveTranslationUnit) async -> TranslationResult? {
        do {
            let transcript = TranscriptDocument(segments: [
                TranscriptSegment(
                    id: unit.id,
                    text: unit.stablePrefixText,
                    language: unit.laneID.sourceLocale,
                    isFinal: false,
                    createdAt: unit.createdAt
                )
            ])
            let translated = try await withThrowingTaskGroup(of: TranslatedTranscript.self) { group in
                group.addTask {
                    try await provider.translate(
                        transcript: transcript,
                        options: TranslationOptions(sourceLocale: unit.laneID.sourceLocale, targetLocale: unit.laneID.targetLocale)
                    )
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: configuration.draftTimeoutNanoseconds)
                    throw CancellationError()
                }
                let value = try await group.next()
                group.cancelAll()
                return try value ?? TranslatedTranscript(
                    sourceLocale: unit.laneID.sourceLocale,
                    targetLocale: unit.laneID.targetLocale,
                    segments: [],
                    provenance: PipelineProvenance(profileID: "live-translation")
                )
            }
            let translatedText = translated.segments.first?.targetText ?? ""
            return TranslationResult(
                id: "\(unit.id)-live-result",
                sourceID: unit.id,
                laneID: unit.laneID,
                sourceText: unit.stablePrefixText,
                translatedText: translatedText,
                displayState: .liveFresh,
                createdAt: now(),
                sourceCreatedAt: unit.createdAt,
                riskFlags: unit.riskFlags
            )
        } catch {
            return TranslationResult(
                id: "\(unit.id)-failed",
                sourceID: unit.id,
                laneID: unit.laneID,
                sourceText: unit.stablePrefixText,
                translatedText: "",
                displayState: .failedRecoverable,
                createdAt: now(),
                sourceCreatedAt: unit.createdAt,
                riskFlags: unit.riskFlags
            )
        }
    }
}
```

- [ ] **Step 4: Run tests and verify pass**

Run:

```bash
swift test --filter LiveTranslationSchedulerTests
```

Expected: all `LiveTranslationSchedulerTests` pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingAgentCore/LiveTranslationScheduler.swift Tests/MeetingAgentCoreTests/LiveTranslationSchedulerTests.swift
git commit -m "Add live translation scheduler"
```

## Task 6: Add Accurate Translation Scheduler

**Files:**
- Create: `Sources/MeetingAgentCore/AccurateTranslationScheduler.swift`
- Test: `Tests/MeetingAgentCoreTests/AccurateTranslationSchedulerTests.swift`

- [ ] **Step 1: Write accurate scheduler tests**

Create `Tests/MeetingAgentCoreTests/AccurateTranslationSchedulerTests.swift`:

```swift
import XCTest
@testable import MeetingAgentCore

@MainActor
final class AccurateTranslationSchedulerTests: XCTestCase {
    func testTranslatesStableBlockAsStableFinal() async {
        let lane = TranslationLaneID(speaker: .default, sourceLocale: "en-US", targetLocale: "zh-CN")
        let provider = AccurateRecordingTranslationProvider(translations: ["block-1": "我们批准上线日期。"])
        var scheduler = AccurateTranslationScheduler(provider: provider)
        let block = StableTranslationBlock(
            id: "block-1",
            laneID: lane,
            sourceText: "We approved the launch date.",
            sourceSegmentIDs: ["segment-1"],
            previousBlockSummary: "Team discussed launch readiness.",
            meetingGoalContext: "Confirm launch date.",
            keyTerms: [MeetingKeyTerm(id: "launch", value: "launch", translationHint: "上线")],
            boundaryReason: .terminalPunctuation,
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let results = await scheduler.translate([block])

        XCTAssertEqual(await provider.requests.first?.sourceText, "We approved the launch date.")
        XCTAssertEqual(results.first?.translatedText, "我们批准上线日期。")
        XCTAssertEqual(results.first?.displayState, .stableFinal)
    }
}

private actor AccurateRecordingTranslationProvider: TextTranslationProvider {
    nonisolated let descriptor = ProviderDescriptor(
        id: "test-accurate",
        displayName: "Test Accurate",
        capability: .textTranslation,
        executionMode: .hosted,
        supportedSourceLocales: ["*"],
        supportedTargetLocales: ["*"],
        requiresNetwork: false,
        requiresAPIKey: false
    )
    private let translations: [String: String]
    private(set) var requests: [(id: String, sourceText: String)] = []

    init(translations: [String: String]) {
        self.translations = translations
    }

    nonisolated func translate(transcript: TranscriptDocument, options: TranslationOptions) async throws -> TranslatedTranscript {
        let segment = transcript.segments[0]
        await record(id: segment.id, sourceText: segment.text)
        return TranslatedTranscript(
            sourceLocale: options.sourceLocale,
            targetLocale: options.targetLocale,
            segments: [
                BilingualSubtitleSegment(
                    id: segment.id,
                    sourceText: segment.text,
                    targetText: translations[segment.id] ?? "stable \(segment.text)"
                )
            ],
            provenance: PipelineProvenance(profileID: "test-accurate", successfulProviders: ["test-accurate"])
        )
    }

    private func record(id: String, sourceText: String) {
        requests.append((id, sourceText))
    }
}
```

- [ ] **Step 2: Run tests and verify failure**

Run:

```bash
swift test --filter AccurateTranslationSchedulerTests
```

Expected: build fails because `AccurateTranslationScheduler` does not exist.

- [ ] **Step 3: Implement accurate scheduler**

Create `Sources/MeetingAgentCore/AccurateTranslationScheduler.swift`:

```swift
import Foundation

public struct AccurateTranslationSchedulerConfiguration: Equatable {
    public var timeoutNanoseconds: UInt64
    public var retryCount: Int

    public init(timeoutNanoseconds: UInt64 = 15_000_000_000, retryCount: Int = 1) {
        self.timeoutNanoseconds = timeoutNanoseconds
        self.retryCount = max(0, retryCount)
    }
}

public struct AccurateTranslationScheduler {
    private let provider: TextTranslationProvider
    private let configuration: AccurateTranslationSchedulerConfiguration
    private var translatedBlockIDs = Set<String>()
    private var now: () -> Date

    public init(
        provider: TextTranslationProvider,
        configuration: AccurateTranslationSchedulerConfiguration = AccurateTranslationSchedulerConfiguration(),
        now: @escaping () -> Date = Date.init
    ) {
        self.provider = provider
        self.configuration = configuration
        self.now = now
    }

    public mutating func translate(_ blocks: [StableTranslationBlock]) async -> [TranslationResult] {
        var results: [TranslationResult] = []
        for block in blocks where !translatedBlockIDs.contains(block.id) {
            if let result = await translate(block) {
                translatedBlockIDs.insert(block.id)
                results.append(result)
            }
        }
        return results
    }

    private func translate(_ block: StableTranslationBlock) async -> TranslationResult? {
        var attempts = 0
        while attempts <= configuration.retryCount {
            attempts += 1
            do {
                let transcript = TranscriptDocument(segments: [
                    TranscriptSegment(
                        id: block.id,
                        text: block.sourceText,
                        language: block.laneID.sourceLocale,
                        isFinal: true,
                        createdAt: block.createdAt
                    )
                ])
                let translated = try await provider.translate(
                    transcript: transcript,
                    options: TranslationOptions(sourceLocale: block.laneID.sourceLocale, targetLocale: block.laneID.targetLocale)
                )
                return TranslationResult(
                    id: "\(block.id)-stable-result",
                    sourceID: block.id,
                    laneID: block.laneID,
                    sourceText: block.sourceText,
                    translatedText: translated.segments.first?.targetText ?? "",
                    displayState: .stableFinal,
                    createdAt: now(),
                    sourceCreatedAt: block.createdAt
                )
            } catch where attempts <= configuration.retryCount {
                continue
            } catch {
                return TranslationResult(
                    id: "\(block.id)-stable-failed",
                    sourceID: block.id,
                    laneID: block.laneID,
                    sourceText: block.sourceText,
                    translatedText: "",
                    displayState: .failedRecoverable,
                    createdAt: now(),
                    sourceCreatedAt: block.createdAt
                )
            }
        }
        return nil
    }
}
```

- [ ] **Step 4: Run tests and verify pass**

Run:

```bash
swift test --filter AccurateTranslationSchedulerTests
```

Expected: all `AccurateTranslationSchedulerTests` pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingAgentCore/AccurateTranslationScheduler.swift Tests/MeetingAgentCoreTests/AccurateTranslationSchedulerTests.swift
git commit -m "Add accurate translation scheduler"
```

## Task 7: Extend Performance Analysis Metrics

**Files:**
- Modify: `scripts/analyze-meeting-performance.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingPerformanceAnalysisScriptTests.swift`

- [ ] **Step 1: Add script test for new metrics**

Append this test to `MeetingPerformanceAnalysisScriptTests`:

```swift
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
```

- [ ] **Step 2: Run test and verify failure**

Run:

```bash
swift test --filter MeetingPerformanceAnalysisScriptTests/testAnalyzeMeetingPerformanceScriptReportsTranslationExperienceV2Metrics
```

Expected: FAIL because the report does not include `Translation Experience V2`.

- [ ] **Step 3: Update the script report**

In `scripts/analyze-meeting-performance.swift`, add these lines in `report(inputPath:)` after existing visible translation metrics:

```swift
lines.append("")
lines.append("Translation Experience V2")
lines.append("Time to First Live Translation: \(format(duration: timeToFirstLiveTranslationV2()))")
lines.append("Live Translation Calls: \(events.filter { $0.event == "translation_live_request_started" }.count)")
lines.append("Stable Translation Success Count: \(events.filter { $0.event == "translation_stable_result_visible" }.count)")
```

Add these helper methods inside `MeetingPerformanceAnalyzer`:

```swift
private func timeToFirstLiveTranslationV2() -> Double? {
    guard let firstAudioSent = firstAudioSent?.wallTime,
          let firstLive = events.first(where: { $0.event == "translation_live_result_visible" })?.wallTime
    else {
        return nil
    }
    return max(0, firstLive.timeIntervalSince(firstAudioSent))
}
```

- [ ] **Step 4: Run test and verify pass**

Run:

```bash
swift test --filter MeetingPerformanceAnalysisScriptTests/testAnalyzeMeetingPerformanceScriptReportsTranslationExperienceV2Metrics
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/analyze-meeting-performance.swift Tests/MeetingAgentCoreTests/MeetingPerformanceAnalysisScriptTests.swift
git commit -m "Report translation experience v2 metrics"
```

## Task 8: Add Integration Facade Without UI Wiring

**Files:**
- Create: `Sources/MeetingAgentCore/TranslationExperiencePipeline.swift`
- Test: `Tests/MeetingAgentCoreTests/TranslationExperiencePipelineTests.swift`

- [ ] **Step 1: Write facade test**

Create `Tests/MeetingAgentCoreTests/TranslationExperiencePipelineTests.swift`:

```swift
import XCTest
@testable import MeetingAgentCore

@MainActor
final class TranslationExperiencePipelineTests: XCTestCase {
    func testPipelineBuildsUnitsAndStoresLiveResult() async {
        let provider = PipelineTranslationProvider(translations: ["segment-1-live-1": "我们确认负责人"])
        var pipeline = TranslationExperiencePipeline(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            liveProvider: provider,
            accurateProvider: provider
        )
        let segment = TranscriptSegment(id: "segment-1", text: "We should confirm the launch owner today", language: "en-US", isFinal: false)

        let snapshot = await pipeline.apply(segments: [segment])

        XCTAssertEqual(snapshot.liveResults.count, 1)
        XCTAssertEqual(snapshot.visibleResults.first?.translatedText, "我们确认负责人")
    }
}

private actor PipelineTranslationProvider: TextTranslationProvider {
    nonisolated let descriptor = ProviderDescriptor(
        id: "test-pipeline",
        displayName: "Test Pipeline",
        capability: .textTranslation,
        executionMode: .hosted,
        supportedSourceLocales: ["*"],
        supportedTargetLocales: ["*"],
        requiresNetwork: false,
        requiresAPIKey: false
    )
    let translations: [String: String]

    init(translations: [String: String]) {
        self.translations = translations
    }

    nonisolated func translate(transcript: TranscriptDocument, options: TranslationOptions) async throws -> TranslatedTranscript {
        let segment = transcript.segments[0]
        return TranslatedTranscript(
            sourceLocale: options.sourceLocale,
            targetLocale: options.targetLocale,
            segments: [
                BilingualSubtitleSegment(
                    id: segment.id,
                    sourceText: segment.text,
                    targetText: translations[segment.id] ?? "translated"
                )
            ],
            provenance: PipelineProvenance(profileID: "test-pipeline", successfulProviders: ["test-pipeline"])
        )
    }
}
```

- [ ] **Step 2: Run test and verify failure**

Run:

```bash
swift test --filter TranslationExperiencePipelineTests
```

Expected: build fails because `TranslationExperiencePipeline` does not exist.

- [ ] **Step 3: Implement facade**

Create `Sources/MeetingAgentCore/TranslationExperiencePipeline.swift`:

```swift
import Foundation

public struct TranslationExperiencePipelineSnapshot: Equatable {
    public var liveResults: [TranslationResult]
    public var stableResults: [TranslationResult]
    public var visibleResults: [TranslationResult]
}

public struct TranslationExperiencePipeline {
    private var unitBuilder: TranslationUnitBuilder
    private var liveScheduler: LiveTranslationScheduler
    private var accurateScheduler: AccurateTranslationScheduler
    private var resultStore = TranslationResultStore()

    public init(sourceLocale: String, targetLocale: String, liveProvider: TextTranslationProvider, accurateProvider: TextTranslationProvider) {
        self.unitBuilder = TranslationUnitBuilder(sourceLocale: sourceLocale, targetLocale: targetLocale)
        self.liveScheduler = LiveTranslationScheduler(provider: liveProvider)
        self.accurateScheduler = AccurateTranslationScheduler(provider: accurateProvider)
    }

    public mutating func apply(segments: [TranscriptSegment], now: Date = Date()) async -> TranslationExperiencePipelineSnapshot {
        let units = unitBuilder.apply(segments: segments, now: now)
        let liveResults = await liveScheduler.schedule(units.liveUnits)
        let stableResults = await accurateScheduler.translate(units.stableBlocks)
        for result in liveResults + stableResults {
            resultStore.attach(result)
        }
        let lanes = Set((liveResults + stableResults).map(\.laneID))
        let visibleResults = lanes.compactMap { resultStore.visibleResult(for: $0) }
        return TranslationExperiencePipelineSnapshot(
            liveResults: liveResults,
            stableResults: stableResults,
            visibleResults: visibleResults
        )
    }
}
```

- [ ] **Step 4: Run test and verify pass**

Run:

```bash
swift test --filter TranslationExperiencePipelineTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingAgentCore/TranslationExperiencePipeline.swift Tests/MeetingAgentCoreTests/TranslationExperiencePipelineTests.swift
git commit -m "Add translation experience pipeline facade"
```

## Task 9: Run Focused and Full Verification

**Files:**
- No source changes expected.

- [ ] **Step 1: Run focused translation tests**

Run:

```bash
swift test --filter TranslationExperienceModelsTests
swift test --filter TranslationContextStoreTests
swift test --filter TranslationResultStoreTests
swift test --filter TranslationUnitBuilderTests
swift test --filter LiveTranslationSchedulerTests
swift test --filter AccurateTranslationSchedulerTests
swift test --filter TranslationExperiencePipelineTests
```

Expected: all focused tests pass.

- [ ] **Step 2: Run performance script tests**

Run:

```bash
swift test --filter MeetingPerformanceAnalysisScriptTests
```

Expected: all performance analysis script tests pass.

- [ ] **Step 3: Run required project verification**

Run:

```bash
make test
```

Expected: full test suite and coverage gate pass.

- [ ] **Step 4: Commit verification-only fixes if needed**

If verification reveals compiler or test issues introduced by this plan, fix only the failing files and commit:

```bash
git add Sources/MeetingAgentCore Tests/MeetingAgentCoreTests scripts/analyze-meeting-performance.swift
git commit -m "Fix translation experience verification issues"
```

Expected: no commit is created if no fixes are needed.
