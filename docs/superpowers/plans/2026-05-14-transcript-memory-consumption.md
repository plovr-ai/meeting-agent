# Transcript Memory Consumption Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make in-memory caption and summary state the only product consumption surface; transcript and summary files become repository-backed hydrate/backup details.

**Architecture:** Introduce caption-native read models (`TranscriptConsumptionView`) and meeting-scoped memory state (`MeetingSessionState`). Product consumers read memory state; repositories are the only file boundary for `CaptionDocument` and `MeetingSummary`. Historical completed meetings hydrate transcript and summary into memory once; if summary is missing, it is generated from the hydrated in-memory transcript and persisted.

**Tech Stack:** Swift 5.9, XCTest, SwiftUI view model state, existing `CaptionDocument`, `MeetingSummary`, `MeetingSummaryWriter`, `MeetingTranscriptStore`, `make test`.

---

## File Structure

- Create `Sources/MeetingAgentCore/TranscriptConsumptionView.swift`
  - Defines `TranscriptConsumptionView`, turns, sections, quality, and a projector from `CaptionDocument`.
- Create `Sources/MeetingAgentCore/MeetingSessionState.swift`
  - Defines `MeetingSessionState`, `TranscriptState`, `SummaryState`, and source/status enums.
- Create `Sources/MeetingAgentCore/MeetingDataRepositories.swift`
  - Defines `TranscriptRepository`, `SummaryRepository`, file-backed implementations, and test-friendly fakes.
- Modify `Sources/MeetingAgentCore/MeetingSummary.swift`
  - Changes `MeetingSummaryInput` from legacy `segments` to `transcript: TranscriptConsumptionView`.
- Modify `Sources/MeetingAgentCore/OpenRouterMeetingSummaryProvider.swift`
  - Renders summary prompt from consumption turns/sections.
- Modify `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
  - Owns `MeetingSessionState`, hydrates completed meetings, generates missing summaries from memory, and stops direct summary/transcript file consumption.
- Modify `Sources/MeetingAgentCore/MeetingArtifactSnapshot.swift`
  - Reads already-loaded memory state instead of loading transcript/summary files.
- Modify `Sources/MeetingAgentCore/MeetingExportService.swift`
  - Accepts memory-backed transcript/summary inputs for product exports; file paths remain only for output destinations and readiness reporting.
- Modify tests under `Tests/MeetingAgentCoreTests/`
  - Add focused tests for projector, repositories, ViewModel hydration/generation, summary input, artifact snapshot, export, and active stop flow.

---

## Task 1: Add TranscriptConsumptionView Projector

**Files:**
- Create: `Sources/MeetingAgentCore/TranscriptConsumptionView.swift`
- Test: `Tests/MeetingAgentCoreTests/TranscriptConsumptionViewTests.swift`

- [ ] **Step 1: Write projector tests**

Create `Tests/MeetingAgentCoreTests/TranscriptConsumptionViewTests.swift`:

```swift
import XCTest
@testable import MeetingAgentCore

final class TranscriptConsumptionViewTests: XCTestCase {
    func testProjectorUsesFinalTurnsAndPreservesSpeakerSectionsAndSourceIDs() {
        let document = CaptionDocument(
            speakers: [
                CaptionSpeaker(id: "speaker-1", label: "Allan", providerSpeakerID: "deepgram-speaker-0")
            ],
            turns: [
                CaptionTurn(
                    id: "turn-draft",
                    speakerID: "speaker-1",
                    speakerLabel: "Allan",
                    startTimeSeconds: 0,
                    endTimeSeconds: 1,
                    sections: [CaptionSection(id: "draft-section", text: "draft text", utteranceIDs: ["draft-utt"])],
                    state: .draft,
                    source: CaptionTurnSource(providerID: "deepgram-transcribe", utteranceIDs: ["draft-utt"])
                ),
                CaptionTurn(
                    id: "turn-final",
                    speakerID: "speaker-1",
                    speakerLabel: "Allan",
                    startTimeSeconds: 2,
                    endTimeSeconds: 8,
                    sections: [
                        CaptionSection(id: "section-1", text: "我们确认负责人。", utteranceIDs: ["utt-1"], startTimeSeconds: 2, endTimeSeconds: 4),
                        CaptionSection(id: "section-2", text: "下周一上线。", utteranceIDs: ["utt-2"], startTimeSeconds: 5, endTimeSeconds: 8)
                    ],
                    state: .final,
                    source: CaptionTurnSource(providerID: "deepgram-transcribe", streamID: "stream-1", resultIDs: ["result-1"], utteranceIDs: ["utt-1", "utt-2"])
                )
            ],
            provider: CaptionProviderInfo(id: "deepgram-transcribe", model: "nova-3", locale: "zh-CN")
        )

        let view = TranscriptConsumptionView.project(meetingID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, document: document)

        XCTAssertEqual(view.language, "zh-CN")
        XCTAssertEqual(view.provider?.id, "deepgram-transcribe")
        XCTAssertEqual(view.finalTurns.count, 1)
        XCTAssertEqual(view.finalTurns.first?.turnID, "turn-final")
        XCTAssertEqual(view.finalTurns.first?.speakerID, "speaker-1")
        XCTAssertEqual(view.finalTurns.first?.speakerLabel, "Allan")
        XCTAssertEqual(view.finalTurns.first?.text, "我们确认负责人。\n下周一上线。")
        XCTAssertEqual(view.finalTurns.first?.sourceIDs, ["utt-1", "utt-2"])
        XCTAssertEqual(view.finalTurns.first?.sections.map(\.text), ["我们确认负责人。", "下周一上线。"])
        XCTAssertEqual(view.quality.finalTurnCount, 1)
        XCTAssertEqual(view.quality.draftTurnCount, 1)
        XCTAssertEqual(view.quality.unknownSpeakerTurnCount, 0)
    }

