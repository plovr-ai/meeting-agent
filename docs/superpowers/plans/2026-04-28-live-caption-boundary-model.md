# Live Caption Boundary Model Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split live caption display sealing from translation finality so same-speaker captions stay readable without forcing premature final translations.

**Architecture:** Add explicit display and translation state to `LiveCaptionTurn`, keep legacy `chunkState` compatibility, and make `LiveCaptionChunker` emit hard versus soft boundary metadata. Then update translation scheduling to treat soft blocks as draft translation candidates and hard boundaries as final translation candidates, while SwiftUI renders same-speaker blocks under a single speaker label.

**Tech Stack:** Swift 5.9, Swift Package Manager, XCTest, SwiftUI.

---

## File Structure

- Modify `Sources/MeetingAgentCore/LiveMeetingCockpit.swift`
  - Add `LiveCaptionDisplayBlockState`, `LiveCaptionTranslationState`, and `LiveCaptionBoundaryStrength`.
  - Extend `LiveCaptionTurn` with display/translation/boundary fields and legacy decoding.
  - Add speaker grouping helpers for UI rendering.
  - Keep old `chunkState` available as a compatibility alias during migration.
- Modify `Sources/MeetingAgentCore/LiveCaptionChunker.swift`
  - Mark `speechFinal`, `speakerChanged`, and `manualStop` as hard boundaries.
  - Mark `punctuation`, `maxDuration`, and `maxLength` as soft boundaries.
  - Return sealed blocks with `translationState` based on boundary strength.
- Modify `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
  - Schedule draft translation for draft/soft-sealed blocks.
  - Schedule final translation for hard-sealed blocks.
  - Prevent stale draft responses from overwriting newer draft or final responses.
- Modify `Sources/MeetingAgentApp/MainWindowView.swift`
  - Render speaker groups instead of one speaker label per caption block.
  - Keep edit actions available for the group label and individual block text.
- Modify tests in `Tests/MeetingAgentCoreTests/`
  - Add focused XCTest coverage in `LiveCaptionStoreTests`, `LiveCaptionChunkerTests`, `MeetingAgentViewModelTests`, and `MainWindowViewLayoutTests`.

---

### Task 1: Add Explicit Caption Boundary States

**Files:**
- Modify: `Sources/MeetingAgentCore/LiveMeetingCockpit.swift`
- Test: `Tests/MeetingAgentCoreTests/LiveCaptionStoreTests.swift`

- [ ] **Step 1: Write the failing legacy/default state tests**

Add these tests to `LiveCaptionStoreTests`:

```swift
func testLiveCaptionTurnDefaultsDisplayAndTranslationStateFromLegacyChunkState() throws {
    let data = Data("""
    {
      "id": "segment-1",
      "sourceSegmentID": "segment-1",
      "sourceSegmentIDs": ["segment-1"],
      "speaker": {},
      "originalText": "hello",
      "sourceLocale": "en-US",
      "targetLocale": "zh-CN",
      "isFinal": true,
      "captionHealth": { "state": "live" },
      "translationHealth": { "state": "pending" },
      "createdAt": "2026-04-28T00:00:00Z",
      "chunkState": "frozen",
      "freezeReason": "punctuation"
    }
    """.utf8)

    let turn = try JSONDecoder.meetingAgent.decode(LiveCaptionTurn.self, from: data)

    XCTAssertEqual(turn.displayState, .sealed)
    XCTAssertEqual(turn.translationState, .draft)
    XCTAssertEqual(turn.boundaryReason, .punctuation)
    XCTAssertEqual(turn.boundaryStrength, .soft)
    XCTAssertEqual(turn.chunkState, .frozen)
}

func testHardBoundaryDefaultsTranslationStateToFinal() {
    let turn = LiveCaptionTurn(
        sourceSegmentID: "segment-1",
        originalText: "done",
        isFinal: true,
        displayState: .sealed,
        translationState: .final,
        boundaryReason: .speechFinal,
        boundaryStrength: .hard
    )

    XCTAssertEqual(turn.displayState, .sealed)
    XCTAssertEqual(turn.translationState, .final)
    XCTAssertEqual(turn.boundaryReason, .speechFinal)
    XCTAssertEqual(turn.boundaryStrength, .hard)
    XCTAssertEqual(turn.chunkState, .frozen)
}
```

- [ ] **Step 2: Run the tests and verify they fail**

Run:

```bash
swift test --filter LiveCaptionStoreTests/testLiveCaptionTurnDefaultsDisplayAndTranslationStateFromLegacyChunkState
swift test --filter LiveCaptionStoreTests/testHardBoundaryDefaultsTranslationStateToFinal
```

Expected: compile failure because `displayState`, `translationState`, `boundaryReason`, and `boundaryStrength` do not exist.

- [ ] **Step 3: Add the new enums and compatibility helpers**

In `LiveMeetingCockpit.swift`, add these enums near the existing live caption state enums:

```swift
public enum LiveCaptionDisplayBlockState: String, Codable, Equatable {
    case draft
    case sealed
}

