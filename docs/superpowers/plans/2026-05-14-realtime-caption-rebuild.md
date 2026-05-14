# Realtime Caption Rebuild Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the realtime transcript/caption architecture with a provider-agnostic `SpeechRecognitionEvent -> CaptionReducer -> MeetingTranscriptStore` path where `transcript.json` is the only transcript source of truth.

**Architecture:** Provider adapters emit normalized speech events. `CaptionReducer` owns draft replacement, speaker boundaries, pause/punctuation/speech-final segmentation, and final promotion. UI, summaries, exports, meeting progress, and knowledge assets read the new `CaptionDocument` persisted by `MeetingTranscriptStore`.

**Tech Stack:** Swift 5.9, Swift Package Manager, XCTest, SwiftUI, macOS 14.2+, existing `MeetingAgentCore` and `MeetingAgentApp` targets.

---

## File Structure

Create these new core files:

- `Sources/MeetingAgentCore/CaptionDocument.swift`: v2 transcript domain model, speaker table, rendering helpers, bridge helpers for summary/export where needed.
- `Sources/MeetingAgentCore/SpeechRecognitionEvent.swift`: provider-neutral realtime event protocol and boundary evidence types.
- `Sources/MeetingAgentCore/CaptionReducer.swift`: state machine for hypotheses, final promotion, boundaries, speaker separation, and snapshots.
- `Sources/MeetingAgentCore/MeetingTranscriptStore.swift`: JSON persistence for `CaptionDocument`, dynamic text rendering, and speaker label updates.
- `Sources/MeetingAgentCore/DeepgramSpeechEventAdapter.swift`: Deepgram streaming response mapping to `SpeechRecognitionEvent`.
- `Sources/MeetingAgentCore/CaptionSRTVTTExporter.swift`: SRT/VTT generation from final `CaptionTurn` values if existing export code is too `TranscriptSegment`-coupled.

Modify these existing files:

- `Sources/MeetingAgentCore/MeetingStore.swift`: stop assigning `transcript.txt` as an internal meeting asset; keep `transcriptJSONURL`.
- `Sources/MeetingAgentCore/MeetingRecord.swift`: make `transcriptURL` optional/legacy-only if necessary; ensure app flows use `transcriptJSONURL`.
- `Sources/MeetingAgentCore/SpeechTranscriptionProvider.swift`: add `SpeechRecognitionEventSink` and streaming context support.
- `Sources/MeetingAgentCore/DeepgramTranscriptionProvider.swift`: emit speech events instead of realtime transcript segment updates.
- `Sources/MeetingAgentCore/OpenAIRealtimeTranscriptionProvider.swift`: adapt to event sink or explicitly route final-only events.
- `Sources/MeetingAgentCore/WhisperTranscriptionProvider.swift`: emit final events for local/final transcription.
- `Sources/MeetingAgentCore/MeetingRecorder.swift`: own `CaptionReducer`/`MeetingTranscriptStore`, drain caption snapshots, and remove realtime `TranscriptUpdateSink` usage.
- `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`: publish new caption turns, remove old realtime pipeline usage, wire summary/export/progress to `CaptionDocument`.
- `Sources/MeetingAgentCore/MeetingSummary.swift`: change `MeetingSummaryInput` from `[TranscriptSegment]` to `[CaptionTurn]` or a transcript-neutral evidence type.
- `Sources/MeetingAgentCore/OpenRouterMeetingSummaryProvider.swift`: render summary prompt from `CaptionTurn`.
- `Sources/MeetingAgentCore/MeetingExportService.swift`: read `CaptionDocument`, not `transcript.txt`/old transcript segments.
- `Sources/MeetingAgentCore/MeetingKnowledgePackage.swift`: read evidence from `CaptionDocument`.
- `Sources/MeetingAgentCore/LiveMeetingCockpit.swift`: either remove old caption store code from main path or keep only shared UI-compatible helpers until app migration is complete.
- `Sources/MeetingAgentApp/MainWindowView.swift`: render `CaptionTurn` groups and remove internal dependency on `transcript.txt`.
- `Sources/MeetingAgentApp/TodayAgendaView.swift`: consider a meeting readable when `transcriptJSONURL` exists.

Create or replace these tests:

- `Tests/MeetingAgentCoreTests/CaptionDocumentTests.swift`
- `Tests/MeetingAgentCoreTests/CaptionReducerTests.swift`
- `Tests/MeetingAgentCoreTests/MeetingTranscriptStoreTests.swift`
- `Tests/MeetingAgentCoreTests/DeepgramSpeechEventAdapterTests.swift`
- `Tests/MeetingAgentCoreTests/MeetingRecorderCaptionPipelineTests.swift`
- `Tests/MeetingAgentCoreTests/MeetingAgentViewModelCaptionRebuildTests.swift`
- Update existing summary/export/knowledge tests to use `CaptionDocument`.
- Delete or quarantine old realtime translation/caption projection tests once the new path replaces them.

## Task 1: Define v2 Caption Document

**Files:**
- Create: `Sources/MeetingAgentCore/CaptionDocument.swift`
- Test: `Tests/MeetingAgentCoreTests/CaptionDocumentTests.swift`

- [ ] **Step 1: Write failing model encode/decode tests**

Add:

```swift
import XCTest
@testable import MeetingAgentCore

final class CaptionDocumentTests: XCTestCase {
    func testCaptionDocumentEncodesAndDecodesV2TurnsAndSpeakers() throws {
        let document = CaptionDocument(
            provider: TranscriptProviderInfo(id: "deepgram-transcribe", model: "nova-3", language: "zh-CN"),
            speakers: [CaptionSpeaker(id: "speaker-0", label: "User A")],
            turns: [
                CaptionTurn(
                    id: "turn-1",
                    speakerID: "speaker-0",
                    speakerLabel: "User A",
                    text: "我们确认负责人。",
                    startTimeSeconds: 1.0,
                    endTimeSeconds: 2.0,
                    isFinal: true,
                    boundaryReason: .punctuation,
                    source: CaptionTurnSource(providerID: "deepgram-transcribe", utteranceIDs: ["dg-1"], confidence: 0.91, language: "zh-CN")
                )
            ]
        )

        let data = try JSONEncoder.meetingAgent.encode(document)
        let decoded = try JSONDecoder.meetingAgent.decode(CaptionDocument.self, from: data)

        XCTAssertEqual(decoded.version, 2)
        XCTAssertEqual(decoded.turns.first?.text, "我们确认负责人。")
        XCTAssertEqual(decoded.speakers.first?.label, "User A")
    }

    func testRenderedTranscriptIsDerivedFromDocument() {
        let document = CaptionDocument(
            speakers: [
                CaptionSpeaker(id: "speaker-0", label: "User A"),
                CaptionSpeaker(id: "speaker-1", label: "User B")
            ],
            turns: [
                CaptionTurn(id: "a", speakerID: "speaker-0", speakerLabel: "User A", text: "第一句。", isFinal: true),
                CaptionTurn(id: "b", speakerID: "speaker-1", speakerLabel: "User B", text: "第二句。", isFinal: true)
            ]
        )

        XCTAssertEqual(document.renderedTranscript(), "User A:\n第一句。\n\nUser B:\n第二句。")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
swift test --filter CaptionDocumentTests
```

Expected: compile failure because `CaptionDocument`, `CaptionTurn`, `CaptionSpeaker`, `CaptionTurnSource`, and `TranscriptProviderInfo` do not exist.

- [ ] **Step 3: Implement the v2 document types**

Add `Sources/MeetingAgentCore/CaptionDocument.swift`:

```swift
import Foundation

public struct CaptionDocument: Codable, Equatable {
    public let version: Int
    public var provider: TranscriptProviderInfo?
    public var speakers: [CaptionSpeaker]
    public var turns: [CaptionTurn]

    public init(
        version: Int = 2,
        provider: TranscriptProviderInfo? = nil,
        speakers: [CaptionSpeaker] = [],
        turns: [CaptionTurn] = []
    ) {
        self.version = version
        self.provider = provider
        self.speakers = speakers
        self.turns = turns
    }

    public func renderedTranscript(includeDrafts: Bool = false) -> String {
        let labelsByID = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0.label ?? $0.id) })
        var blocks: [(label: String, texts: [String])] = []
        for turn in turns where includeDrafts || turn.isFinal {
            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let label = turn.speakerID.flatMap { labelsByID[$0] } ?? turn.speakerLabel ?? "Unknown Speaker"
            if let last = blocks.indices.last, blocks[last].label == label {
                blocks[last].texts.append(text)
            } else {
                blocks.append((label, [text]))
            }
        }
        return blocks
            .map { "\($0.label):\n\($0.texts.joined(separator: "\n"))" }
            .joined(separator: "\n\n")
    }
}

public struct TranscriptProviderInfo: Codable, Equatable {
    public var id: String
    public var model: String?
    public var language: String?

    public init(id: String, model: String? = nil, language: String? = nil) {
        self.id = id
        self.model = model
        self.language = language
    }
}

public struct CaptionSpeaker: Codable, Equatable, Identifiable {
    public var id: String
    public var label: String?

    public init(id: String, label: String? = nil) {
        self.id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        self.label = label?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
    }
}

public enum CaptionBoundaryReason: String, Codable, Equatable {
    case speakerChanged
    case pause
    case punctuation
    case speechFinal
    case manualStop
}

public struct CaptionTurn: Codable, Equatable, Identifiable {
    public var id: String
    public var speakerID: String?
    public var speakerLabel: String?
    public var text: String
    public var startTimeSeconds: Double?
    public var endTimeSeconds: Double?
    public var isFinal: Bool
    public var boundaryReason: CaptionBoundaryReason?
    public var source: CaptionTurnSource

    public init(
        id: String,
        speakerID: String? = nil,
        speakerLabel: String? = nil,
        text: String,
        startTimeSeconds: Double? = nil,
        endTimeSeconds: Double? = nil,
        isFinal: Bool,
        boundaryReason: CaptionBoundaryReason? = nil,
        source: CaptionTurnSource = CaptionTurnSource(providerID: "unknown")
    ) {
        self.id = id
        self.speakerID = speakerID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        self.speakerLabel = speakerLabel?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.startTimeSeconds = startTimeSeconds
        self.endTimeSeconds = endTimeSeconds
        self.isFinal = isFinal
        self.boundaryReason = boundaryReason
        self.source = source
    }
}

public struct CaptionTurnSource: Codable, Equatable {
    public var providerID: String
    public var utteranceIDs: [String]
    public var confidence: Double?
    public var language: String?

    public init(
        providerID: String,
        utteranceIDs: [String] = [],
        confidence: Double? = nil,
        language: String? = nil
    ) {
        self.providerID = providerID
        self.utteranceIDs = Array(Set(utteranceIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
        self.confidence = confidence
        self.language = language?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
    }
}

private extension String {
    var nilIfBlank: String? {
        isEmpty ? nil : self
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run:

```bash
swift test --filter CaptionDocumentTests
```

Expected: `CaptionDocumentTests` passes.

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingAgentCore/CaptionDocument.swift Tests/MeetingAgentCoreTests/CaptionDocumentTests.swift
git commit -m "feat: add caption document model"
```

## Task 2: Define Speech Recognition Events

**Files:**
- Create: `Sources/MeetingAgentCore/SpeechRecognitionEvent.swift`
- Test: `Tests/MeetingAgentCoreTests/SpeechRecognitionEventTests.swift`

- [ ] **Step 1: Write failing event tests**

Add:

```swift
import XCTest
@testable import MeetingAgentCore

final class SpeechRecognitionEventTests: XCTestCase {
    func testPayloadNormalizesBlankProviderUtteranceID() {
        let payload = SpeechUtterancePayload(
            providerID: "deepgram-transcribe",
            providerUtteranceID: " ",
            speaker: TranscriptSpeaker(identifier: "speaker-0"),
            startTimeSeconds: 1,
            endTimeSeconds: 2,
            text: " hello ",
            language: " zh-CN ",
            confidence: 0.9,
            boundary: SpeechBoundary(speechFinal: false, punctuationFinal: false, pauseDurationSeconds: nil)
        )

        XCTAssertNil(payload.providerUtteranceID)
        XCTAssertEqual(payload.text, "hello")
        XCTAssertEqual(payload.language, "zh-CN")
        XCTAssertEqual(payload.fallbackKey.providerID, "deepgram-transcribe")
    }

    func testPunctuationBoundaryDetectsChineseSentenceEnd() {
        XCTAssertTrue(SpeechBoundary.detectsPunctuationFinal(in: "我们确认负责人。"))
        XCTAssertTrue(SpeechBoundary.detectsPunctuationFinal(in: "可以吗？"))
        XCTAssertFalse(SpeechBoundary.detectsPunctuationFinal(in: "我们确认负责人"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
swift test --filter SpeechRecognitionEventTests
```