    func testProjectorFiltersEmptySectionsAndFallsBackToSpeakerID() {
        let document = CaptionDocument(turns: [
            CaptionTurn(
                id: "turn-1",
                speakerID: "speaker-unknown",
                speakerLabel: nil,
                startTimeSeconds: nil,
                endTimeSeconds: nil,
                sections: [
                    CaptionSection(id: "empty", text: "   "),
                    CaptionSection(id: "kept", text: "Needs follow-up.", utteranceIDs: ["utt-3"])
                ],
                state: .final,
                source: CaptionTurnSource(providerID: "provider", utteranceIDs: ["utt-3"])
            )
        ])

        let view = TranscriptConsumptionView.project(meetingID: UUID(), document: document)

        XCTAssertEqual(view.finalTurns.first?.speakerLabel, "speaker-unknown")
        XCTAssertEqual(view.finalTurns.first?.sections.map(\.id), ["kept"])
        XCTAssertEqual(view.quality.emptyFinalTurnCount, 0)
        XCTAssertEqual(view.quality.unknownSpeakerTurnCount, 1)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```sh
swift test --filter TranscriptConsumptionViewTests
```

Expected: compile failure because `TranscriptConsumptionView` does not exist.

- [ ] **Step 3: Implement the projector**

Create `Sources/MeetingAgentCore/TranscriptConsumptionView.swift`:

```swift
import Foundation

public struct TranscriptConsumptionView: Equatable, Sendable {
    public let meetingID: UUID
    public let language: String?
    public let provider: CaptionProviderInfo?
    public let finalTurns: [TranscriptConsumptionTurn]
    public let quality: TranscriptConsumptionQuality

    public static func project(meetingID: UUID, document: CaptionDocument) -> TranscriptConsumptionView {
        let finalTurns = document.turns
            .filter { $0.state == .final }
            .compactMap(TranscriptConsumptionTurn.init(turn:))
        let draftCount = document.turns.filter { $0.state == .draft }.count
        let unknownSpeakerCount = finalTurns.filter {
            ($0.speakerID ?? "").isEmpty || $0.speakerLabel == $0.speakerID
        }.count
        let emptyFinalTurnCount = document.turns.filter {
            $0.state == .final && $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count

        return TranscriptConsumptionView(
            meetingID: meetingID,
            language: document.provider?.locale,
            provider: document.provider,
            finalTurns: finalTurns,
            quality: TranscriptConsumptionQuality(
                finalTurnCount: finalTurns.count,
                draftTurnCount: draftCount,
                unknownSpeakerTurnCount: unknownSpeakerCount,
                emptyFinalTurnCount: emptyFinalTurnCount
            )
        )
    }
}

public struct TranscriptConsumptionTurn: Equatable, Sendable {
    public let turnID: String
    public let speakerID: String?
    public let speakerLabel: String?
    public let sections: [TranscriptConsumptionSection]
    public let text: String
    public let startTimeSeconds: Double?
    public let endTimeSeconds: Double?
    public let sourceIDs: [String]

    init?(turn: CaptionTurn) {
        let sections = turn.sections.compactMap(TranscriptConsumptionSection.init(section:))
        let text = sections.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let sourceIDs = Self.uniqueIDs(sections.flatMap(\.sourceIDs) + turn.source.utteranceIDs + turn.source.resultIDs)
        self.turnID = turn.id
        self.speakerID = turn.speakerID
        self.speakerLabel = turn.speakerLabel ?? turn.speakerID
        self.sections = sections
        self.text = text
        self.startTimeSeconds = turn.startTimeSeconds
        self.endTimeSeconds = turn.endTimeSeconds
        self.sourceIDs = sourceIDs
    }

    private static func uniqueIDs(_ values: [String]) -> [String] {
        Array(Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
    }
}

public struct TranscriptConsumptionSection: Equatable, Sendable {
    public let id: String
    public let text: String
    public let startTimeSeconds: Double?
    public let endTimeSeconds: Double?
    public let sourceIDs: [String]

    init?(section: CaptionSection) {
        let text = section.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        self.id = section.id
        self.text = text
        self.startTimeSeconds = section.startTimeSeconds
        self.endTimeSeconds = section.endTimeSeconds
        self.sourceIDs = Array(Set(section.utteranceIDs)).sorted()
    }
}

public struct TranscriptConsumptionQuality: Equatable, Sendable {
    public let finalTurnCount: Int
    public let draftTurnCount: Int
    public let unknownSpeakerTurnCount: Int
    public let emptyFinalTurnCount: Int
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run:

```sh
swift test --filter TranscriptConsumptionViewTests
```

Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```sh
git add Sources/MeetingAgentCore/TranscriptConsumptionView.swift Tests/MeetingAgentCoreTests/TranscriptConsumptionViewTests.swift
git commit -m "Add transcript consumption view"
```

---

## Task 2: Add Memory State And File Repositories

**Files:**
- Create: `Sources/MeetingAgentCore/MeetingSessionState.swift`
- Create: `Sources/MeetingAgentCore/MeetingDataRepositories.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingSessionStateTests.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingDataRepositoriesTests.swift`

- [ ] **Step 1: Write memory state tests**

Create `Tests/MeetingAgentCoreTests/MeetingSessionStateTests.swift`:

```swift
import XCTest
@testable import MeetingAgentCore

final class MeetingSessionStateTests: XCTestCase {
    func testTranscriptStateProjectsConsumptionViewFromCaptionDocument() {
        let meetingID = UUID()
        let document = CaptionDocument(
            turns: [
                CaptionTurn(
                    id: "turn-1",
                    speakerID: "speaker-1",
                    speakerLabel: "Allan",
                    sections: [CaptionSection(id: "section-1", text: "Final text", utteranceIDs: ["utt-1"])],
                    state: .final,
                    source: CaptionTurnSource(providerID: "deepgram", utteranceIDs: ["utt-1"])
                )
            ],
            provider: CaptionProviderInfo(id: "deepgram", locale: "en-US")
        )

        let state = TranscriptState(meetingID: meetingID, captionDocument: document, source: .hydratedFromPersistence)

        XCTAssertEqual(state.consumptionView.finalTurns.map(\.text), ["Final text"])
        XCTAssertEqual(state.visibleTurns.map(\.originalText), ["Final text"])
        XCTAssertEqual(state.source, .hydratedFromPersistence)
    }

    func testSummaryStateTracksLoadedSummary() {
        let summary = MeetingSummary(
            overview: "Loaded summary",
            keyTopics: [],
            decisions: [],
            actionItems: [],
            openQuestions: [],
            risks: [],
            followUps: [],
            language: "en-US",
            sourceSegmentIDs: ["turn-1"],
            generatedAt: Date(timeIntervalSince1970: 1),
            provider: "test",
            status: .succeeded,
            failureReason: nil
        )

        let state = SummaryState.loaded(summary)

        XCTAssertEqual(state.summary, summary)
        XCTAssertEqual(state.status, .loaded)
        XCTAssertEqual(state.source, .loadedFromPersistence)
    }
}
```

- [ ] **Step 2: Write repository tests**

Create `Tests/MeetingAgentCoreTests/MeetingDataRepositoriesTests.swift`:

```swift
import XCTest
@testable import MeetingAgentCore

final class MeetingDataRepositoriesTests: XCTestCase {
    func testFileTranscriptRepositoryLoadsAndSavesCaptionDocument() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-repositories-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let record = try store.createMeeting(name: "Meet", startedAt: Date()).record
        let repository = FileTranscriptRepository()
        let document = CaptionDocument(turns: [
            CaptionTurn(
                id: "turn-1",
                sections: [CaptionSection(text: "Persisted")],
                state: .final,
                source: CaptionTurnSource(providerID: "test")
            )
        ])

        try repository.saveCaptionDocument(document, for: record)
        let loaded = try repository.loadCaptionDocument(for: record)

        XCTAssertEqual(loaded.turns.map(\.text), ["Persisted"])
    }

    func testFileSummaryRepositoryReturnsNilWhenSummaryMissingAndLoadsWhenPresent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("summary-repositories-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let record = try store.createMeeting(name: "Meet", startedAt: Date()).record
        let repository = FileSummaryRepository()

        XCTAssertNil(try repository.loadSummary(for: record))

        let summary = MeetingSummary(
            overview: "Generated",
            keyTopics: [],
            decisions: [],
            actionItems: [],
            openQuestions: [],
            risks: [],
            followUps: [],
            language: "en-US",
            sourceSegmentIDs: ["turn-1"],
            generatedAt: Date(timeIntervalSince1970: 1),
            provider: "test",
            status: .succeeded,
            failureReason: nil
        )
        try repository.saveSummary(summary, for: record)

        XCTAssertEqual(try repository.loadSummary(for: record), summary)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(record.summaryMarkdownURL).path))
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run:

```sh
swift test --filter MeetingSessionStateTests
swift test --filter MeetingDataRepositoriesTests
```

Expected: compile failures because state and repository types do not exist.

- [ ] **Step 4: Implement memory state**

Create `Sources/MeetingAgentCore/MeetingSessionState.swift`:

```swift
import Foundation

public struct MeetingSessionState: Equatable {
    public let meetingID: UUID
    public var transcript: TranscriptState
    public var summary: SummaryState
}

public enum TranscriptStateSource: Equatable {
    case empty
    case activeRecording
    case hydratedFromPersistence
}

public struct TranscriptState: Equatable {
    public let meetingID: UUID
    public var captionDocument: CaptionDocument
    public var source: TranscriptStateSource

    public var consumptionView: TranscriptConsumptionView {
        TranscriptConsumptionView.project(meetingID: meetingID, document: captionDocument)
    }

    public var visibleTurns: [LiveCaptionTurn] {
        captionDocument.transcriptDocument.segments.map(LiveCaptionTurn.init(segment:))
    }

    public init(meetingID: UUID, captionDocument: CaptionDocument = CaptionDocument(), source: TranscriptStateSource = .empty) {
        self.meetingID = meetingID
        self.captionDocument = captionDocument
        self.source = source
    }
}

public enum SummaryStateStatus: Equatable {
    case missing
    case loaded
    case generating
    case generated
    case failed(String)
}

public enum SummaryStateSource: Equatable {
    case none
    case loadedFromPersistence
    case generatedInSession
}

public struct SummaryState: Equatable {
    public var summary: MeetingSummary?
    public var status: SummaryStateStatus
    public var source: SummaryStateSource

    public static var missing: SummaryState {
        SummaryState(summary: nil, status: .missing, source: .none)
    }

    public static func loaded(_ summary: MeetingSummary) -> SummaryState {
        SummaryState(summary: summary, status: .loaded, source: .loadedFromPersistence)
    }

    public static func generated(_ summary: MeetingSummary) -> SummaryState {
        SummaryState(summary: summary, status: .generated, source: .generatedInSession)
    }

    public static func failed(_ message: String) -> SummaryState {
        SummaryState(summary: nil, status: .failed(message), source: .none)
    }
}
```

- [ ] **Step 5: Implement repositories**

Create `Sources/MeetingAgentCore/MeetingDataRepositories.swift`:

```swift
import Foundation

public protocol TranscriptRepository {
    func loadCaptionDocument(for meeting: MeetingRecord) throws -> CaptionDocument
    func saveCaptionDocument(_ document: CaptionDocument, for meeting: MeetingRecord) throws
}

public protocol SummaryRepository {
    func loadSummary(for meeting: MeetingRecord) throws -> MeetingSummary?
    func saveSummary(_ summary: MeetingSummary, for meeting: MeetingRecord) throws
}

public struct FileTranscriptRepository: TranscriptRepository {
    public init() {}

    public func loadCaptionDocument(for meeting: MeetingRecord) throws -> CaptionDocument {
        guard let url = meeting.transcriptJSONURL else { return CaptionDocument() }
        return try MeetingTranscriptStore.readDocument(from: url)
    }

    public func saveCaptionDocument(_ document: CaptionDocument, for meeting: MeetingRecord) throws {
        guard let url = meeting.transcriptJSONURL else {
            throw ProbeError.invalidArguments("Meeting has no transcript JSON URL")
        }
        let data = try JSONEncoder.meetingAgent.encode(document)
        try data.write(to: url, options: .atomic)
    }
}

public struct FileSummaryRepository: SummaryRepository {
    public init() {}

    public func loadSummary(for meeting: MeetingRecord) throws -> MeetingSummary? {
        guard let url = meeting.summaryJSONURL,
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return try MeetingSummaryWriter.read(from: url)
    }

    public func saveSummary(_ summary: MeetingSummary, for meeting: MeetingRecord) throws {
        guard let jsonURL = meeting.summaryJSONURL,
              let markdownURL = meeting.summaryMarkdownURL
        else {
            throw ProbeError.invalidArguments("Meeting has no summary output URL")
        }
        try MeetingSummaryWriter.write(summary, jsonURL: jsonURL, markdownURL: markdownURL)
    }
}
```

- [ ] **Step 6: Run tests**

Run:

```sh
swift test --filter MeetingSessionStateTests
swift test --filter MeetingDataRepositoriesTests
```

Expected: all new tests pass.

- [ ] **Step 7: Commit**

```sh
git add Sources/MeetingAgentCore/MeetingSessionState.swift Sources/MeetingAgentCore/MeetingDataRepositories.swift Tests/MeetingAgentCoreTests/MeetingSessionStateTests.swift Tests/MeetingAgentCoreTests/MeetingDataRepositoriesTests.swift
git commit -m "Add meeting memory state repositories"
```

---

## Task 3: Move Summary Input To TranscriptConsumptionView

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingSummary.swift`
- Modify: `Sources/MeetingAgentCore/OpenRouterMeetingSummaryProvider.swift`
- Modify tests using `MeetingSummaryInput`: `Tests/MeetingAgentCoreTests/MeetingSummaryProviderTests.swift`, `Tests/MeetingAgentCoreTests/GoalOrientedSummaryTests.swift`, `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] **Step 1: Write summary prompt test**