public enum LiveCaptionTranslationState: String, Codable, Equatable {
    case draft
    case pendingFinal
    case final
}

public enum LiveCaptionBoundaryStrength: String, Codable, Equatable {
    case soft
    case hard
}
```

Add this computed property to `LiveCaptionFreezeReason`:

```swift
public var boundaryStrength: LiveCaptionBoundaryStrength {
    switch self {
    case .speechFinal, .speakerChanged, .manualStop:
        return .hard
    case .maxLength, .maxDuration, .punctuation:
        return .soft
    }
}
```

- [ ] **Step 4: Extend `LiveCaptionTurn`**

Add fields to `LiveCaptionTurn`:

```swift
public var displayState: LiveCaptionDisplayBlockState
public var translationState: LiveCaptionTranslationState
public var boundaryReason: LiveCaptionFreezeReason?
public var boundaryStrength: LiveCaptionBoundaryStrength?
```

Update the initializer signature after `freezeReason`:

```swift
displayState: LiveCaptionDisplayBlockState? = nil,
translationState: LiveCaptionTranslationState? = nil,
boundaryReason: LiveCaptionFreezeReason? = nil,
boundaryStrength: LiveCaptionBoundaryStrength? = nil
```

Inside the initializer, assign:

```swift
let resolvedDisplayState = displayState ?? (chunkState == .draft ? .draft : .sealed)
let resolvedBoundaryReason = boundaryReason ?? freezeReason
let resolvedBoundaryStrength = boundaryStrength ?? resolvedBoundaryReason?.boundaryStrength
self.displayState = resolvedDisplayState
self.translationState = translationState ?? {
    if resolvedDisplayState == .draft {
        return .draft
    }
    return resolvedBoundaryStrength == .hard ? .final : .draft
}()
self.boundaryReason = resolvedBoundaryReason
self.boundaryStrength = resolvedBoundaryStrength
```

Keep assigning `chunkState` and `freezeReason` so existing call sites continue compiling.

- [ ] **Step 5: Update Codable keys and decoding**

Add cases to `CodingKeys`:

```swift
case displayState
case translationState
case boundaryReason
case boundaryStrength
```

In `init(from:)`, decode new fields after `freezeReason`:

```swift
let decodedDisplayState = try container.decodeIfPresent(LiveCaptionDisplayBlockState.self, forKey: .displayState)
let decodedTranslationState = try container.decodeIfPresent(LiveCaptionTranslationState.self, forKey: .translationState)
let decodedBoundaryReason = try container.decodeIfPresent(LiveCaptionFreezeReason.self, forKey: .boundaryReason) ?? freezeReason
let decodedBoundaryStrength = try container.decodeIfPresent(LiveCaptionBoundaryStrength.self, forKey: .boundaryStrength) ?? decodedBoundaryReason?.boundaryStrength
displayState = decodedDisplayState ?? (chunkState == .draft ? .draft : .sealed)
translationState = decodedTranslationState ?? {
    if displayState == .draft {
        return .draft
    }
    return decodedBoundaryStrength == .hard ? .final : .draft
}()
boundaryReason = decodedBoundaryReason
boundaryStrength = decodedBoundaryStrength
```

- [ ] **Step 6: Run the state tests and commit**

Run:

```bash
swift test --filter LiveCaptionStoreTests/testLiveCaptionTurnDefaultsDisplayAndTranslationStateFromLegacyChunkState
swift test --filter LiveCaptionStoreTests/testHardBoundaryDefaultsTranslationStateToFinal
```

Expected: both pass.

Commit:

```bash
git add Sources/MeetingAgentCore/LiveMeetingCockpit.swift Tests/MeetingAgentCoreTests/LiveCaptionStoreTests.swift
git commit -m "feat: add live caption boundary states"
```

---

### Task 2: Emit Soft and Hard Boundaries from the Chunker

**Files:**
- Modify: `Sources/MeetingAgentCore/LiveCaptionChunker.swift`
- Test: `Tests/MeetingAgentCoreTests/LiveCaptionChunkerTests.swift`

- [ ] **Step 1: Write failing chunker tests**

Add these tests to `LiveCaptionChunkerTests`:

```swift
func testSoftPunctuationBoundarySealsDisplayButKeepsDraftTranslation() {
    var chunker = LiveCaptionChunker(
        sourceLocale: "en-US",
        targetLocale: "zh-CN",
        policy: LiveCaptionChunkingPolicy(minPunctuationCharacters: 10)
    )

    let updates = chunker.append(segment(id: "s1", text: "That sounds good."))

    XCTAssertEqual(updates.last?.turn.displayState, .sealed)
    XCTAssertEqual(updates.last?.turn.translationState, .draft)
    XCTAssertEqual(updates.last?.turn.boundaryReason, .punctuation)
    XCTAssertEqual(updates.last?.turn.boundaryStrength, .soft)
}