Expected: compile failure because event types do not exist.

- [ ] **Step 3: Implement event protocol**

Add `Sources/MeetingAgentCore/SpeechRecognitionEvent.swift`:

```swift
import Foundation

public enum SpeechRecognitionEvent: Equatable {
    case hypothesis(SpeechUtterancePayload)
    case final(SpeechUtterancePayload)
    case providerStatus(ProviderStatus)
}

public struct ProviderStatus: Equatable {
    public var providerID: String
    public var message: String

    public init(providerID: String, message: String) {
        self.providerID = providerID
        self.message = message
    }
}

public struct SpeechBoundary: Equatable {
    public var speechFinal: Bool
    public var punctuationFinal: Bool
    public var pauseDurationSeconds: Double?

    public init(
        speechFinal: Bool = false,
        punctuationFinal: Bool = false,
        pauseDurationSeconds: Double? = nil
    ) {
        self.speechFinal = speechFinal
        self.punctuationFinal = punctuationFinal
        self.pauseDurationSeconds = pauseDurationSeconds
    }

    public static func detectsPunctuationFinal(in text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return ["。", "！", "？", ".", "!", "?"].contains(String(last))
    }
}

public struct SpeechUtteranceKey: Hashable, Equatable {
    public var providerID: String
    public var speakerID: String?
    public var startTimeSeconds: Double?

    public init(providerID: String, speakerID: String?, startTimeSeconds: Double?) {
        self.providerID = providerID
        self.speakerID = speakerID
        self.startTimeSeconds = startTimeSeconds
    }
}

public struct SpeechUtterancePayload: Equatable {
    public var providerID: String
    public var providerUtteranceID: String?
    public var fallbackKey: SpeechUtteranceKey
    public var speaker: TranscriptSpeaker?
    public var startTimeSeconds: Double?
    public var endTimeSeconds: Double?
    public var text: String
    public var language: String?
    public var confidence: Double?
    public var boundary: SpeechBoundary

    public init(
        providerID: String,
        providerUtteranceID: String?,
        speaker: TranscriptSpeaker?,
        startTimeSeconds: Double?,
        endTimeSeconds: Double?,
        text: String,
        language: String?,
        confidence: Double?,
        boundary: SpeechBoundary
    ) {
        let normalizedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.providerID = normalizedProviderID.isEmpty ? "unknown" : normalizedProviderID
        self.providerUtteranceID = providerUtteranceID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        self.speaker = speaker
        self.startTimeSeconds = startTimeSeconds
        self.endTimeSeconds = endTimeSeconds
        self.text = normalizedText
        self.language = language?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        self.confidence = confidence
        self.boundary = boundary
        self.fallbackKey = SpeechUtteranceKey(
            providerID: self.providerID,
            speakerID: speaker?.identifier,
            startTimeSeconds: startTimeSeconds
        )
    }
}

private extension String {
    var nilIfBlank: String? { isEmpty ? nil : self }
}
```

- [ ] **Step 4: Run tests**

Run:

```bash
swift test --filter SpeechRecognitionEventTests
```

Expected: tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingAgentCore/SpeechRecognitionEvent.swift Tests/MeetingAgentCoreTests/SpeechRecognitionEventTests.swift
git commit -m "feat: add speech recognition events"
```

## Task 3: Implement Caption Reducer

**Files:**
- Create: `Sources/MeetingAgentCore/CaptionReducer.swift`
- Test: `Tests/MeetingAgentCoreTests/CaptionReducerTests.swift`

- [ ] **Step 1: Write failing reducer tests**

Add tests for:

```swift
func testInterimHypothesesReplaceSameVisibleDraft()
func testFinalPromotesDraftWithoutDuplicatingTurn()
func testDuplicateFinalIsIgnored()
func testDifferentSpeakersCreateSeparateTurns()
func testSameSpeakerWithoutBoundaryExtendsSameTurn()
func testPauseBoundaryCreatesNewTurn()
func testPunctuationBoundaryCreatesNewTurn()
func testSpeechFinalBoundaryCreatesNewTurn()
func testLongCJKWithoutBoundaryDoesNotSplitByCharacterCount()
```

Use helper:

```swift
private func payload(
    id: String?,
    speakerID: String?,
    start: Double,
    end: Double,
    text: String,
    speechFinal: Bool = false,
    pause: Double? = nil
) -> SpeechUtterancePayload {
    SpeechUtterancePayload(
        providerID: "deepgram-transcribe",
        providerUtteranceID: id,
        speaker: speakerID.map { TranscriptSpeaker(identifier: $0) },
        startTimeSeconds: start,
        endTimeSeconds: end,
        text: text,
        language: "zh-CN",
        confidence: 0.9,
        boundary: SpeechBoundary(
            speechFinal: speechFinal,
            punctuationFinal: SpeechBoundary.detectsPunctuationFinal(in: text),
            pauseDurationSeconds: pause
        )
    )
}
```

For the no-character-split test, assert:

```swift
XCTAssertEqual(document.turns.count, 1)
XCTAssertEqual(document.turns[0].text, "我们今天先确认日本市场的发布节奏然后再讨论韩国客户的本地化需求")
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
swift test --filter CaptionReducerTests
```

Expected: compile failure because `CaptionReducer` does not exist.

- [ ] **Step 3: Implement reducer**

Add `Sources/MeetingAgentCore/CaptionReducer.swift` with:

```swift
import Foundation

public struct CaptionReducerPolicy: Equatable {
    public var pauseBoundarySeconds: Double

    public init(pauseBoundarySeconds: Double = 0.9) {
        self.pauseBoundarySeconds = pauseBoundarySeconds
    }
}