Modify `Tests/MeetingAgentCoreTests/MeetingSummaryProviderTests.swift` to add a test near the OpenRouter provider tests:

```swift
func testOpenRouterSummaryPromptUsesConsumptionTurnsWithSourceEvidence() async throws {
    let client = CapturingOpenRouterChatClient(responseContent: """
    {
      "autoGeneratedTitle": "Launch Planning",
      "overview": "The team confirmed the launch owner.",
      "keyTopics": ["Launch"],
      "tags": [],
      "decisions": [],
      "actionItems": [],
      "openQuestions": [],
      "risks": [],
      "followUps": []
    }
    """)
    let provider = OpenRouterMeetingSummaryProvider(apiKey: "key", model: "model", client: client)
    let document = CaptionDocument(
        turns: [
            CaptionTurn(
                id: "turn-1",
                speakerID: "speaker-1",
                speakerLabel: "Allan",
                startTimeSeconds: 12,
                endTimeSeconds: 25,
                sections: [CaptionSection(id: "section-1", text: "We confirmed the launch owner.", utteranceIDs: ["utt-1"], startTimeSeconds: 12, endTimeSeconds: 25)],
                state: .final,
                source: CaptionTurnSource(providerID: "deepgram", utteranceIDs: ["utt-1"])
            )
        ],
        provider: CaptionProviderInfo(id: "deepgram", locale: "en-US")
    )

    _ = try await provider.generateSummary(input: MeetingSummaryInput(
        meetingName: "Meet",
        startedAt: Date(timeIntervalSince1970: 0),
        endedAt: Date(timeIntervalSince1970: 30),
        language: "en-US",
        targetLanguage: "en-US",
        meetingGoal: nil,
        transcript: TranscriptConsumptionView.project(meetingID: UUID(), document: document),
        generatedAt: Date(timeIntervalSince1970: 40)
    ))

    let prompt = try XCTUnwrap(client.requests.first?.messages.last?.content)
    XCTAssertTrue(prompt.contains("[00:00:12-00:00:25] Allan"))
    XCTAssertTrue(prompt.contains("We confirmed the launch owner."))
    XCTAssertTrue(prompt.contains("source: utt-1"))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter MeetingSummaryProviderTests/testOpenRouterSummaryPromptUsesConsumptionTurnsWithSourceEvidence
```