func testSpeechFinalBoundarySealsDisplayAndFinalizesTranslation() {
    var chunker = LiveCaptionChunker(sourceLocale: "en-US", targetLocale: "zh-CN")

    let updates = chunker.append(segment(id: "s1", text: "Done.", speechFinal: true))

    XCTAssertEqual(updates.last?.turn.displayState, .sealed)
    XCTAssertEqual(updates.last?.turn.translationState, .final)
    XCTAssertEqual(updates.last?.turn.boundaryReason, .speechFinal)
    XCTAssertEqual(updates.last?.turn.boundaryStrength, .hard)
}

func testSpeakerChangeBoundaryFinalizesPreviousSpeakerTranslation() {
    var chunker = LiveCaptionChunker(sourceLocale: "en-US", targetLocale: "zh-CN")
    _ = chunker.append(segment(id: "a1", speaker: "a", text: "First thought"))

    let updates = chunker.append(segment(id: "b1", speaker: "b", text: "Second thought"))

    XCTAssertEqual(updates.first?.turn.displayState, .sealed)
    XCTAssertEqual(updates.first?.turn.translationState, .final)
    XCTAssertEqual(updates.first?.turn.boundaryReason, .speakerChanged)
    XCTAssertEqual(updates.first?.turn.boundaryStrength, .hard)
    XCTAssertEqual(updates.last?.turn.displayState, .draft)
    XCTAssertEqual(updates.last?.turn.translationState, .draft)
}
```

- [ ] **Step 2: Run the chunker tests and verify failure**

Run:

```bash
swift test --filter LiveCaptionChunkerTests/testSoftPunctuationBoundarySealsDisplayButKeepsDraftTranslation
swift test --filter LiveCaptionChunkerTests/testSpeechFinalBoundarySealsDisplayAndFinalizesTranslation
swift test --filter LiveCaptionChunkerTests/testSpeakerChangeBoundaryFinalizesPreviousSpeakerTranslation
```

Expected: failures because `LiveCaptionChunker.frozen` still only sets `chunkState` and `freezeReason`.

- [ ] **Step 3: Update draft turn creation**

In all `LiveCaptionTurn(...)` draft creation sites inside `LiveCaptionChunker.mergedChunk`, pass:

```swift
displayState: .draft,
translationState: .draft,
boundaryReason: nil,
boundaryStrength: nil
```

- [ ] **Step 4: Update frozen turn creation**

Replace the tail of `frozen(_ turn:reason:)` with explicit boundary state:

```swift
let strength = reason.boundaryStrength
return LiveCaptionTurn(
    id: turn.id,
    sourceSegmentID: turn.sourceSegmentID,
    sourceSegmentIDs: turn.sourceSegmentIDs,
    speaker: turn.speaker,
    originalText: turn.originalText,
    translatedText: turn.translatedText,
    sourceLocale: turn.sourceLocale,
    targetLocale: turn.targetLocale,
    isFinal: true,
    captionHealth: turn.captionHealth,
    translationHealth: .pending,
    createdAt: turn.createdAt,
    chunkState: .frozen,
    translationRevision: turn.translationRevision,
    freezeReason: reason,
    displayState: .sealed,
    translationState: strength == .hard ? .final : .draft,
    boundaryReason: reason,
    boundaryStrength: strength
)
```

- [ ] **Step 5: Run chunker tests and commit**

Run:

```bash
swift test --filter LiveCaptionChunkerTests
```

Expected: all `LiveCaptionChunkerTests` pass.

Commit:

```bash
git add Sources/MeetingAgentCore/LiveCaptionChunker.swift Tests/MeetingAgentCoreTests/LiveCaptionChunkerTests.swift
git commit -m "feat: mark caption chunk boundaries"
```

---

### Task 3: Preserve Boundary State Through Live Caption Store Updates

**Files:**
- Modify: `Sources/MeetingAgentCore/LiveMeetingCockpit.swift`
- Test: `Tests/MeetingAgentCoreTests/LiveCaptionStoreTests.swift`

- [ ] **Step 1: Write failing store tests**

Add these tests to `LiveCaptionStoreTests`:

```swift
func testUpsertingSoftSealedTurnPreservesDraftTranslationState() {
    var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
    let turn = LiveCaptionTurn(
        sourceSegmentID: "segment-1",
        originalText: "That sounds good.",
        isFinal: true,
        chunkState: .frozen,
        freezeReason: .punctuation,
        displayState: .sealed,
        translationState: .draft,
        boundaryReason: .punctuation,
        boundaryStrength: .soft
    )

    store.upsert(turn)

    XCTAssertEqual(store.turns.first?.displayState, .sealed)
    XCTAssertEqual(store.turns.first?.translationState, .draft)
    XCTAssertEqual(store.turns.first?.boundaryStrength, .soft)
}