public struct CaptionReducer {
    private var document: CaptionDocument
    private var activeDrafts: [String: String] = [:]
    private var committedFinalKeys = Set<String>()
    private let policy: CaptionReducerPolicy

    public init(document: CaptionDocument = CaptionDocument(), policy: CaptionReducerPolicy = CaptionReducerPolicy()) {
        self.document = document
        self.policy = policy
    }

    public var currentDocument: CaptionDocument { document }

    @discardableResult
    public mutating func apply(_ event: SpeechRecognitionEvent) -> CaptionDocument {
        switch event {
        case .hypothesis(let payload):
            applyHypothesis(payload)
        case .final(let payload):
            applyFinal(payload)
        case .providerStatus:
            break
        }
        return document
    }

    public mutating func flushOpenDrafts(reason: CaptionBoundaryReason = .manualStop) -> CaptionDocument {
        for turnID in activeDrafts.values {
            if let index = document.turns.firstIndex(where: { $0.id == turnID }) {
                document.turns[index].isFinal = true
                document.turns[index].boundaryReason = reason
            }
        }
        activeDrafts.removeAll()
        return document
    }

    private mutating func applyHypothesis(_ payload: SpeechUtterancePayload) {
        guard !payload.text.isEmpty else { return }
        registerSpeaker(payload.speaker)
        let key = matchingActiveKey(for: payload) ?? stableKey(for: payload)
        if let turnID = activeDrafts[key], let index = document.turns.firstIndex(where: { $0.id == turnID }) {
            document.turns[index] = turn(from: payload, id: turnID, isFinal: false, existingSource: document.turns[index].source)
        } else {
            let newTurn = turn(from: payload, id: "turn-\(UUID().uuidString)", isFinal: false)
            document.turns.append(newTurn)
            activeDrafts[key] = newTurn.id
        }
    }

    private mutating func applyFinal(_ payload: SpeechUtterancePayload) {
        guard !payload.text.isEmpty else { return }
        registerSpeaker(payload.speaker)
        let finalKey = finalDedupKey(for: payload)
        guard !committedFinalKeys.contains(finalKey) else { return }
        committedFinalKeys.insert(finalKey)

        if let key = matchingActiveKey(for: payload), let turnID = activeDrafts[key], let index = document.turns.firstIndex(where: { $0.id == turnID }) {
            document.turns[index] = turn(from: payload, id: turnID, isFinal: true, existingSource: document.turns[index].source)
            document.turns[index].boundaryReason = boundaryReason(for: payload)
            activeDrafts[key] = nil
            return
        }

        if shouldExtendPreviousTurn(with: payload), let lastIndex = document.turns.indices.last {
            document.turns[lastIndex].text = joined(document.turns[lastIndex].text, payload.text)
            document.turns[lastIndex].endTimeSeconds = payload.endTimeSeconds ?? document.turns[lastIndex].endTimeSeconds
            document.turns[lastIndex].isFinal = true
            document.turns[lastIndex].boundaryReason = boundaryReason(for: payload)
            document.turns[lastIndex].source = mergedSource(document.turns[lastIndex].source, payload: payload)
        } else {
            var newTurn = turn(from: payload, id: "turn-\(UUID().uuidString)", isFinal: true)
            newTurn.boundaryReason = boundaryReason(for: payload)
            document.turns.append(newTurn)
        }
    }
}
```

Complete the private helpers in the same file:

- `registerSpeaker(_:)`
- `stableKey(for:)`
- `matchingActiveKey(for:)`
- `finalDedupKey(for:)`
- `turn(from:id:isFinal:existingSource:)`
- `boundaryReason(for:)`
- `shouldExtendPreviousTurn(with:)`
- `sameSpeaker(_:_:)`
- `timeRangesOverlapOrAreClose(_:_:tolerance:)`
- `textsAreRevisionRelated(_:_:)`
- `joined(_:_:)`
- `mergedSource(_:payload:)`

Implementation constraints:

- `shouldExtendPreviousTurn` must return `false` on speaker change.
- It must return `false` when `payload.boundary.pauseDurationSeconds >= policy.pauseBoundarySeconds`.
- It must return `false` when the previous final turn has a hard boundary from `.speechFinal`, `.punctuation`, or `.pause`.
- It must never inspect character count or word count for splitting.
- `textsAreRevisionRelated` can use prefix/contains overlap for first implementation.

- [ ] **Step 4: Run reducer tests**

Run:

```bash
swift test --filter CaptionReducerTests
```

Expected: all reducer tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingAgentCore/CaptionReducer.swift Tests/MeetingAgentCoreTests/CaptionReducerTests.swift
git commit -m "feat: add caption reducer"
```

## Task 4: Add Meeting Transcript Store

**Files:**
- Create: `Sources/MeetingAgentCore/MeetingTranscriptStore.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingTranscriptStoreTests.swift`
- Modify: `Sources/MeetingAgentCore/MeetingStore.swift`

- [ ] **Step 1: Write failing persistence tests**

Add tests:

```swift
func testStoreWritesAndReadsCaptionDocument() throws
func testStoreUpdatesSpeakerLabelAcrossDocument() throws
func testMeetingStoreDoesNotCreateTranscriptTxtURLForNewRecords() throws
```

Assert that `MeetingStore.createMeeting` gives a `transcriptJSONURL` ending in `transcript.json` and either `transcriptURL == nil` or no internal code uses it.

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
swift test --filter MeetingTranscriptStoreTests
```

Expected: compile failure or assertion failure because the store does not exist and `MeetingStore` still assigns `transcript.txt`.

- [ ] **Step 3: Implement store**

Add `Sources/MeetingAgentCore/MeetingTranscriptStore.swift`:

```swift
import Foundation

public final class MeetingTranscriptStore {
    private let url: URL
    private let fileManager: FileManager

    public init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    public func read() throws -> CaptionDocument {
        guard fileManager.fileExists(atPath: url.path) else {
            return CaptionDocument()
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder.meetingAgent.decode(CaptionDocument.self, from: data)
    }

    public func write(_ document: CaptionDocument) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder.meetingAgent.encode(document)
        try data.write(to: url, options: .atomic)
    }