Expected: compile failure because `MeetingSummaryInput` still requires `segments`.

- [ ] **Step 3: Change MeetingSummaryInput**

Modify `Sources/MeetingAgentCore/MeetingSummary.swift`:

```swift
public struct MeetingSummaryInput: Equatable {
    public let meetingName: String
    public let startedAt: Date
    public let endedAt: Date?
    public let language: String?
    public let targetLanguage: String?
    public let meetingGoal: String?
    public let transcript: TranscriptConsumptionView
    public let generatedAt: Date

    public init(
        meetingName: String,
        startedAt: Date,
        endedAt: Date?,
        language: String?,
        targetLanguage: String? = nil,
        meetingGoal: String?,
        transcript: TranscriptConsumptionView,
        generatedAt: Date = Date()
    ) {
        self.meetingName = meetingName
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.language = language
        self.targetLanguage = targetLanguage
        self.meetingGoal = meetingGoal
        self.transcript = transcript
        self.generatedAt = generatedAt
    }
}
```

- [ ] **Step 4: Render prompt from turns**

Modify `Sources/MeetingAgentCore/OpenRouterMeetingSummaryProvider.swift`:

```swift
private static func prompt(for input: MeetingSummaryInput) -> String {
    var lines = [
        "Meeting name: \(input.meetingName)",
        "Transcript language: \(input.language ?? input.transcript.language ?? "unknown")",
        "Summary target language: \(input.targetLanguage ?? input.language ?? input.transcript.language ?? "unknown")",
        "Write every generated JSON string value in the summary target language."
    ]
    if let meetingGoal = input.meetingGoal?.trimmingCharacters(in: .whitespacesAndNewlines),
       !meetingGoal.isEmpty {
        lines.append("Meeting goal: \(meetingGoal)")
    }
    lines.append("")
    lines.append("Transcript turns:")
    lines.append(contentsOf: input.transcript.finalTurns.map(renderTurn))
    return lines.joined(separator: "\n")
}

private static func renderTurn(_ turn: TranscriptConsumptionTurn) -> String {
    let speaker = turn.speakerLabel ?? turn.speakerID ?? "Unknown speaker"
    let range = formattedRange(start: turn.startTimeSeconds, end: turn.endTimeSeconds)
    let source = turn.sourceIDs.isEmpty ? "none" : turn.sourceIDs.joined(separator: ", ")
    return "[\(range)] \(speaker)\n\(turn.text)\nsource: \(source)"
}

private static func formattedRange(start: Double?, end: Double?) -> String {
    "\(formatTimestamp(start))-\(formatTimestamp(end))"
}

private static func formatTimestamp(_ seconds: Double?) -> String {
    guard let seconds else { return "unknown" }
    let total = max(0, Int(seconds.rounded(.down)))
    return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
}
```

Also update `failedSummary(...)` source IDs:

```swift
let sourceSegmentIDs = input.transcript.finalTurns.flatMap(\.sourceIDs)
```

- [ ] **Step 5: Update other tests to build inputs through CaptionDocument**

Where tests currently pass `segments: [...]`, replace with:

```swift
let transcript = TranscriptConsumptionView.project(
    meetingID: UUID(),
    document: CaptionDocument(turns: [
        CaptionTurn(
            id: "segment-1",
            speakerID: "speaker-1",
            speakerLabel: "User A",
            sections: [CaptionSection(text: "The transcript text.", utteranceIDs: ["segment-1"])],
            state: .final,
            source: CaptionTurnSource(providerID: "test", utteranceIDs: ["segment-1"])
        )
    ])
)
```

Then pass `transcript: transcript`.

- [ ] **Step 6: Run summary tests**

Run:

```sh
swift test --filter MeetingSummaryProviderTests
swift test --filter GoalOrientedSummaryTests
```

Expected: all pass.

- [ ] **Step 7: Commit**

```sh
git add Sources/MeetingAgentCore/MeetingSummary.swift Sources/MeetingAgentCore/OpenRouterMeetingSummaryProvider.swift Tests/MeetingAgentCoreTests/MeetingSummaryProviderTests.swift Tests/MeetingAgentCoreTests/GoalOrientedSummaryTests.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift
git commit -m "Use transcript consumption view for summaries"
```

---

## Task 4: Hydrate Completed Meetings Into Memory In ViewModel

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Modify: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] **Step 1: Add ViewModel tests for completed meeting summary loading**

Add tests to `MeetingAgentViewModelTests.swift`:

```swift
func testSelectingCompletedMeetingLoadsSummaryFromPersistenceWithoutProviderCall() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(baseDirectory: root)
    let stored = try store.createMeeting(name: "Completed", startedAt: Date(timeIntervalSince1970: 0))
    let captionDocument = CaptionDocument(turns: [
        CaptionTurn(
            id: "turn-1",
            sections: [CaptionSection(text: "Transcript text", utteranceIDs: ["utt-1"])],
            state: .final,
            source: CaptionTurnSource(providerID: "test", utteranceIDs: ["utt-1"])
        )
    ])
    try FileTranscriptRepository().saveCaptionDocument(captionDocument, for: stored.record)
    let summary = MeetingSummary(
        overview: "Persisted summary",
        keyTopics: [],
        decisions: [],
        actionItems: [],
        openQuestions: [],
        risks: [],
        followUps: [],
        language: "en-US",
        sourceSegmentIDs: ["utt-1"],
        generatedAt: Date(timeIntervalSince1970: 10),
        provider: "persisted",
        status: .succeeded,
        failureReason: nil
    )
    try FileSummaryRepository().saveSummary(summary, for: stored.record)
    let provider = CapturingSummaryProvider(providerName: "should-not-run")
    let viewModel = MeetingAgentViewModel(store: store, summaryProviderFactory: { _ in provider })

    try viewModel.loadMeetings()
    viewModel.selectMeeting(stored.record.id)
    await viewModel.waitForLiveCaptionReplayForTesting()

    XCTAssertEqual(viewModel.selectedMeetingSummary?.overview, "Persisted summary")
    XCTAssertEqual(provider.requests.count, 0)
    XCTAssertEqual(viewModel.liveCaptionTurns.map(\.originalText), ["Transcript text"])
}

func testSelectingCompletedMeetingWithoutSummaryGeneratesFromHydratedMemoryTranscript() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(baseDirectory: root)
    let stored = try store.createMeeting(name: "Completed", startedAt: Date(timeIntervalSince1970: 0))
    let captionDocument = CaptionDocument(turns: [
        CaptionTurn(
            id: "turn-1",
            speakerLabel: "Allan",
            sections: [CaptionSection(text: "We confirmed the owner.", utteranceIDs: ["utt-1"])],
            state: .final,
            source: CaptionTurnSource(providerID: "test", utteranceIDs: ["utt-1"])
        )
    ])
    try FileTranscriptRepository().saveCaptionDocument(captionDocument, for: stored.record)
    let provider = CapturingSummaryProvider(providerName: "summary-provider")
    let viewModel = MeetingAgentViewModel(store: store, summaryProviderFactory: { _ in provider })

    try viewModel.loadMeetings()
    viewModel.selectMeeting(stored.record.id)
    await viewModel.waitForLiveCaptionReplayForTesting()
    try await viewModel.waitForSummaryIdleForTesting()

    XCTAssertEqual(provider.requests.count, 1)
    XCTAssertEqual(provider.requests.first?.transcript.finalTurns.first?.text, "We confirmed the owner.")
    XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(stored.record.summaryJSONURL).path))
}
```

Update `CapturingSummaryProvider` in the test file so it stores `[MeetingSummaryInput]`:

```swift
private final class CapturingSummaryProvider: MeetingSummaryProvider {
    let providerName: String
    private(set) var requests: [MeetingSummaryInput] = []

    init(providerName: String = "capturing-summary") {
        self.providerName = providerName
    }

    func generateSummary(input: MeetingSummaryInput) async throws -> MeetingSummary {
        requests.append(input)
        return MeetingSummary(
            overview: input.transcript.finalTurns.map(\.text).joined(separator: " "),
            keyTopics: [],
            decisions: [],
            actionItems: [],
            openQuestions: [],
            risks: [],
            followUps: [],
            language: input.targetLanguage ?? input.language,
            sourceSegmentIDs: input.transcript.finalTurns.flatMap(\.sourceIDs),
            generatedAt: input.generatedAt,
            provider: providerName,
            status: .succeeded,
            failureReason: nil
        )
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```sh
swift test --filter MeetingAgentViewModelTests/testSelectingCompletedMeetingLoadsSummaryFromPersistenceWithoutProviderCall
swift test --filter MeetingAgentViewModelTests/testSelectingCompletedMeetingWithoutSummaryGeneratesFromHydratedMemoryTranscript
```

Expected: compile failure for missing `selectedMeetingSummary` and `waitForSummaryIdleForTesting`, or behavioral failure because selection still reads files through old artifact snapshot paths.

- [ ] **Step 3: Add repository dependencies and session state to ViewModel**

Modify `MeetingAgentViewModel` stored properties:

```swift
private let transcriptRepository: TranscriptRepository
private let summaryRepository: SummaryRepository
@Published public private(set) var selectedMeetingSessionState: MeetingSessionState?