func testAppendingInterimToSoftSealedSameSpeakerBlockKeepsDisplayDraftOnlyWhenOverlapping() {
    var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
    let speaker = TranscriptSpeaker(identifier: "speaker-1", label: "User A")
    store.upsert(LiveCaptionTurn(
        sourceSegmentID: "final-1",
        speaker: speaker,
        originalText: "No. It works.",
        isFinal: true,
        chunkState: .frozen,
        freezeReason: .punctuation,
        displayState: .sealed,
        translationState: .draft,
        boundaryReason: .punctuation,
        boundaryStrength: .soft
    ))

    let updated = store.append(TranscriptSegment(
        id: "interim-1",
        speaker: speaker,
        text: "It works very well.",
        language: "en-US",
        isFinal: false
    ))

    XCTAssertEqual(store.turns.count, 1)
    XCTAssertEqual(updated.displayState, .draft)
    XCTAssertEqual(updated.translationState, .draft)
    XCTAssertNil(updated.boundaryReason)
    XCTAssertNil(updated.boundaryStrength)
}
```

- [ ] **Step 2: Run and verify the tests fail**

Run:

```bash
swift test --filter LiveCaptionStoreTests/testUpsertingSoftSealedTurnPreservesDraftTranslationState
swift test --filter LiveCaptionStoreTests/testAppendingInterimToSoftSealedSameSpeakerBlockKeepsDisplayDraftOnlyWhenOverlapping
```

Expected: at least the second test fails until provisional merge resets display/boundary fields correctly.

- [ ] **Step 3: Update `LiveCaptionStore.append` turn creation**

In the `let turn = LiveCaptionTurn(...)` initializer in `append(_:)`, pass:

```swift
displayState: segment.isFinal ? .sealed : .draft,
translationState: .draft,
boundaryReason: nil,
boundaryStrength: nil
```

- [ ] **Step 4: Update `mergedTurn` and `mergedProvisionalTurn`**

In `mergedTurn`, preserve the appended turn's boundary state:

```swift
merged.displayState = turn.displayState
merged.translationState = turn.translationState
merged.boundaryReason = turn.boundaryReason
merged.boundaryStrength = turn.boundaryStrength
```

In `mergedProvisionalTurn`, reset to active draft:

```swift
merged.displayState = .draft
merged.translationState = .draft
merged.boundaryReason = nil
merged.boundaryStrength = nil
```

- [ ] **Step 5: Run store tests and commit**

Run:

```bash
swift test --filter LiveCaptionStoreTests
```

Expected: all `LiveCaptionStoreTests` pass.

Commit:

```bash
git add Sources/MeetingAgentCore/LiveMeetingCockpit.swift Tests/MeetingAgentCoreTests/LiveCaptionStoreTests.swift
git commit -m "fix: preserve caption boundary state in store"
```

---

### Task 4: Add Speaker Grouping for UI Rendering

**Files:**
- Modify: `Sources/MeetingAgentCore/LiveMeetingCockpit.swift`
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift`
- Test: `Tests/MeetingAgentCoreTests/LiveCaptionStoreTests.swift`
- Test: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

- [ ] **Step 1: Write failing speaker grouping tests**

Add this struct and tests near the live caption store tests:

```swift
func testSpeakerGroupsCombineConsecutiveSameSpeakerCaptionBlocks() {
    let speaker = TranscriptSpeaker(identifier: "speaker-1", label: "User A")
    let groups = LiveCaptionSpeakerGroup.groups(from: [
        LiveCaptionTurn(sourceSegmentID: "s1", speaker: speaker, originalText: "First block.", isFinal: true),
        LiveCaptionTurn(sourceSegmentID: "s2", speaker: speaker, originalText: "Second block.", isFinal: true),
        LiveCaptionTurn(sourceSegmentID: "s3", speaker: TranscriptSpeaker(identifier: "speaker-2", label: "User B"), originalText: "Other speaker.", isFinal: true)
    ])

    XCTAssertEqual(groups.count, 2)
    XCTAssertEqual(groups[0].speaker, speaker)
    XCTAssertEqual(groups[0].turns.map(\.sourceSegmentID), ["s1", "s2"])
    XCTAssertEqual(groups[1].turns.map(\.sourceSegmentID), ["s3"])
}

func testSpeakerGroupsStartNewGroupWhenSameSpeakerReturnsAfterDifferentSpeaker() {
    let userA = TranscriptSpeaker(identifier: "speaker-1", label: "User A")
    let userB = TranscriptSpeaker(identifier: "speaker-2", label: "User B")
    let groups = LiveCaptionSpeakerGroup.groups(from: [
        LiveCaptionTurn(sourceSegmentID: "a1", speaker: userA, originalText: "A first.", isFinal: true),
        LiveCaptionTurn(sourceSegmentID: "b1", speaker: userB, originalText: "B.", isFinal: true),
        LiveCaptionTurn(sourceSegmentID: "a2", speaker: userA, originalText: "A again.", isFinal: true)
    ])

    XCTAssertEqual(groups.count, 3)
    XCTAssertEqual(groups.map { $0.speaker.label }, ["User A", "User B", "User A"])
}
```

- [ ] **Step 2: Run and verify failure**

Run:

```bash
swift test --filter LiveCaptionStoreTests/testSpeakerGroupsCombineConsecutiveSameSpeakerCaptionBlocks
swift test --filter LiveCaptionStoreTests/testSpeakerGroupsStartNewGroupWhenSameSpeakerReturnsAfterDifferentSpeaker
```

Expected: compile failure because `LiveCaptionSpeakerGroup` does not exist.

- [ ] **Step 3: Implement `LiveCaptionSpeakerGroup`**

Add this public type in `LiveMeetingCockpit.swift` after `LiveCaptionTurn`:

```swift
public struct LiveCaptionSpeakerGroup: Equatable, Identifiable {
    public var id: String
    public var speaker: TranscriptSpeaker
    public var turns: [LiveCaptionTurn]

    public init(id: String, speaker: TranscriptSpeaker, turns: [LiveCaptionTurn]) {
        self.id = id
        self.speaker = speaker
        self.turns = turns
    }

    public static func groups(from turns: [LiveCaptionTurn]) -> [LiveCaptionSpeakerGroup] {
        var groups: [LiveCaptionSpeakerGroup] = []
        for turn in turns {
            if let lastIndex = groups.indices.last,
               groups[lastIndex].speaker == turn.speaker {
                groups[lastIndex].turns.append(turn)
            } else {
                groups.append(LiveCaptionSpeakerGroup(id: turn.id, speaker: turn.speaker, turns: [turn]))
            }
        }
        return groups
    }
}
```

- [ ] **Step 4: Add a layout source test for grouped rendering**

In `MainWindowViewLayoutTests`, add:

```swift
func testUnifiedTranscriptRendersSpeakerGroupsInsteadOfOneLabelPerBlock() throws {
    let source = try String(contentsOfFile: "Sources/MeetingAgentApp/MainWindowView.swift")

    XCTAssertTrue(source.contains("LiveCaptionSpeakerGroup.groups(from: turns)"))
    XCTAssertTrue(source.contains("ForEach(group.turns)"))
    XCTAssertTrue(source.contains("BilingualTranscriptBlock"))
}
```

- [ ] **Step 5: Update SwiftUI rendering**

In `UnifiedTranscriptView.body`, replace the direct `ForEach(turns)` rendering with grouped rendering:

```swift
let groups = LiveCaptionSpeakerGroup.groups(from: turns)
ForEach(groups) { group in
    BilingualTranscriptGroup(
        group: group,
        sourceLocale: sourceLocale,
        targetLocale: targetLocale,
        editSpeaker: group.speaker.identifier == nil ? nil : {
            if let firstTurn = group.turns.first {
                editSpeaker(firstTurn)
            }
        },
        editText: editText
    )
    .id(group.turns.last?.id ?? group.id)
}
```

Rename the existing `BilingualTranscriptRow` to `BilingualTranscriptBlock` and create a wrapper:

```swift
private struct BilingualTranscriptGroup: View {
    let group: LiveCaptionSpeakerGroup
    let sourceLocale: String
    let targetLocale: String
    var editSpeaker: (() -> Void)?
    var editText: (LiveCaptionTurn) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            speakerLabel
            ForEach(group.turns) { turn in
                BilingualTranscriptBlock(
                    turn: turn,
                    secondLanguageEnabled: secondLanguageEnabled(for: turn),
                    editText: {
                        editText(turn)
                    }
                )
            }
        }
        .padding(14)
        .background(CommandCenterPalette.panel.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func secondLanguageEnabled(for turn: LiveCaptionTurn) -> Bool {
        LiveCaptionDisplayState.isSecondLanguageEnabled(
            sourceLocale: turn.sourceLocale.isEmpty ? sourceLocale : turn.sourceLocale,
            targetLocale: turn.targetLocale.isEmpty ? targetLocale : turn.targetLocale,
            hasTranslatedText: !(turn.translatedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        )
    }

    private var speakerDisplayName: String {
        group.speaker.label ?? group.speaker.identifier ?? "Speaker"
    }

    @ViewBuilder
    private var speakerLabel: some View {
        if let editSpeaker {
            Menu {
                Button("Edit name") {
                    editSpeaker()
                }
            } label: {
                HStack(spacing: 4) {
                    Text(speakerDisplayName)
                        .commandCenterMono()
                    Image(systemName: "chevron.down")
                        .font(CommandCenterTypography.caption)
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .help("Edit speaker name")
        } else {
            Text(speakerDisplayName)
                .commandCenterMono()
        }
    }
}
```

In `BilingualTranscriptBlock`, remove speaker editing and speaker label rendering. Keep the text edit button in its header.

- [ ] **Step 6: Run UI grouping tests and commit**

Run:

```bash
swift test --filter LiveCaptionStoreTests/testSpeakerGroups
swift test --filter MainWindowViewLayoutTests/testUnifiedTranscriptRendersSpeakerGroupsInsteadOfOneLabelPerBlock
```

Expected: all selected tests pass.

Commit:

```bash
git add Sources/MeetingAgentCore/LiveMeetingCockpit.swift Sources/MeetingAgentApp/MainWindowView.swift Tests/MeetingAgentCoreTests/LiveCaptionStoreTests.swift Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift
git commit -m "feat: group live captions by speaker"
```

---

### Task 5: Split Draft and Final Translation Scheduling

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] **Step 1: Write failing translation boundary tests**

Add this test to `MeetingAgentViewModelTests`:

```swift
func testSoftCaptionBoundaryRequestsDraftTranslationButDoesNotFinalizeTranslation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(baseDirectory: root)
    let record = try store.createMeeting(name: "Meet", startedAt: Date()).record
    let writer = try TranscriptFileWriter(url: XCTUnwrap(record.transcriptURL), structuredURL: XCTUnwrap(record.transcriptJSONURL))
    let provider = ViewModelFakeTextTranslationProvider(translations: ["deepgram-transcribe-stream-0.00": "草稿翻译"])
    let viewModel = MeetingAgentViewModel(
        store: store,
        captionTranslationProviderFactory: { _ in provider },
        processTargetsProvider: { [] }
    )
    try viewModel.loadMeetings()
    viewModel.selectMeeting(record.id)

    try writer.replace(with: [
        TranscriptSegment(
            id: "deepgram-transcribe-stream-0.00",
            speaker: TranscriptSpeaker(identifier: "speaker-1", label: "User A"),
            startTimeSeconds: 0,
            endTimeSeconds: 9.49,
            text: "My name is Sherwin Chaffee, and I work at Microsoft as a copilot principal technical specialist. Now on this channel, we often build our own autonomous agents",
            language: "en-US",
            sourceProvider: "deepgram-transcribe",
            isFinal: true,
            speechFinal: false,
            timingSource: .precise
        )
    ])

    viewModel.drainRecordingFrames()
    try await waitFor { viewModel.liveCaptionTurns.first?.translatedText == "草稿翻译" }

    XCTAssertEqual(viewModel.liveCaptionTurns.first?.displayState, .sealed)
    XCTAssertEqual(viewModel.liveCaptionTurns.first?.translationState, .draft)
    XCTAssertEqual(viewModel.liveCaptionTurns.first?.boundaryStrength, .soft)
}
```

Add this final boundary test:

```swift
func testSpeechFinalCaptionBoundaryRequestsFinalTranslation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(baseDirectory: root)
    let record = try store.createMeeting(name: "Meet", startedAt: Date()).record
    let writer = try TranscriptFileWriter(url: XCTUnwrap(record.transcriptURL), structuredURL: XCTUnwrap(record.transcriptJSONURL))
    let provider = ViewModelFakeTextTranslationProvider(translations: ["segment-1": "最终翻译"])
    let viewModel = MeetingAgentViewModel(
        store: store,
        captionTranslationProviderFactory: { _ in provider },
        processTargetsProvider: { [] }
    )
    try viewModel.loadMeetings()
    viewModel.selectMeeting(record.id)

    try writer.replace(with: [
        TranscriptSegment(
            id: "segment-1",
            speaker: TranscriptSpeaker(identifier: "speaker-1", label: "User A"),
            text: "Done.",
            language: "en-US",
            sourceProvider: "deepgram-transcribe",
            isFinal: true,
            speechFinal: true
        )
    ])

    viewModel.drainRecordingFrames()
    try await waitFor { viewModel.liveCaptionTurns.first?.translatedText == "最终翻译" }

    XCTAssertEqual(viewModel.liveCaptionTurns.first?.translationState, .final)
    XCTAssertEqual(viewModel.liveCaptionTurns.first?.boundaryStrength, .hard)
}
```

- [ ] **Step 2: Run and verify failure**

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testSoftCaptionBoundaryRequestsDraftTranslationButDoesNotFinalizeTranslation
swift test --filter MeetingAgentViewModelTests/testSpeechFinalCaptionBoundaryRequestsFinalTranslation
```

Expected: failures until chunk/store state is preserved through view model translation.

- [ ] **Step 3: Update draft candidate selection**

In `MeetingAgentViewModel.scheduleCaptionTextTranslationIfNeeded`, keep the existing draft behavior but switch from `chunkState == .draft` to a helper:

```swift
private func shouldScheduleDraftTranslation(for turn: LiveCaptionTurn) -> Bool {
    guard turn.translationState != .final else {
        return false
    }
    if turn.displayState == .draft {
        return shouldTranslateDraftCaption(turn)
    }
    if turn.displayState == .sealed, turn.boundaryStrength == .soft {
        return true
    }
    return false
}
```

Use it in the candidate filter:

```swift
let draftCandidates = liveCaptionStore.turns.filter { turn in
    guard turn.translationHealth == .pending,
          shouldScheduleDraftTranslation(for: turn),
          draftTranslationInFlightByTurnID[turn.id] != turn.translationRevision
    else { return false }
    return true
}
```

- [ ] **Step 4: Add final candidate scheduling**

Add a second candidate list after draft candidates:

```swift
let finalCandidates = liveCaptionStore.turns.filter { turn in
    guard turn.displayState == .sealed,
          turn.boundaryStrength == .hard,
          turn.translationHealth == .pending,
          finalTranslationInFlightByTurnID[turn.id] != turn.translationRevision
    else { return false }
    return true
}
```

Add a property near `draftTranslationInFlightByTurnID`:

```swift
private var finalTranslationInFlightByTurnID: [String: Int] = [:]
```

Schedule final candidates through the same provider path, but record them in `finalTranslationInFlightByTurnID`.

- [ ] **Step 5: Guard against stale draft overwrites**

In the translation completion path that calls `liveCaptionStore.attachTranslation`, add this guard before applying a draft response:

```swift
guard liveCaptionStore.turns.first(where: { $0.id == turn.id })?.translationState != .final else {
    draftTranslationInFlightByTurnID[turn.id] = nil
    return
}
```

For final responses, update the store with translation and preserve `translationState = .final`. If `attachTranslation` currently only sets `translationHealth`, add a store method:

```swift
public mutating func markTranslationFinal(forTurnID turnID: String) {
    guard let index = turns.firstIndex(where: { $0.id == turnID }) else { return }
    turns[index].translationState = .final
}
```

Call it immediately after attaching a final translation.

- [ ] **Step 6: Run targeted view model tests and commit**

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testSoftCaptionBoundaryRequestsDraftTranslationButDoesNotFinalizeTranslation
swift test --filter MeetingAgentViewModelTests/testSpeechFinalCaptionBoundaryRequestsFinalTranslation
swift test --filter MeetingAgentViewModelTests/testOlderDraftTranslationDoesNotOverwriteNewerDraft
```

Expected: all selected tests pass.

Commit:

```bash
git add Sources/MeetingAgentCore/MeetingAgentViewModel.swift Sources/MeetingAgentCore/LiveMeetingCockpit.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift
git commit -m "feat: separate draft and final caption translation"
```

---

### Task 6: Preserve Context for Final Translation Units

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] **Step 1: Write failing context test**

Add this test to `MeetingAgentViewModelTests`:

```swift
func testHardBoundaryFinalTranslationUsesSameSpeakerSoftBlockContext() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(baseDirectory: root)
    let record = try store.createMeeting(name: "Meet", startedAt: Date()).record
    let writer = try TranscriptFileWriter(url: XCTUnwrap(record.transcriptURL), structuredURL: XCTUnwrap(record.transcriptJSONURL))
    let provider = ViewModelFakeTextTranslationProvider(translations: ["segment-2": "完整上下文翻译"])
    let viewModel = MeetingAgentViewModel(
        store: store,
        captionTranslationProviderFactory: { _ in provider },
        processTargetsProvider: { [] }
    )
    try viewModel.loadMeetings()
    viewModel.selectMeeting(record.id)

    try writer.replace(with: [
        TranscriptSegment(
            id: "segment-1",
            speaker: TranscriptSpeaker(identifier: "speaker-1", label: "User A"),
            text: "That is the interpreter agent.",
            language: "en-US",
            sourceProvider: "deepgram-transcribe",
            isFinal: true,
            speechFinal: false
        ),
        TranscriptSegment(
            id: "segment-2",
            speaker: TranscriptSpeaker(identifier: "speaker-1", label: "User A"),
            text: "So I just turned it on.",
            language: "en-US",
            sourceProvider: "deepgram-transcribe",
            isFinal: true,
            speechFinal: true
        )
    ])

    viewModel.drainRecordingFrames()
    try await waitFor { viewModel.liveCaptionTurns.last?.translatedText == "完整上下文翻译" }

    XCTAssertEqual(provider.requestedSegmentTexts.last, ["That is the interpreter agent. So I just turned it on."])
}
```

- [ ] **Step 2: Run and verify failure**

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testHardBoundaryFinalTranslationUsesSameSpeakerSoftBlockContext
```

Expected: failure because the final request currently uses only the turn text selected for translation.

- [ ] **Step 3: Add translation source text helper**

In `MeetingAgentViewModel`, add:

```swift
private func translationSourceText(for turn: LiveCaptionTurn, final: Bool) -> String {
    guard final else {
        return turn.originalText
    }
    let groups = LiveCaptionSpeakerGroup.groups(from: liveCaptionStore.turns)
    guard let group = groups.first(where: { $0.turns.contains(where: { $0.id == turn.id }) }) else {
        return turn.originalText
    }
    var texts: [String] = []
    for candidate in group.turns {
        texts.append(candidate.originalText)
        if candidate.id == turn.id {
            break
        }
    }
    return texts
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}
```

Use `translationSourceText(for:final:)` when building the provider request:

```swift
let sourceText = translationSourceText(for: turn, final: isFinalTranslation)
```

- [ ] **Step 4: Run targeted tests and commit**

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testHardBoundaryFinalTranslationUsesSameSpeakerSoftBlockContext
swift test --filter MeetingAgentViewModelTests/testDraftCaptionTranslationUpdatesSameTurnAsTextGrows
```

Expected: both pass.

Commit:

```bash
git add Sources/MeetingAgentCore/MeetingAgentViewModel.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift
git commit -m "feat: translate final captions with speaker context"
```

---

### Task 7: Full Regression Verification

**Files:**
- No production edits expected.
- Tests: full suite.

- [ ] **Step 1: Run focused regression tests**

Run:

```bash
swift test --filter LiveCaptionChunkerTests
swift test --filter LiveCaptionStoreTests
swift test --filter MeetingAgentViewModelTests/testInterimDeepgramSegmentDisplaysWithDraftTranslationBeforeFinalArrives
swift test --filter MeetingAgentViewModelTests/testFinalDeepgramSegmentRemovesCoveredInterimTurnsFromLiveCaptions
swift test --filter MeetingAgentViewModelTests/testOlderDraftTranslationDoesNotOverwriteNewerDraft
swift test --filter MainWindowViewLayoutTests/testUnifiedTranscriptRendersSpeakerGroupsInsteadOfOneLabelPerBlock
```

Expected: all selected tests pass.

- [ ] **Step 2: Run the required full suite**

Run:

```bash
make test
```

Expected:

```text
Test Suite 'All tests' passed
Coverage gate passed.
```

- [ ] **Step 3: Check git status**

Run:

```bash
git status --short --branch
```

Expected: only untracked local environment/log files may remain, such as `.env` or `x.log`.

- [ ] **Step 4: Commit any final test-only adjustments**

If Step 1 or Step 2 required test-only corrections, commit them:

```bash
git add Tests/MeetingAgentCoreTests
git commit -m "test: cover live caption boundary regressions"
```

If no files changed after verification, do not create an empty commit.