    public func updateSpeakerLabel(speakerID: String, label: String) throws -> CaptionDocument {
        var document = try read()
        let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = document.speakers.firstIndex(where: { $0.id == speakerID }) {
            document.speakers[index].label = normalizedLabel.isEmpty ? nil : normalizedLabel
        } else {
            document.speakers.append(CaptionSpeaker(id: speakerID, label: normalizedLabel))
        }
        for index in document.turns.indices where document.turns[index].speakerID == speakerID {
            document.turns[index].speakerLabel = normalizedLabel.isEmpty ? nil : normalizedLabel
        }
        try write(document)
        return document
    }
}
```

- [ ] **Step 4: Modify `MeetingStore`**

Change `Sources/MeetingAgentCore/MeetingStore.swift` meeting creation so new records no longer assign `transcript.txt`:

```swift
transcriptURL: nil,
transcriptJSONURL: directory.appendingPathComponent("transcript.json"),
```

Keep `transcriptURL` on `MeetingRecord` if removing it causes broad churn; treat it as legacy/export-only.

- [ ] **Step 5: Run persistence tests**

Run:

```bash
swift test --filter MeetingTranscriptStoreTests
```

Expected: tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/MeetingAgentCore/MeetingTranscriptStore.swift Sources/MeetingAgentCore/MeetingStore.swift Tests/MeetingAgentCoreTests/MeetingTranscriptStoreTests.swift
git commit -m "feat: persist caption transcript document"
```

## Task 5: Make Performance Events JSONL-Safe

**Files:**
- Modify: `Sources/MeetingAgentCore/PerformanceEventLogger.swift`
- Test: `Tests/MeetingAgentCoreTests/PerformanceEventLoggerTests.swift`

- [ ] **Step 1: Write failing concurrent write test**

Add:

```swift
func testConcurrentWritesProduceValidJSONLLines() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("events-\(UUID().uuidString).jsonl")
    let logger = PerformanceEventLogger(url: url)

    await withTaskGroup(of: Void.self) { group in
        for index in 0..<100 {
            group.addTask {
                logger.log("event-\(index)", metadata: ["index": "\(index)"])
            }
        }
    }

    let lines = try String(contentsOf: url).split(separator: "\n")
    XCTAssertEqual(lines.count, 100)
    for line in lines {
        XCTAssertNoThrow(try JSONDecoder.meetingAgent.decode(PerformanceEvent.self, from: Data(line.utf8)))
    }
}
```

- [ ] **Step 2: Run test to verify current behavior**

Run:

```bash
swift test --filter PerformanceEventLoggerTests/testConcurrentWritesProduceValidJSONLLines
```

Expected: fail or flake if writes interleave; if it passes locally, keep it as regression coverage.

- [ ] **Step 3: Serialize writes**

Modify `PerformanceEventLogger` so `append(_:)` uses a private serial `DispatchQueue` or actor-style lock:

```swift
private let writeQueue = DispatchQueue(label: "MeetingAgent.PerformanceEventLogger.write")

public func append(_ event: PerformanceEvent) {
    writeQueue.async { [url] in
        do {
            let data = try JSONEncoder.meetingAgent.encode(event)
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.write(contentsOf: Data("\n".utf8))
                try handle.close()
            } else {
                try data.appendingNewline().write(to: url, options: .atomic)
            }
        } catch {
            // Performance logging must never affect recording.
        }
    }
}
```

If tests need deterministic completion, add a test-only `flush()` method guarded as internal:

```swift
func flush() {
    writeQueue.sync {}
}
```

- [ ] **Step 4: Run logger tests**

Run:

```bash
swift test --filter PerformanceEventLoggerTests
```

Expected: tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingAgentCore/PerformanceEventLogger.swift Tests/MeetingAgentCoreTests/PerformanceEventLoggerTests.swift
git commit -m "fix: serialize performance event writes"
```

## Task 6: Add Deepgram Speech Event Adapter

**Files:**
- Create: `Sources/MeetingAgentCore/DeepgramSpeechEventAdapter.swift`
- Modify: `Sources/MeetingAgentCore/DeepgramTranscriptionProvider.swift`
- Test: `Tests/MeetingAgentCoreTests/DeepgramSpeechEventAdapterTests.swift`

- [ ] **Step 1: Write adapter tests**

Add tests that feed representative Deepgram streaming JSON:

```swift
func testInterimResponseMapsToHypothesisEvent()
func testFinalResponseMapsToFinalEvent()
func testWordSpeakerMapsToTranscriptSpeaker()
func testSpeechFinalMapsToBoundary()
func testPunctuationMapsToBoundary()
```

Assert:

```swift
guard case .hypothesis(let payload) = events.single else { XCTFail(); return }
XCTAssertEqual(payload.speaker?.identifier, "deepgram-speaker-0")
XCTAssertEqual(payload.boundary.speechFinal, false)
XCTAssertEqual(payload.boundary.punctuationFinal, true)
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
swift test --filter DeepgramSpeechEventAdapterTests
```

Expected: compile failure because adapter does not exist.

- [ ] **Step 3: Implement adapter**

Add `DeepgramSpeechEventAdapter`:

```swift
public enum DeepgramSpeechEventAdapter {
    public static func events(from data: Data, providerID: String) -> [SpeechRecognitionEvent] {
        guard let response = try? JSONDecoder.meetingAgent.decode(DeepgramStreamingResponse.self, from: data),
              let isFinal = response.isFinal,
              let alternative = response.channel?.alternatives.first
        else {
            return []
        }

        let words = alternative.words ?? []
        let text = text(from: alternative, words: words)
        guard !text.isEmpty else { return [] }
        let speaker = speaker(from: words)
        let payload = SpeechUtterancePayload(
            providerID: providerID,
            providerUtteranceID: utteranceID(providerID: providerID, response: response, words: words),
            speaker: speaker,
            startTimeSeconds: words.compactMap(\.start).first ?? response.start,
            endTimeSeconds: words.compactMap(\.end).last ?? response.start.flatMap { start in response.duration.map { start + $0 } },
            text: text,
            language: response.metadata?.detectedLanguage,
            confidence: alternative.confidence,
            boundary: SpeechBoundary(
                speechFinal: response.speechFinal == true,
                punctuationFinal: SpeechBoundary.detectsPunctuationFinal(in: text),
                pauseDurationSeconds: nil
            )
        )
        return [isFinal ? .final(payload) : .hypothesis(payload)]
    }
}
```

Keep helpers private:

- `text(from:words:)`
- `speaker(from:)`
- `utteranceID(providerID:response:words:)`

If mixed speakers appear within one Deepgram response, split into one event per contiguous speaker run. Preserve the same mapping as the old mapper, but output speech events instead of `TranscriptSegment`.

- [ ] **Step 4: Run adapter tests**

Run:

```bash
swift test --filter DeepgramSpeechEventAdapterTests
```

Expected: tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingAgentCore/DeepgramSpeechEventAdapter.swift Sources/MeetingAgentCore/DeepgramTranscriptionProvider.swift Tests/MeetingAgentCoreTests/DeepgramSpeechEventAdapterTests.swift
git commit -m "feat: map deepgram responses to speech events"
```