public var selectedMeetingSummary: MeetingSummary? {
    selectedMeetingSessionState?.summary.summary
}
```

Extend initializer:

```swift
transcriptRepository: TranscriptRepository = FileTranscriptRepository(),
summaryRepository: SummaryRepository = FileSummaryRepository(),
```

Assign them in init:

```swift
self.transcriptRepository = transcriptRepository
self.summaryRepository = summaryRepository
```

- [ ] **Step 4: Implement completed meeting hydration**

Add a private method:

```swift
private func hydrateCompletedMeetingSession(for meeting: MeetingRecord) {
    do {
        let document = try transcriptRepository.loadCaptionDocument(for: meeting)
        let transcriptState = TranscriptState(
            meetingID: meeting.id,
            captionDocument: document,
            source: .hydratedFromPersistence
        )
        if let summary = try summaryRepository.loadSummary(for: meeting) {
            selectedMeetingSessionState = MeetingSessionState(
                meetingID: meeting.id,
                transcript: transcriptState,
                summary: .loaded(summary)
            )
            return
        }
        selectedMeetingSessionState = MeetingSessionState(
            meetingID: meeting.id,
            transcript: transcriptState,
            summary: .missing
        )
        Task { [weak self] in
            try? await self?.generateMissingSummaryFromSelectedSession(for: meeting.id)
        }
    } catch {
        selectedMeetingSessionState = MeetingSessionState(
            meetingID: meeting.id,
            transcript: TranscriptState(meetingID: meeting.id, source: .empty),
            summary: .failed(String(describing: error))
        )
    }
}
```

In `selectMeeting(...)`, after setting selected meeting, call this for non-recording/completed meetings instead of making file reads available to artifact consumers.

- [ ] **Step 5: Generate missing summary from memory**

Add:

```swift
private func generateMissingSummaryFromSelectedSession(for meetingID: UUID, generatedAt: Date = Date()) async throws {
    guard var session = selectedMeetingSessionState,
          session.meetingID == meetingID,
          session.summary.summary == nil,
          let meeting = meetings.first(where: { $0.id == meetingID })
    else { return }
    guard !session.transcript.consumptionView.finalTurns.isEmpty else {
        selectedMeetingSessionState?.summary = .failed("Transcript has no final caption turns")
        return
    }
    selectedMeetingSessionState?.summary.status = .generating
    let provider = summaryProviderFactory(speechConfiguration)
    let progress = progressState(for: meeting)
    let summary = try await provider.generateSummary(input: MeetingSummaryInput(
        meetingName: meeting.name,
        startedAt: meeting.startedAt,
        endedAt: meeting.endedAt,
        language: speechLocaleIdentifier,
        targetLanguage: speechConfiguration.localeIdentifier,
        meetingGoal: summaryGoalContext(for: progress),
        transcript: session.transcript.consumptionView,
        generatedAt: generatedAt
    ))
    try summaryRepository.saveSummary(summary, for: meeting)
    session.summary = .generated(summary)
    selectedMeetingSessionState = session
}
```

- [ ] **Step 6: Update public generateSummary to use memory**

Change `generateSummary(for:)` so it never reads `meeting.transcriptJSONURL`. It should:

1. Ensure a session is hydrated for `meetingID`.
2. Use `selectedMeetingSessionState?.transcript.consumptionView` if selected, or hydrate an ephemeral `TranscriptState` through `transcriptRepository`.
3. Persist through `summaryRepository`.

Use this shape:

```swift
let transcriptView: TranscriptConsumptionView
if selectedMeetingSessionState?.meetingID == meetingID {
    transcriptView = selectedMeetingSessionState!.transcript.consumptionView
} else {
    let document = try transcriptRepository.loadCaptionDocument(for: meeting)
    transcriptView = TranscriptConsumptionView.project(meetingID: meetingID, document: document)
}
```

Then pass `transcript: transcriptView`.

- [ ] **Step 7: Add testing hook**

Add under existing testing helpers:

```swift
public func waitForSummaryIdleForTesting() async {
    while selectedMeetingSessionState?.summary.status == .generating {
        await Task.yield()
    }
}
```

- [ ] **Step 8: Run ViewModel tests**

Run:

```sh
swift test --filter MeetingAgentViewModelTests/testSelectingCompletedMeetingLoadsSummaryFromPersistenceWithoutProviderCall
swift test --filter MeetingAgentViewModelTests/testSelectingCompletedMeetingWithoutSummaryGeneratesFromHydratedMemoryTranscript
swift test --filter MeetingAgentViewModelTests/testGenerateSummaryWritesArtifacts
```

Expected: all pass.

- [ ] **Step 9: Commit**

```sh
git add Sources/MeetingAgentCore/MeetingAgentViewModel.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift
git commit -m "Hydrate completed meetings into memory"
```

---

## Task 5: Move Artifact Snapshot And UI Detail Data To Memory State

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingArtifactSnapshot.swift`
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`
- Test: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

- [ ] **Step 1: Write artifact snapshot memory test**

Add to `MeetingAgentViewModelTests.swift`:

```swift
func testArtifactSnapshotUsesSelectedSessionStateInsteadOfReadingFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(baseDirectory: root)
    let stored = try store.createMeeting(name: "Completed", startedAt: Date(timeIntervalSince1970: 0))
    try FileTranscriptRepository().saveCaptionDocument(CaptionDocument(turns: [
        CaptionTurn(
            id: "turn-1",
            sections: [CaptionSection(text: "Memory transcript", utteranceIDs: ["utt-1"])],
            state: .final,
            source: CaptionTurnSource(providerID: "test", utteranceIDs: ["utt-1"])
        )
    ]), for: stored.record)
    let summary = MeetingSummary(
        overview: "Memory summary",
        keyTopics: [],
        decisions: [],
        actionItems: [],
        openQuestions: [],
        risks: [],
        followUps: [],
        language: "en-US",
        sourceSegmentIDs: ["utt-1"],
        generatedAt: Date(timeIntervalSince1970: 10),
        provider: "test",
        status: .succeeded,
        failureReason: nil
    )
    try FileSummaryRepository().saveSummary(summary, for: stored.record)
    let viewModel = MeetingAgentViewModel(store: store)

    try viewModel.loadMeetings()
    viewModel.selectMeeting(stored.record.id)
    await viewModel.waitForLiveCaptionReplayForTesting()
    try FileManager.default.removeItem(at: XCTUnwrap(stored.record.transcriptJSONURL))
    try FileManager.default.removeItem(at: XCTUnwrap(stored.record.summaryJSONURL))
    viewModel.refreshSelectedMeetingArtifactSnapshot()

    XCTAssertEqual(viewModel.selectedMeetingArtifactSnapshot?.transcriptText, "User A:\nMemory transcript")
    XCTAssertEqual(viewModel.selectedMeetingArtifactSnapshot?.summary?.overview, "Memory summary")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter MeetingAgentViewModelTests/testArtifactSnapshotUsesSelectedSessionStateInsteadOfReadingFiles
```

Expected: failure because artifact snapshot currently reads files.

- [ ] **Step 3: Replace MeetingArtifactSnapshot loader**

Change `MeetingArtifactSnapshot` to expose a memory-backed factory:

```swift
public static func make(
    meeting: MeetingRecord,
    session: MeetingSessionState?
) -> MeetingArtifactSnapshot {
    let turns = session?.transcript.visibleTurns ?? []
    let transcriptText = TranscriptFormatter.render(
        session?.transcript.captionDocument.transcriptDocument.segments ?? []
    )
    return MeetingArtifactSnapshot(
        transcriptText: transcriptText,
        summary: session?.summary.summary,
        transcriptSegments: session?.transcript.captionDocument.transcriptDocument.segments ?? [],
        actualTranscriptionSourceText: meeting.transcriptionProviderID,
        transcriptLatencyText: "unavailable"
    )
}
```

Keep old file-backed `load(...)` only if tests or legacy utilities need it; mark it internal and do not call it from ViewModel.

- [ ] **Step 4: Update ViewModel snapshot refresh**

In `MeetingAgentViewModel.refreshSelectedMeetingArtifactSnapshot()`, replace file-backed load with:

```swift
selectedMeetingArtifactSnapshot = selectedMeeting.map {
    MeetingArtifactSnapshot.make(meeting: $0, session: selectedMeetingSessionState)
}
```

- [ ] **Step 5: Run layout guard**

Run:

```sh
swift test --filter MainWindowViewLayoutTests
swift test --filter MeetingAgentViewModelTests/testArtifactSnapshotUsesSelectedSessionStateInsteadOfReadingFiles
```

Expected: pass. Existing layout test should still confirm the SwiftUI view does not directly read files.

- [ ] **Step 6: Commit**

```sh
git add Sources/MeetingAgentCore/MeetingArtifactSnapshot.swift Sources/MeetingAgentCore/MeetingAgentViewModel.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift
git commit -m "Use memory state for artifact snapshots"
```

---

## Task 6: Move Export And Knowledge Inputs To Memory Read Models

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingExportService.swift`
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingExportServiceTests.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] **Step 1: Write export test that survives transcript file deletion after hydration**

Add to `MeetingAgentViewModelTests.swift`:

```swift
func testExportUsesHydratedMemoryTranscriptWhenTranscriptFileIsGone() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(baseDirectory: root)
    let stored = try store.createMeeting(name: "Completed", startedAt: Date(timeIntervalSince1970: 0))
    try FileTranscriptRepository().saveCaptionDocument(CaptionDocument(turns: [
        CaptionTurn(
            id: "turn-1",
            sections: [CaptionSection(text: "Export from memory", utteranceIDs: ["utt-1"])],
            state: .final,
            source: CaptionTurnSource(providerID: "test", utteranceIDs: ["utt-1"])
        )
    ]), for: stored.record)
    let viewModel = MeetingAgentViewModel(store: store)

    try viewModel.loadMeetings()
    viewModel.selectMeeting(stored.record.id)
    await viewModel.waitForLiveCaptionReplayForTesting()
    try FileManager.default.removeItem(at: XCTUnwrap(stored.record.transcriptJSONURL))

    let exportURL = try viewModel.exportSelectedMeetingTranscriptAsMarkdown()
    let exported = try String(contentsOf: exportURL, encoding: .utf8)

    XCTAssertTrue(exported.contains("Export from memory"))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter MeetingAgentViewModelTests/testExportUsesHydratedMemoryTranscriptWhenTranscriptFileIsGone
```

Expected: failure because export currently checks/reads `record.transcriptJSONURL`.

- [ ] **Step 3: Add memory-backed export methods**

Modify `MeetingExportService` to add overloads that accept memory input:

```swift
public func exportTranscriptMarkdown(
    record: MeetingRecord,
    transcript: TranscriptConsumptionView,
    to destinationURL: URL
) throws -> URL {
    let body = transcript.finalTurns.map { turn in
        let speaker = turn.speakerLabel ?? turn.speakerID ?? "Unknown speaker"
        return "\(speaker):\n\(turn.text)"
    }.joined(separator: "\n\n")
    try body.write(to: destinationURL, atomically: true, encoding: .utf8)
    return destinationURL
}
```

Keep existing file-backed methods for legacy tests, but product ViewModel should call the memory overload.

- [ ] **Step 4: Update ViewModel export actions**

Where ViewModel exports selected transcript, resolve:

```swift
guard let session = selectedMeetingSessionState else {
    throw MeetingExportError.missingArtifact("in-memory transcript")
}
return try exportService.exportTranscriptMarkdown(
    record: selectedMeeting,
    transcript: session.transcript.consumptionView,
    to: destinationURL
)
```

Apply the same principle for knowledge package inputs: pass memory `TranscriptConsumptionView` and memory `MeetingSummary?`; only output files are written by export.

- [ ] **Step 5: Run export tests**

Run:

```sh
swift test --filter MeetingExportServiceTests
swift test --filter MeetingAgentViewModelTests/testExportUsesHydratedMemoryTranscriptWhenTranscriptFileIsGone
```

Expected: pass.

- [ ] **Step 6: Commit**

```sh
git add Sources/MeetingAgentCore/MeetingExportService.swift Sources/MeetingAgentCore/MeetingAgentViewModel.swift Tests/MeetingAgentCoreTests/MeetingExportServiceTests.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift
git commit -m "Export from memory transcript state"
```

---

## Task 7: Update Active Recording Stop To Persist From Memory

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingRecorderTests.swift`

- [ ] **Step 1: Write active stop memory summary test**

Add to `MeetingAgentViewModelTests.swift`:

```swift
func testStopRecordingGeneratesSummaryFromLiveMemoryTranscript() async throws {
    let fixture = try ViewModelRecorderFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
    let provider = CapturingSummaryProvider(providerName: "summary-provider")
    let viewModel = MeetingAgentViewModel(
        store: fixture.store,
        recorder: fixture.recorder,
        summaryProviderFactory: { _ in provider },
        processTargetsProvider: { [target] }
    )

    try await viewModel.startRecording(for: target)
    fixture.transcriber.emitSpeechEvent(.final(SpeechUtterancePayload(
        providerID: "deepgram-transcribe",
        providerResultID: "result-1",
        providerUtteranceID: "utt-1",
        speaker: TranscriptSpeaker(identifier: "speaker-1", label: "Allan"),
        startTimeSeconds: 1,
        endTimeSeconds: 4,
        text: "We confirmed the owner.",
        language: "en-US",
        confidence: 0.9,
        boundary: SpeechBoundary(speechFinal: true)
    )))
    viewModel.drainRecordingFrames()
    try await waitFor { viewModel.liveCaptionTurns.first?.isFinal == true }

    viewModel.stopRecording(at: Date(timeIntervalSince1970: 10))
    try await viewModel.waitForSummaryIdleForTesting()

    XCTAssertEqual(provider.requests.first?.transcript.finalTurns.first?.text, "We confirmed the owner.")
    let record = try XCTUnwrap(viewModel.meetings.first)
    XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(record.summaryJSONURL).path))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter MeetingAgentViewModelTests/testStopRecordingGeneratesSummaryFromLiveMemoryTranscript