## Task 7: Replace Transcription Sink With Speech Event Sink

**Files:**
- Modify: `Sources/MeetingAgentCore/SpeechTranscriptionProvider.swift`
- Modify: `Sources/MeetingAgentCore/DeepgramTranscriptionProvider.swift`
- Modify: `Sources/MeetingAgentCore/OpenAIRealtimeTranscriptionProvider.swift`
- Modify: `Sources/MeetingAgentCore/WhisperTranscriptionProvider.swift`
- Test: provider tests touched by sink changes.

- [ ] **Step 1: Add sink protocol tests through existing provider test fakes**

Update provider test fakes to record events:

```swift
private final class RecordingSpeechRecognitionEventSink: SpeechRecognitionEventSink {
    private(set) var events: [SpeechRecognitionEvent] = []
    func receive(_ event: SpeechRecognitionEvent) {
        events.append(event)
    }
}
```

Assert Deepgram emits `.hypothesis` and `.final` events through the sink.

- [ ] **Step 2: Add event sink protocol**

In `SpeechTranscriptionProvider.swift`:

```swift
public protocol SpeechRecognitionEventSink: AnyObject {
    func receive(_ event: SpeechRecognitionEvent)
}
```

Change `SpeechTranscriptionStreamContext`:

```swift
public let speechEventSink: SpeechRecognitionEventSink?
```

Keep `transcriptUpdateSink` temporarily only if needed for final transcript compatibility inside this task. Mark it as legacy in a comment and remove it in Task 8.

- [ ] **Step 3: Emit Deepgram speech events**

In `URLSessionDeepgramStreamingSession.yieldSegments(from:)`, either rename to `yieldEvents(from:)` or keep segment stream temporarily and add an `events` stream. Preferred final shape:

```swift
public protocol DeepgramStreamingTranscriptionSession: AnyObject {
    var events: AsyncStream<SpeechRecognitionEvent> { get }
    func send(_ frame: AudioFrame) async throws
    func close() async
}
```

The websocket receive path should call:

```swift
for event in DeepgramSpeechEventAdapter.events(from: data, providerID: "deepgram-transcribe") {
    continuation?.yield(event)
}
```

- [ ] **Step 4: Update OpenAI and Whisper**

OpenAI realtime:

```swift
speechEventSink?.receive(.hypothesis(payload))
speechEventSink?.receive(.final(payload))
```

Whisper/local final transcription:

```swift
for segment in transcriptSegments {
    speechEventSink?.receive(.final(payload(from: segment)))
}
```

- [ ] **Step 5: Run provider tests**

Run:

```bash
swift test --filter DeepgramStreamingTranscriptionProviderTests
swift test --filter OpenAIRealtimeTranscriptionProviderTests
swift test --filter WhisperTranscriptionProviderTests
```

Expected: updated provider tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/MeetingAgentCore/SpeechTranscriptionProvider.swift Sources/MeetingAgentCore/DeepgramTranscriptionProvider.swift Sources/MeetingAgentCore/OpenAIRealtimeTranscriptionProvider.swift Sources/MeetingAgentCore/WhisperTranscriptionProvider.swift Tests/MeetingAgentCoreTests/DeepgramStreamingTranscriptionProviderTests.swift Tests/MeetingAgentCoreTests/OpenAIRealtimeTranscriptionProviderTests.swift Tests/MeetingAgentCoreTests/WhisperTranscriptionProviderTests.swift
git commit -m "feat: route transcription through speech events"
```

## Task 8: Replace Recorder Transcript Pipeline

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingRecorder.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingRecorderCaptionPipelineTests.swift`

- [ ] **Step 1: Write recorder pipeline tests**

Test cases:

```swift
func testRecorderDrainsCaptionDocumentUpdatesFromSpeechEvents()
func testRecorderPersistsTranscriptJSONWithoutTranscriptTxt()
func testRecorderFlushesOpenDraftsOnStop()
```

Use a fake transcriber that calls `speechEventSink.receive(.hypothesis(...))` and `.final(...)`.

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
swift test --filter MeetingRecorderCaptionPipelineTests
```

Expected: compile or assertion failure because recorder still drains `TranscriptSegmentAccumulationResult`.

- [ ] **Step 3: Replace `RecordingTranscriptUpdateSink`**

In `MeetingRecorder.swift`, replace `RecordingTranscriptUpdateSink` with:

```swift
private final class RecordingSpeechEventSink: SpeechRecognitionEventSink {
    private var reducer = CaptionReducer()
    private let store: MeetingTranscriptStore
    private let performanceEventLogger: PerformanceEventLogger?
    private var pendingDocuments: [CaptionDocument] = []
    private let lock = NSLock()

    init(transcriptJSONURL: URL, performanceEventLogger: PerformanceEventLogger?) {
        self.store = MeetingTranscriptStore(url: transcriptJSONURL)
        self.performanceEventLogger = performanceEventLogger
    }

    func receive(_ event: SpeechRecognitionEvent) {
        lock.lock()
        defer { lock.unlock() }
        let document = reducer.apply(event)
        try? store.write(document)
        pendingDocuments.append(document)
    }

    func drainDocuments() -> [CaptionDocument] {
        lock.lock()
        defer { lock.unlock() }
        let output = pendingDocuments
        pendingDocuments.removeAll()
        return output
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        let document = reducer.flushOpenDrafts()
        try? store.write(document)
        pendingDocuments.append(document)
    }
}
```

- [ ] **Step 4: Change recorder public drain API**

Replace:

```swift
public func drainTranscriptUpdates() -> [TranscriptSegmentAccumulationResult]
```

with:

```swift
public func drainCaptionDocuments() -> [CaptionDocument] {
    speechEventSink?.drainDocuments() ?? []
}
```

Rename stored property `transcriptUpdateSink` to `speechEventSink`.

- [ ] **Step 5: Update transcriber factory signature**

Change factory closure to accept `SpeechRecognitionEventSink?` and pass it into `StreamingSpeechTranscriberFactory.startTranscriber`.

- [ ] **Step 6: Run recorder tests**

Run:

```bash
swift test --filter MeetingRecorderCaptionPipelineTests
```

Expected: tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/MeetingAgentCore/MeetingRecorder.swift Tests/MeetingAgentCoreTests/MeetingRecorderCaptionPipelineTests.swift
git commit -m "feat: persist realtime captions from recorder"
```

## Task 9: Replace ViewModel Realtime Caption Path

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelCaptionRebuildTests.swift`

- [ ] **Step 1: Write focused ViewModel tests**

Test cases:

```swift
func testLiveCaptionsPublishLatestCaptionDocument()
func testDraftCorrectionReplacesVisibleLine()
func testSpeakerGroupsUseModelSpeakerIDs()
func testStoppingRecordingKeepsFlushedFinalCaptionVisible()
```

Use recorder fixture updated for `CaptionDocument`.

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
swift test --filter MeetingAgentViewModelCaptionRebuildTests
```

Expected: compile failure until ViewModel publishes new caption type.

- [ ] **Step 3: Change published caption state**

Replace:

```swift
@Published public private(set) var liveCaptionTurns: [LiveCaptionTurn] = []
```

with:

```swift
@Published public private(set) var liveCaptionTurns: [CaptionTurn] = []
```

Keep property name for UI churn minimization.

- [ ] **Step 4: Replace drain handling**

In `drainRecordingFrames`, replace old transcript accumulation path:

```swift
let captionDocuments = recorder.drainCaptionDocuments()
if let latest = captionDocuments.last {
    liveCaptionTurns = latest.turns
    meetingProgressHealth.caption = latest.turns.isEmpty ? .idle : .live
}
```

Remove calls to:

- `applyTranscriptAccumulationResultsToLiveCaptions`
- draft caption input throttle
- live caption snapshot debounce
- `RealtimeCaptionSession`
- `LiveCaptionPipeline`

for the active recording path.

- [ ] **Step 5: Replace replay/load behavior**

When selecting a meeting or loading historical selected meeting, read:

```swift
let document = try MeetingTranscriptStore(url: transcriptJSONURL).read()
liveCaptionTurns = document.turns
```

Historical compatibility is out of scope; do not fallback to old `TranscriptFileWriter`.

- [ ] **Step 6: Run ViewModel tests**

Run:

```bash
swift test --filter MeetingAgentViewModelCaptionRebuildTests
```

Expected: tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/MeetingAgentCore/MeetingAgentViewModel.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelCaptionRebuildTests.swift
git commit -m "feat: publish captions from caption document"
```

## Task 10: Replace App UI Rendering

**Files:**
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift`
- Modify: `Sources/MeetingAgentApp/TodayAgendaView.swift`
- Test: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift` or add a source-level UI contract test.

- [ ] **Step 1: Write UI source contract tests**

Update tests to assert:

```swift
XCTAssertTrue(source.contains("let liveCaptionTurns: [CaptionTurn]"))
XCTAssertFalse(source.contains("TranscriptFileWriter.renderedTranscript"))
XCTAssertFalse(source.contains("meeting.transcriptURL == nil"))
```

- [ ] **Step 2: Update UI types**

Replace `LiveCaptionTurn` usage in `MainWindowView` with `CaptionTurn`.

Create grouping helper:

```swift
struct CaptionSpeakerGroup: Identifiable, Equatable {
    let id: String
    let speakerID: String?
    let speakerLabel: String
    var turns: [CaptionTurn]
}
```

Group consecutive turns by `speakerID`.

- [ ] **Step 3: Replace transcript fallback**

Render from `CaptionTurn.text`. Remove internal reading from `transcript.txt`.

Export Transcript button should be enabled by `meeting.transcriptJSONURL != nil`, not `transcriptURL`.

- [ ] **Step 4: Update TodayAgendaView readable transcript check**

Change:

```swift
guard let transcriptURL = meeting.transcriptURL else { return false }
```

to:

```swift
guard let transcriptJSONURL = meeting.transcriptJSONURL else { return false }
return FileManager.default.isReadableFile(atPath: transcriptJSONURL.path)
```

- [ ] **Step 5: Run UI contract tests**

Run:

```bash
swift test --filter MainWindowViewLayoutTests
```

Expected: tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/MeetingAgentApp/MainWindowView.swift Sources/MeetingAgentApp/TodayAgendaView.swift Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift
git commit -m "feat: render caption document turns"
```

## Task 11: Move Summary, Export, Progress, and Knowledge to CaptionDocument

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingSummary.swift`
- Modify: `Sources/MeetingAgentCore/OpenRouterMeetingSummaryProvider.swift`
- Modify: `Sources/MeetingAgentCore/MeetingExportService.swift`
- Modify: `Sources/MeetingAgentCore/LiveMeetingCockpit.swift` or split `MeetingProgressCoordinator` into its own file if needed.
- Modify: meeting knowledge package files that read `[TranscriptSegment]`.
- Tests: update summary/export/progress/knowledge tests.

- [ ] **Step 1: Update summary input tests**

Replace segment fixtures with:

```swift
let turns = [
    CaptionTurn(id: "turn-1", speakerID: "speaker-a", speakerLabel: "Alice", text: "We confirmed launch owner.", startTimeSeconds: 12, endTimeSeconds: 15, isFinal: true)
]
```

Assert summary prompts include:

```text
- id: turn-1
  speaker: Alice
  text: We confirmed launch owner.