```

Expected: failure until stop flow updates `MeetingSessionState` before summary generation.

- [ ] **Step 3: Update live caption publication to keep TranscriptState current**

In `publishRealtimeCaptionPipelineSnapshot(...)` or the place where live caption turns are assigned, update selected active session:

```swift
private func updateActiveTranscriptState(from snapshot: LiveCaptionPipelineSnapshot) {
    guard let meetingID = activeMeetingID else { return }
    let document = CaptionDocument(
        turns: snapshot.turns.map { $0.captionTurn },
        provider: CaptionProviderInfo(id: speechConfiguration.hostedTranscriptionProviderID ?? speechConfiguration.provider.rawValue, locale: speechConfiguration.localeIdentifier)
    )
    selectedMeetingSessionState = MeetingSessionState(
        meetingID: meetingID,
        transcript: TranscriptState(meetingID: meetingID, captionDocument: document, source: .activeRecording),
        summary: selectedMeetingSessionState?.meetingID == meetingID ? selectedMeetingSessionState!.summary : .missing
    )
}
```

If `LiveCaptionTurn` does not expose `captionTurn`, add a focused converter in `TranscriptState` or `LiveMeetingCockpit.swift`. The converter must preserve speaker ID/label, text sections, final state, timing, and source segment IDs.

- [ ] **Step 4: Stop flow persists memory and generates summary from memory**

After `flushLiveCaptionPipeline(reason: .manualStop)` during stop:

```swift
if let session = selectedMeetingSessionState,
   session.meetingID == stoppedID,
   let meeting = meetings.first(where: { $0.id == stoppedID }) {
    try? transcriptRepository.saveCaptionDocument(session.transcript.captionDocument, for: meeting)
}
try await generateSummary(for: stoppedID, generatedAt: generatedAt)
```

`generateSummary` must use the selected session transcript from Task 4.

- [ ] **Step 5: Run active tests**

Run:

```sh
swift test --filter MeetingAgentViewModelTests/testStopRecordingGeneratesSummaryFromLiveMemoryTranscript
swift test --filter MeetingRecorderTests/testRecorderStopPreservesSpeechEventCaptionDocument
```

Expected: pass.

- [ ] **Step 6: Commit**

```sh
git add Sources/MeetingAgentCore/MeetingAgentViewModel.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift Tests/MeetingAgentCoreTests/MeetingRecorderTests.swift
git commit -m "Generate summaries from live memory transcript"
```

---

## Task 8: Remove Product-Level Direct Transcript File Reads

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Modify: `Sources/MeetingAgentCore/MeetingArtifactSnapshot.swift`
- Modify: `Sources/MeetingAgentCore/MeetingExportService.swift`
- Modify: `AGENTS.md`
- Test: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`
- Test: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

- [ ] **Step 1: Add search guard tests**

Add to `MainWindowViewLayoutTests.swift` or a new architecture guard test:

```swift
func testProductConsumersDoNotReadTranscriptFilesDirectly() throws {
    let viewModel = try String(contentsOfFile: "Sources/MeetingAgentCore/MeetingAgentViewModel.swift")
    let artifactSnapshot = try String(contentsOfFile: "Sources/MeetingAgentCore/MeetingArtifactSnapshot.swift")
    let exportService = try String(contentsOfFile: "Sources/MeetingAgentCore/MeetingExportService.swift")

    XCTAssertFalse(viewModel.contains("TranscriptFileWriter.readDocument"))
    XCTAssertFalse(viewModel.contains("MeetingSummaryWriter.read"))
    XCTAssertFalse(artifactSnapshot.contains("TranscriptFileWriter.readDocument"))
    XCTAssertFalse(artifactSnapshot.contains("MeetingSummaryWriter.read"))
    XCTAssertFalse(exportService.contains("TranscriptFileWriter.readDocument(from:"))
}
```

- [ ] **Step 2: Run guard to verify it fails**

Run:

```sh
swift test --filter MainWindowViewLayoutTests/testProductConsumersDoNotReadTranscriptFilesDirectly
```

Expected: failure if any product-level direct read remains.

- [ ] **Step 3: Replace remaining direct reads**

Use `rg` to identify remaining product-level reads:

```sh
rg -n "TranscriptFileWriter\\.readDocument|MeetingSummaryWriter\\.read|transcriptJSONURL" Sources/MeetingAgentCore/MeetingAgentViewModel.swift Sources/MeetingAgentCore/MeetingArtifactSnapshot.swift Sources/MeetingAgentCore/MeetingExportService.swift
```

Allowed uses after cleanup:

- repositories in `MeetingDataRepositories.swift`;
- low-level legacy utilities;
- tests and fixtures;
- path availability checks for UI button enabling, if they do not read data.

Move any remaining data read into repositories or memory state.

- [ ] **Step 4: Update AGENTS.md with new rule**

Add under Realtime Caption Architecture:

```markdown
- Product consumers must read transcript and summary data from `MeetingSessionState` or a derived read model. Files are repository-owned hydrate/backup assets; summary, progress, export, and UI detail surfaces must not directly read `transcript.json` or `summary.json`.
```

- [ ] **Step 5: Run architecture guard and focused suites**

Run:

```sh
swift test --filter MainWindowViewLayoutTests/testProductConsumersDoNotReadTranscriptFilesDirectly
swift test --filter MeetingAgentViewModelTests
swift test --filter MeetingExportServiceTests
```

Expected: pass.

- [ ] **Step 6: Commit**

```sh
git add Sources/MeetingAgentCore/MeetingAgentViewModel.swift Sources/MeetingAgentCore/MeetingArtifactSnapshot.swift Sources/MeetingAgentCore/MeetingExportService.swift Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift AGENTS.md
git commit -m "Remove direct transcript file consumption"
```

---

## Task 9: Full Verification And Final Cleanup

**Files:**
- Potentially modify tests/docs only if verification exposes misses.

- [ ] **Step 1: Run product-path search**

Run:

```sh
rg -n "TranscriptFileWriter\\.readDocument|MeetingSummaryWriter\\.read|transcriptJSONURL" Sources/MeetingAgentCore/MeetingAgentViewModel.swift Sources/MeetingAgentCore/MeetingArtifactSnapshot.swift Sources/MeetingAgentCore/MeetingExportService.swift Sources/MeetingAgentApp
```

Expected:

- no direct transcript/summary file data reads in ViewModel, artifact snapshot, export, or app UI;
- any `transcriptJSONURL` occurrences are only availability/path metadata checks, not data consumption.

- [ ] **Step 2: Run full test suite**

Run:

```sh
make test
```

Expected:

- all tests pass;
- coverage gate passes.

- [ ] **Step 3: Inspect git status and diff**

Run:

```sh
git status --short
git diff --stat
```

Expected:

- only intended source/test/doc files modified;
- `.env` remains untracked and untouched.

- [ ] **Step 4: Commit final cleanup if needed**

If Task 9 required code or doc fixes:

```sh
git add <changed-files>
git commit -m "Verify memory transcript consumption"
```

If no files changed, do not create an empty commit.

---

## Self-Review Checklist

- Spec coverage: Tasks cover memory state, repositories, `TranscriptConsumptionView`, summary load/generate behavior, active stop, artifact snapshots, export, direct-read cleanup, and verification.
- Placeholder scan: No `TBD`, `TODO`, or "implement later" instructions remain.
- Type consistency: `TranscriptConsumptionView`, `MeetingSessionState`, `TranscriptState`, `SummaryState`, `TranscriptRepository`, and `SummaryRepository` are introduced before later tasks use them.
- Scope check: Plan is large but cohesive. It is one refactor around a single boundary: memory-backed transcript/summary consumption.