```

- [ ] **Step 2: Change `MeetingSummaryInput`**

Replace:

```swift
public let segments: [TranscriptSegment]
```

with:

```swift
public let turns: [CaptionTurn]
```

Update initializers and title generator:

```swift
enum MeetingSummaryTitleGenerator {
    static func title(summary: MeetingSummary, turns: [CaptionTurn]) -> String
}
```

- [ ] **Step 3: Update export service**

Export transcript text via:

```swift
let document = try MeetingTranscriptStore(url: transcriptJSONURL).read()
let text = document.renderedTranscript()
```

Generate SRT/VTT from final turns with timing.

- [ ] **Step 4: Update meeting progress**

Change process signature:

```swift
public func process(turns: [CaptionTurn]) async
```

Ignore drafts unless the existing product behavior explicitly needs recent draft analysis. Default to final turns.

- [ ] **Step 5: Update knowledge package**

Use `CaptionTurn.id` as evidence ID. Use speaker label from turn or speaker table. Anchors become `turn-<id>` or timestamp anchors.

- [ ] **Step 6: Run affected tests**

Run:

```bash
swift test --filter MeetingSummaryTests
swift test --filter OpenRouterMeetingSummaryProviderTests
swift test --filter MeetingExportServiceTests
swift test --filter MeetingProgressCoordinatorTests
swift test --filter MeetingKnowledgePackageTests
```

Expected: updated tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/MeetingAgentCore Tests/MeetingAgentCoreTests
git commit -m "feat: read downstream features from caption document"
```

## Task 12: Remove Old Realtime Caption Main Path

**Files:**
- Delete or detach:
  - `Sources/MeetingAgentCore/RealtimeCaptionSession.swift`
  - `Sources/MeetingAgentCore/LiveCaptionPipeline.swift`
  - `Sources/MeetingAgentCore/CaptionTurnAssembler.swift`
  - `Sources/MeetingAgentCore/LiveCaptionChunker.swift`
- Modify: any remaining references in `Sources/MeetingAgentCore/TranslationUnitBuilder.swift`, translation remnants, and tests.
- Tests: remove obsolete tests tied to old translation-era caption projection.

- [ ] **Step 1: Search old path references**

Run:

```bash
rg -n "LiveCaptionPipeline|RealtimeCaptionSession|CaptionTurnAssembler|LiveCaptionChunker|TranscriptSegmentAccumulator|LiveCaptionTurn|sourceSegmentIDs" Sources Tests
```

Expected: list all remaining old references.

- [ ] **Step 2: Remove or replace references**

Rules:

- Replace active recording references with `CaptionReducer`/`CaptionDocument`.
- Replace UI references with `CaptionTurn`.
- Delete tests whose only purpose is old translation projection behavior.
- Keep `TranscriptSegment` only if final/offline providers still need it temporarily; it must not drive realtime captions or transcript persistence.

- [ ] **Step 3: Delete unused files**

Delete old files only after `rg` shows no production references:

```bash
git rm Sources/MeetingAgentCore/RealtimeCaptionSession.swift
git rm Sources/MeetingAgentCore/LiveCaptionPipeline.swift
git rm Sources/MeetingAgentCore/CaptionTurnAssembler.swift
git rm Sources/MeetingAgentCore/LiveCaptionChunker.swift
```

- [ ] **Step 4: Run compile**

Run:

```bash
swift test --filter CaptionDocumentTests
```

Expected: package compiles and targeted test passes.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "refactor: remove legacy realtime caption pipeline"
```

## Task 13: End-to-End Verification

**Files:**
- Modify: `scripts/analyze-meeting-performance.swift`
- Add or update: analyzer tests in `Tests/MeetingAgentCoreTests/MeetingPerformanceAnalysisScriptTests.swift`

- [ ] **Step 1: Update analyzer expectations**

Analyzer should read v2 `transcript.json` and report:

- total turns
- final turns
- draft turns
- speaker count
- duplicate final ignored count
- invalid JSONL line count
- first caption latency if events include timing

It should not require translation metrics.

- [ ] **Step 2: Add script tests**

Add fixture with v2 `transcript.json` and valid `performance-events.jsonl`. Assert output contains:

```text
Transcript Version: 2
Caption Turn Count:
Speaker Count:
Invalid Performance Event Lines: 0
```

- [ ] **Step 3: Run full unit test entrypoint**

Run:

```bash
make test
```

Expected: all tests pass and coverage gate passes.

- [ ] **Step 4: Build app**

Run:

```bash
swift build --product MeetingAgentApp
```

Expected: build succeeds.

- [ ] **Step 5: Package app**

Run:

```bash
make package-app
```

Expected: `dist/MeetingAgent.app` exists.

- [ ] **Step 6: Fresh manual recording verification**

Record a fresh Deepgram Chinese meeting sample and verify:

- no `transcript.txt` exists in the meeting directory
- `transcript.json` has `"version": 2`
- speaker IDs reflect provider output
- interim corrections replace visible drafts
- same speaker only segments on pause, punctuation, or `speechFinal`
- summary and markdown assets still generate
- `performance-events.jsonl` parses with one JSON object per line

- [ ] **Step 7: Commit final verification updates**

```bash
git add scripts Tests
git commit -m "test: verify caption document pipeline"
```

## Self-Review

Spec coverage:

- Provider/model decoupling: Tasks 2, 6, 7.
- Draft replacement: Task 3.
- Final promotion/idempotency: Task 3.
- Speaker separation: Tasks 1, 3, 10.
- No character/word-count segmentation: Task 3.
- `transcript.json` only: Tasks 4, 8, 10.
- Derived assets retained: Task 11.
- JSONL validity: Task 5 and Task 13.
- Old architecture removal: Task 12.

Placeholder scan:

- No `TBD`, `TODO`, or intentionally deferred implementation placeholders.
- Each task has concrete files, tests, commands, and expected outcomes.

Type consistency:

- `CaptionDocument`, `CaptionTurn`, `CaptionSpeaker`, `CaptionTurnSource`, `TranscriptProviderInfo`, `SpeechRecognitionEvent`, `SpeechUtterancePayload`, `SpeechBoundary`, `CaptionReducer`, and `MeetingTranscriptStore` are introduced before downstream tasks reference them.
