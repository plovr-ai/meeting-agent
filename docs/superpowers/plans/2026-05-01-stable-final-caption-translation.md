# Stable Final Caption Translation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make final caption translations durable across live caption turn churn, then reduce draft translation waste using measurable logs.

**Architecture:** Keep translation request policy in `CaptionTranslationScheduler`, but split final request identity from live turn identity. Final completions attach by original turn ID, rebind by source segment IDs, or persist by source segment ID; draft completions keep strict stale protection. `LiveCaptionPipeline` exposes live-only versus final-only scheduling paths, and the analysis script counts persisted final translations as final success.

**Tech Stack:** Swift 5.9, Swift concurrency, XCTest, existing JSONL `PerformanceEventLogger`, existing transcript translation cache.

---

## File Structure

- Modify `Sources/MeetingAgentCore/CaptionTranslationScheduler.swift`
  - Own stable final request keys, request attachment targets, final rebind/persist apply outcomes, final/draft key sets, and final outcome telemetry.
- Modify `Sources/MeetingAgentCore/LiveCaptionPipeline.swift`
  - Route normal live updates, replay, flush, and explicit pending translation scheduling through the right scheduler mode.
- Modify `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
  - Adapt the caption translation persistence closure to return whether the transcript cache update succeeded.
- Modify `scripts/analyze-meeting-performance.swift`
  - Treat final persisted outcomes as final success and add readable final rebind/persist/failure metrics.
- Modify `Tests/MeetingAgentCoreTests/CaptionTranslationSchedulerTests.swift`
  - Cover stable final keys, rebind attach, persist-only success, and draft stale safety.
- Modify `Tests/MeetingAgentCoreTests/LiveCaptionPipelineTests.swift`
  - Cover replay/flush scheduling policy.
- Modify `Tests/MeetingAgentCoreTests/MeetingPerformanceAnalysisScriptTests.swift`
  - Cover persisted final success metrics and readable names.
- Modify `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift` only if persistence closure signature breakage requires integration coverage updates.

---

### Task 1: Add Final Request Target And Stable Final Key

**Files:**
- Modify: `Sources/MeetingAgentCore/CaptionTranslationScheduler.swift`
- Test: `Tests/MeetingAgentCoreTests/CaptionTranslationSchedulerTests.swift`

- [ ] **Step 1: Write the failing final-key regression test**

Add this test to `CaptionTranslationSchedulerTests`:

```swift
func testFinalTranslationKeyIgnoresMutableLiveTurnState() async throws {
    var originalStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
    originalStore.upsert(hardSealedTurn(text: "confirm the launch owner", sourceLocale: "en-US", targetLocale: "zh-CN"))
    let provider = RecordingTextTranslationProvider(translations: ["segment-1": "确认上线负责人"])
    let scheduler = CaptionTranslationScheduler(
        provider: provider,
        performanceEventLogger: nil,
        configuration: CaptionTranslationSchedulerConfiguration(draftDebounceNanoseconds: 0, maxConcurrentTranslationRequests: 1)
    )

    let updates = await scheduler.translationUpdates(for: originalStore)
    let update = try XCTUnwrap(updates.first)
    var changedTurn = hardSealedTurn(text: "confirm the launch owner", sourceLocale: "en-US", targetLocale: "zh-CN")
    changedTurn.displayState = .sealed
    changedTurn.boundaryStrength = .soft
    changedTurn.boundaryReason = .punctuation
    changedTurn.translationRevision = 42
    var changedStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
    changedStore.upsert(changedTurn)

    let outcome = scheduler.apply(update, to: &changedStore)

    XCTAssertTrue(outcome.publishedVisibleText)
    XCTAssertEqual(changedStore.turns.first?.translatedText, "确认上线负责人")
    XCTAssertEqual(changedStore.turns.first?.translationState, .final)
}
```

- [ ] **Step 2: Run the focused failing test**

Run:

```bash
swift test --filter CaptionTranslationSchedulerTests/testFinalTranslationKeyIgnoresMutableLiveTurnState
```

Expected: FAIL because `apply` recomputes the current key from mutable display/boundary/revision fields and logs the result as stale.

- [ ] **Step 3: Add request attachment target types**

In `CaptionTranslationScheduler.swift`, add these types near `ActiveCaptionTranslationRequest`:

```swift
struct CaptionTranslationAttachmentTarget: Equatable {
    var originalTurnID: String
    var primarySourceSegmentID: String
    var sourceSegmentIDs: [String]
    var sourceText: String
    var speaker: TranscriptSpeaker?
    var sourceLocale: String
    var targetLocale: String
    var createdAt: Date
}

enum CaptionTranslationApplyOutcome: Equatable {
    case none
    case attached(turnID: String)
    case rebound(originalTurnID: String, reboundTurnID: String)
    case persisted(segmentID: String)

    var publishedVisibleText: Bool {
        switch self {
        case .attached, .rebound:
            return true
        case .none, .persisted:
            return false
        }
    }
}
```

Update `ActiveCaptionTranslationRequest`:

```swift
struct ActiveCaptionTranslationRequest: Equatable {
    var id: String
    var turn: LiveCaptionTurn
    var key: String
    var isDraft: Bool
    var revision: Int
    var requestOrdinalForTurn: Int = 1
    var sourceText: String = ""
    var attachmentTarget: CaptionTranslationAttachmentTarget? = nil
    var providerID: String = ""
    var configuration: CaptionTranslationSchedulerConfiguration = CaptionTranslationSchedulerConfiguration()
    var queueDepth: Int?
    var inFlightCount: Int?
}
```

- [ ] **Step 4: Split draft and final key generation**

Replace the single `translationKey(for:isFinalTranslation:)` helper with:

```swift
private func translationKey(for turn: LiveCaptionTurn, isFinalTranslation: Bool, sourceText: String? = nil) -> String {
    if isFinalTranslation {
        return finalTranslationKey(for: turn, sourceText: sourceText ?? turn.originalText)
    }
    return draftTranslationKey(for: turn)
}

private func finalTranslationKey(for turn: LiveCaptionTurn, sourceText: String) -> String {
    [
        "final",
        turn.sourceSegmentIDs.joined(separator: ","),
        normalizedTranslationSourceText(sourceText),
        turn.sourceLocale,
        turn.targetLocale
    ].joined(separator: "\u{1F}")
}

private func draftTranslationKey(for turn: LiveCaptionTurn) -> String {
    [
        turn.id,
        turn.sourceSegmentIDs.joined(separator: ","),
        turn.originalText,
        turn.sourceLocale,
        turn.targetLocale,
        "draft",
        turn.displayState.rawValue,
        turn.boundaryStrength.map(String.init(describing:)) ?? "",
        turn.boundaryReason?.rawValue ?? "",
        String(turn.translationRevision)
    ].joined(separator: "\u{1F}")
}

private func normalizedTranslationSourceText(_ text: String) -> String {
    text
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}
```

In `translationExecution`, compute `sourceText` before `key`:

```swift
let isFinalTranslation = turn.displayState == .sealed && turn.boundaryStrength == .hard
let sourceText = translationSourceText(for: turn, in: store, final: isFinalTranslation)
let key = translationKey(for: turn, isFinalTranslation: isFinalTranslation, sourceText: sourceText)
```

Build the attachment target when creating `ActiveCaptionTranslationRequest`:

```swift
let attachmentTarget = CaptionTranslationAttachmentTarget(
    originalTurnID: turn.id,
    primarySourceSegmentID: turn.sourceSegmentID,
    sourceSegmentIDs: turn.sourceSegmentIDs,
    sourceText: sourceText,
    speaker: turn.speaker,
    sourceLocale: turn.sourceLocale,
    targetLocale: turn.targetLocale,
    createdAt: turn.createdAt
)
```

Set `attachmentTarget: isFinalTranslation ? attachmentTarget : nil`.

- [ ] **Step 5: Run the focused test**

Run:

```bash
swift test --filter CaptionTranslationSchedulerTests/testFinalTranslationKeyIgnoresMutableLiveTurnState
```

Expected: PASS after Task 2 is complete; at this point it may still fail because `apply` is still strict. Keep the failing state if only key generation is complete.

- [ ] **Step 6: Commit key/target groundwork only if existing tests still pass**

Run:

```bash
swift test --filter CaptionTranslationSchedulerTests
git add Sources/MeetingAgentCore/CaptionTranslationScheduler.swift Tests/MeetingAgentCoreTests/CaptionTranslationSchedulerTests.swift
git commit -m "test: cover stable final caption translation identity"
```

Expected: Commit only when the full scheduler test file passes. If the new test is still failing by design, defer commit until Task 2.

---

### Task 2: Rebind Final Results By Source Segment IDs

**Files:**
- Modify: `Sources/MeetingAgentCore/CaptionTranslationScheduler.swift`
- Test: `Tests/MeetingAgentCoreTests/CaptionTranslationSchedulerTests.swift`

- [ ] **Step 1: Write the failing rebind test**

Add this test:

```swift
func testFinalTranslationRebindsWhenOriginalTurnWasMerged() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("caption-translation-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let eventsURL = root.appendingPathComponent("performance-events.jsonl")
    var originalStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
    originalStore.upsert(hardSealedTurn(id: "segment-1", text: "confirm launch owner", sourceLocale: "en-US", targetLocale: "zh-CN"))
    let provider = RecordingTextTranslationProvider(translations: ["segment-1": "确认上线负责人"])
    let scheduler = CaptionTranslationScheduler(
        provider: provider,
        performanceEventLogger: PerformanceEventLogger(url: eventsURL),
        configuration: CaptionTranslationSchedulerConfiguration(draftDebounceNanoseconds: 0, maxConcurrentTranslationRequests: 1)
    )

    let update = try XCTUnwrap(await scheduler.translationUpdates(for: originalStore).first)
    var currentStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
    var merged = hardSealedTurn(id: "segment-2", text: "confirm launch owner and timeline", sourceLocale: "en-US", targetLocale: "zh-CN")
    merged.id = "merged-turn"
    merged.sourceSegmentID = "segment-2"
    merged.sourceSegmentIDs = ["segment-1", "segment-2"]
    currentStore.upsert(merged)

    let outcome = scheduler.apply(update, to: &currentStore)

    XCTAssertEqual(outcome, .rebound(originalTurnID: "segment-1", reboundTurnID: "merged-turn"))
    XCTAssertEqual(currentStore.turns.first?.translatedText, "确认上线负责人")
    XCTAssertEqual(currentStore.turns.first?.translationState, .final)
    let events = try readEvents(from: eventsURL)
    XCTAssertTrue(events.contains { $0.event == "caption_translation_rebound" && $0.metadata["translationKind"] == "final" })
    XCTAssertTrue(events.contains { $0.event == "caption_translation_attached" && $0.segmentID == "merged-turn" })
    XCTAssertFalse(events.contains { $0.event == "caption_translation_stale" && $0.metadata["reason"] == "final_no_longer_current" })
}
```

- [ ] **Step 2: Run the failing rebind test**

Run:

```bash
swift test --filter CaptionTranslationSchedulerTests/testFinalTranslationRebindsWhenOriginalTurnWasMerged
```

Expected: FAIL because `apply` only finds the original `turnID`.

- [ ] **Step 3: Change `apply` to return an outcome**

Change the signature:

```swift
@discardableResult
func apply(_ update: CaptionTranslationUpdate, to store: inout LiveCaptionStore) -> CaptionTranslationApplyOutcome
```

Update non-attaching paths to return `.none`. Update draft success to return `.attached(turnID: current.id)`.

- [ ] **Step 4: Add source-segment rebind helpers**

Add these helpers to `CaptionTranslationScheduler`:

```swift
private func currentTurnForFinalRequest(
    _ request: ActiveCaptionTranslationRequest,
    in store: LiveCaptionStore
) -> LiveCaptionTurn? {
    guard let target = request.attachmentTarget else {
        return store.turns.first(where: { $0.id == request.turn.id })
    }
    if let original = store.turns.first(where: { $0.id == target.originalTurnID }),
       Set(target.sourceSegmentIDs).isSubset(of: Set(original.sourceSegmentIDs)) {
        return original
    }
    return store.turns.first { turn in
        Set(target.sourceSegmentIDs).isSubset(of: Set(turn.sourceSegmentIDs))
            && turn.targetLocale == target.targetLocale
    }
}

private func isCurrentDraftUpdate(
    _ update: CaptionTranslationUpdate,
    current: LiveCaptionTurn
) -> Bool {
    guard let request = update.request else { return false }
    return request.isDraft
        && current.translationHealth == .pending
        && draftTranslationKey(for: current) == update.key
}
```

- [ ] **Step 5: Implement final apply rebind**

In the `.finalText(let text)` branch, use this flow before logging stale:

```swift
guard let request = update.request, !request.isDraft else {
    return .none
}
guard let targetTurn = currentTurnForFinalRequest(request, in: store) else {
    return persistFinalTranslation(text, request: request)
}
let wasRebound = targetTurn.id != request.turn.id
store.attachTranslation(text, toTurnID: targetTurn.id)
store.markTranslationFinal(forTurnID: targetTurn.id)
if wasRebound {
    logRebound(request: request, reboundTurnID: targetTurn.id, textLength: text.count)
}
logAttached(request: request, attachedTurnID: targetTurn.id, textLength: text.count)
persistTranslation?(targetTurn, text, true)
return wasRebound
    ? .rebound(originalTurnID: request.turn.id, reboundTurnID: targetTurn.id)
    : .attached(turnID: targetTurn.id)
```

For draft results, keep the strict draft key guard:

```swift
guard let current = store.turns.first(where: { $0.id == update.turnID }),
      isCurrentDraftUpdate(update, current: current)
else {
    if let request = update.request,
       let current = store.turns.first(where: { $0.id == update.turnID }) {
        logStale(update: update, request: request, current: current)
    }
    return .none
}
```

- [ ] **Step 6: Add rebound logging**

Add:

```swift
private func logRebound(request: ActiveCaptionTranslationRequest, reboundTurnID: String, textLength: Int) {
    performanceEventLogger?.log(
        "caption_translation_rebound",
        segmentID: reboundTurnID,
        isFinal: true,
        textLength: textLength,
        metadata: translationMetadata(for: request, extra: ["reboundTurnID": reboundTurnID])
    )
}
```

Change `logAttached` to accept attached turn ID:

```swift
private func logAttached(request: ActiveCaptionTranslationRequest, attachedTurnID: String? = nil, textLength: Int) {
    performanceEventLogger?.log(
        "caption_translation_attached",
        segmentID: attachedTurnID ?? request.turn.id,
        isFinal: !request.isDraft,
        textLength: textLength,
        metadata: translationMetadata(for: request)
    )
    logCount("caption_translation_completed_count", request: request)
}
```

- [ ] **Step 7: Update pipeline call sites for outcome**

In `LiveCaptionPipeline.scheduleLiveTranslations()`, replace:

```swift
let attachedVisibleText = translationScheduler.apply(update, to: &store)
if attachedVisibleText {
    logCaptionSnapshotPublished(for: update, publishedAt: Date())
}
```

with:

```swift
let outcome = translationScheduler.apply(update, to: &store)
if outcome.publishedVisibleText {
    logCaptionSnapshotPublished(for: update, publishedAt: Date())
}
```

- [ ] **Step 8: Run scheduler tests**

Run:

```bash
swift test --filter CaptionTranslationSchedulerTests
```

Expected: PASS.

- [ ] **Step 9: Commit rebind behavior**

Run:

```bash
git add Sources/MeetingAgentCore/CaptionTranslationScheduler.swift Sources/MeetingAgentCore/LiveCaptionPipeline.swift Tests/MeetingAgentCoreTests/CaptionTranslationSchedulerTests.swift
git commit -m "feat: rebind final caption translations"
```

---

### Task 3: Persist Final Results When No Live Turn Can Receive Them

**Files:**
- Modify: `Sources/MeetingAgentCore/CaptionTranslationScheduler.swift`
- Modify: `Sources/MeetingAgentCore/LiveCaptionPipeline.swift`
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Test: `Tests/MeetingAgentCoreTests/CaptionTranslationSchedulerTests.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift` if needed

- [ ] **Step 1: Write the failing persist-only test**

Add this test:

```swift
func testFinalTranslationPersistsWhenLiveTurnNoLongerExists() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("caption-translation-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let eventsURL = root.appendingPathComponent("performance-events.jsonl")
    var originalStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
    originalStore.upsert(hardSealedTurn(id: "segment-1", text: "confirm launch owner", sourceLocale: "en-US", targetLocale: "zh-CN"))
    let provider = RecordingTextTranslationProvider(translations: ["segment-1": "确认上线负责人"])
    var persisted: [(segmentID: String, text: String, targetLocale: String, isFinal: Bool)] = []
    let scheduler = CaptionTranslationScheduler(
        provider: provider,
        performanceEventLogger: PerformanceEventLogger(url: eventsURL),
        persistTranslation: { target, text, isFinal in
            persisted.append((target.primarySourceSegmentID, text, target.targetLocale, isFinal))
            return true
        },
        configuration: CaptionTranslationSchedulerConfiguration(draftDebounceNanoseconds: 0, maxConcurrentTranslationRequests: 1)
    )

    let update = try XCTUnwrap(await scheduler.translationUpdates(for: originalStore).first)
    var emptyStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
    let outcome = scheduler.apply(update, to: &emptyStore)

    XCTAssertEqual(outcome, .persisted(segmentID: "segment-1"))
    XCTAssertEqual(persisted.first?.segmentID, "segment-1")
    XCTAssertEqual(persisted.first?.text, "确认上线负责人")
    XCTAssertEqual(persisted.first?.targetLocale, "zh-CN")
    XCTAssertEqual(persisted.first?.isFinal, true)
    let events = try readEvents(from: eventsURL)
    XCTAssertTrue(events.contains { $0.event == "caption_translation_persisted" && $0.metadata["translationKind"] == "final" })
    XCTAssertFalse(events.contains { $0.event == "caption_translation_stale" && $0.metadata["reason"] == "final_no_longer_current" })
}
```

- [ ] **Step 2: Run the failing persist-only test**

Run:

```bash
swift test --filter CaptionTranslationSchedulerTests/testFinalTranslationPersistsWhenLiveTurnNoLongerExists
```

Expected: FAIL because the persistence closure still requires a live `LiveCaptionTurn`.

- [ ] **Step 3: Change persistence closure signature**

Replace the scheduler property and init argument:

```swift
private let persistTranslation: ((CaptionTranslationAttachmentTarget, String, Bool) -> Bool)?
```

Constructor argument:

```swift
persistTranslation: ((CaptionTranslationAttachmentTarget, String, Bool) -> Bool)? = nil
```

Update live attach persistence calls:

```swift
if let target = request.attachmentTarget {
    _ = persistTranslation?(target, text, true)
}
```

For draft attach, keep persistence only when a target exists or create a draft target from the current turn:

```swift
let target = CaptionTranslationAttachmentTarget(
    originalTurnID: current.id,
    primarySourceSegmentID: current.sourceSegmentID,
    sourceSegmentIDs: current.sourceSegmentIDs,
    sourceText: current.originalText,
    speaker: current.speaker,
    sourceLocale: current.sourceLocale,
    targetLocale: current.targetLocale,
    createdAt: current.createdAt
)
_ = persistTranslation?(target, text, false)
```

- [ ] **Step 4: Add persist outcome helper and logging**

Add:

```swift
private func persistFinalTranslation(
    _ text: String,
    request: ActiveCaptionTranslationRequest
) -> CaptionTranslationApplyOutcome {
    guard let target = request.attachmentTarget,
          let persistTranslation,
          persistTranslation(target, text, true)
    else {
        logStaleWithoutCurrent(request: request, reason: "source_segment_deleted")
        return .none
    }
    performanceEventLogger?.log(
        "caption_translation_persisted",
        segmentID: target.primarySourceSegmentID,
        isFinal: true,
        textLength: text.count,
        metadata: translationMetadata(for: request)
    )
    logCount("caption_translation_completed_count", request: request)
    return .persisted(segmentID: target.primarySourceSegmentID)
}

private func logStaleWithoutCurrent(request: ActiveCaptionTranslationRequest, reason: String) {
    performanceEventLogger?.log(
        "caption_translation_stale",
        segmentID: request.attachmentTarget?.primarySourceSegmentID ?? request.turn.id,
        isFinal: !request.isDraft,
        textLength: request.turn.originalText.count,
        metadata: translationMetadata(for: request, extra: ["reason": reason])
    )
    logCount("caption_translation_stale_count", request: request, extra: ["reason": reason])
}
```

- [ ] **Step 5: Adapt `LiveCaptionPipeline` initializer**

Change the stored property and init parameter:

```swift
private let persistTranslation: ((CaptionTranslationAttachmentTarget, String, Bool) -> Bool)?
```

and:

```swift
persistTranslation: ((CaptionTranslationAttachmentTarget, String, Bool) -> Bool)? = nil
```

Pass it unchanged to `CaptionTranslationScheduler`.

- [ ] **Step 6: Adapt `MeetingAgentViewModel` persistence closure**

Change `makeLiveCaptionPipeline` signatures to accept:

```swift
persistTranslation: ((CaptionTranslationAttachmentTarget, String, Bool) -> Bool)? = nil
```

Replace the closure body with:

```swift
persistTranslation: { [weak self] target, translatedText, isFinal in
    if let self, self.activeMeetingID == self.selectedMeetingID {
        if (try? self.recorder.updateActiveTranscriptTranslation(
            segmentID: target.primarySourceSegmentID,
            text: translatedText,
            targetLocale: target.targetLocale,
            isFinal: isFinal
        )) == true {
            return true
        }
    }
    do {
        try TranscriptFileWriter.updateSegmentTranslation(
            segmentID: target.primarySourceSegmentID,
            text: translatedText,
            targetLocale: target.targetLocale,
            isFinal: isFinal,
            textURL: textURL,
            structuredURL: structuredURL
        )
        return true
    } catch {
        return false
    }
}
```

- [ ] **Step 7: Run persistence-focused tests**

Run:

```bash
swift test --filter CaptionTranslationSchedulerTests/testFinalTranslationPersistsWhenLiveTurnNoLongerExists
swift test --filter MeetingAgentViewModelTests/testSelectingMeetingReplaysCachedFinalCaptionTranslationThroughPipeline
```

Expected: PASS.

- [ ] **Step 8: Commit persist-only behavior**

Run:

```bash
git add Sources/MeetingAgentCore/CaptionTranslationScheduler.swift Sources/MeetingAgentCore/LiveCaptionPipeline.swift Sources/MeetingAgentCore/MeetingAgentViewModel.swift Tests/MeetingAgentCoreTests/CaptionTranslationSchedulerTests.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift
git commit -m "feat: persist final caption translations without live turns"
```

---

### Task 4: Split Draft And Final Scheduling Modes For Replay And Flush

**Files:**
- Modify: `Sources/MeetingAgentCore/CaptionTranslationScheduler.swift`
- Modify: `Sources/MeetingAgentCore/LiveCaptionPipeline.swift`
- Test: `Tests/MeetingAgentCoreTests/LiveCaptionPipelineTests.swift`

- [ ] **Step 1: Write the failing replay draft suppression test**

Add this test to `LiveCaptionPipelineTests`:

```swift
func testReplayDoesNotScheduleDraftTranslations() async throws {
    let provider = RecordingTextTranslationProvider(translations: ["segment-1": "草稿翻译"])
    let pipeline = LiveCaptionPipeline(
        sourceLocale: "en-US",
        targetLocale: "zh-CN",
        translationProvider: provider,
        performanceEventLogger: nil
    )
    let document = TranscriptDocument(segments: [
        TranscriptSegment(
            id: "segment-1",
            speaker: TranscriptSpeaker(identifier: "speaker-1"),
            text: "draft text from replay",
            language: "en-US",
            isFinal: false
        )
    ])

    _ = await pipeline.replay(document)

    XCTAssertTrue(provider.requests.isEmpty)
}
```

Use the existing test provider name and request accessor in `LiveCaptionPipelineTests`; if the helper is named differently, adapt only the helper reference.

- [ ] **Step 2: Run the failing replay test**

Run:

```bash
swift test --filter LiveCaptionPipelineTests/testReplayDoesNotScheduleDraftTranslations
```

Expected: FAIL if replay currently schedules draft translation.

- [ ] **Step 3: Add scheduler mode methods**

In `CaptionTranslationScheduler`, make the existing methods explicit:

```swift
func finalTranslationUpdates(for store: LiveCaptionStore) async -> [CaptionTranslationUpdate] {
    await translationUpdates(for: store, includingDrafts: false)
}

func liveTranslationUpdates(for store: LiveCaptionStore) async -> [CaptionTranslationUpdate] {
    await translationUpdates(for: store, includingDrafts: true)
}
```

Keep `translationUpdates(for:)` as a compatibility wrapper:

```swift
func translationUpdates(for store: LiveCaptionStore) async -> [CaptionTranslationUpdate] {
    await finalTranslationUpdates(for: store)
}
```

- [ ] **Step 4: Split pipeline scheduling helpers**

In `LiveCaptionPipeline`, add:

```swift
private func scheduleFinalTranslationsOnly() async {
    let generation = storeGeneration
    let updates = await translationScheduler.finalTranslationUpdates(for: store)
    guard generation == storeGeneration else {
        for update in updates {
            translationScheduler.discardStale(update, against: store)
        }
        return
    }
    for update in updates {
        let outcome = translationScheduler.apply(update, to: &store)
        if outcome.publishedVisibleText {
            logCaptionSnapshotPublished(for: update, publishedAt: Date())
        }
    }
}
```

Change `replay(_:)`:

```swift
public func replay(_ document: TranscriptDocument) async -> LiveCaptionPipelineSnapshot {
    replayCaptions(document)
    await scheduleFinalTranslationsOnly()
    return snapshot(
        captionHealth: store.turns.isEmpty ? .idle : .live,
        translationHealth: currentTranslationHealth()
    )
}
```

Change `flush(reason:)` to call `scheduleFinalTranslationsOnly()` after `flushCaptionsOnly(reason:)`.

Keep normal `apply(_:)` using `scheduleLiveTranslations()`.

- [ ] **Step 5: Run pipeline tests**

Run:

```bash
swift test --filter LiveCaptionPipelineTests
```

Expected: PASS.

- [ ] **Step 6: Commit scheduling split**

Run:

```bash
git add Sources/MeetingAgentCore/CaptionTranslationScheduler.swift Sources/MeetingAgentCore/LiveCaptionPipeline.swift Tests/MeetingAgentCoreTests/LiveCaptionPipelineTests.swift
git commit -m "fix: suppress replay draft caption translations"
```

---

### Task 5: Update Performance Analysis Metrics

**Files:**
- Modify: `scripts/analyze-meeting-performance.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingPerformanceAnalysisScriptTests.swift`

- [ ] **Step 1: Write failing analysis-script test for final persisted success**

Add a test that writes JSONL with one final scheduled event and one final persisted event, then runs the script and checks readable output:

```swift
func testFinalPersistedTranslationCountsAsFinalSuccess() throws {
    let fixture = try ScriptFixture()
    try fixture.writeEvents([
        event("caption_translation_scheduled", isFinal: true, metadata: [
            "translationKind": "final",
            "translationRequestID": "request-1",
            "sourceSegmentID": "segment-1"
        ]),
        event("caption_translation_persisted", isFinal: true, metadata: [
            "translationKind": "final",
            "translationRequestID": "request-1",
            "sourceSegmentID": "segment-1"
        ])
    ])

    let output = try fixture.runScript()

    XCTAssertTrue(output.contains("Final Translation Success Rate: 100.0%"))
    XCTAssertTrue(output.contains("Final Visible Attach Rate: 0.0%"))
    XCTAssertTrue(output.contains("Final Persist-Only Rate: 100.0%"))
    XCTAssertTrue(output.contains("Final True Failure Rate: 0.0%"))
}
```

Use existing helpers in `MeetingPerformanceAnalysisScriptTests`; if helper names differ, keep the event content and assertions unchanged.

- [ ] **Step 2: Run the failing analysis test**

Run:

```bash
swift test --filter MeetingPerformanceAnalysisScriptTests/testFinalPersistedTranslationCountsAsFinalSuccess
```

Expected: FAIL because the script only counts `caption_translation_attached`.

- [ ] **Step 3: Count persisted final outcomes as success**

In `scripts/analyze-meeting-performance.swift`, add helpers:

```swift
private func successfulTranslationEvents(kind: String? = nil) -> [PerformanceEvent] {
    let successEvents = translationEvents("caption_translation_attached")
        + translationEvents("caption_translation_persisted")
    guard let kind else { return successEvents }
    return successEvents.filter { $0.metadata["translationKind"] == kind }
}

private func finalVisibleAttachRate() -> Double? {
    let scheduled = translationEvents("caption_translation_scheduled").filter { $0.metadata["translationKind"] == "final" }.count
    guard scheduled > 0 else { return nil }
    let attached = translationEvents("caption_translation_attached").filter { $0.metadata["translationKind"] == "final" }.count
    return Double(attached) / Double(scheduled) * 100
}

private func finalPersistOnlyRate() -> Double? {
    let scheduled = translationEvents("caption_translation_scheduled").filter { $0.metadata["translationKind"] == "final" }.count
    guard scheduled > 0 else { return nil }
    let persisted = translationEvents("caption_translation_persisted").filter { $0.metadata["translationKind"] == "final" }.count
    return Double(persisted) / Double(scheduled) * 100
}

private func finalTrueFailureRate() -> Double? {
    let scheduled = translationEvents("caption_translation_scheduled").filter { $0.metadata["translationKind"] == "final" }.count
    guard scheduled > 0 else { return nil }
    let failures = translationEvents("caption_translation_stale")
        .filter { $0.metadata["translationKind"] == "final" }
        .filter { event in
            let reason = event.metadata["reason"] ?? ""
            return reason == "source_segment_deleted"
                || reason == "target_locale_changed"
                || reason == "provider_configuration_changed"
        }
        .count
        + translationEvents("caption_translation_provider_error")
            .filter { $0.metadata["translationKind"] == "final" }
            .count
    return Double(failures) / Double(scheduled) * 100
}
```

Update `translationSuccessRate` to use `successfulTranslationEvents`.

- [ ] **Step 4: Add readable report lines**

In the `Experience KPIs` section, after final success, add:

```swift
lines.append("Final Visible Attach Rate: \(format(percent: finalVisibleAttachRate()))")
lines.append("Final Persist-Only Rate: \(format(percent: finalPersistOnlyRate()))")
lines.append("Final True Failure Rate: \(format(percent: finalTrueFailureRate()))")
```

In `Process Metrics`, extend outcomes:

```swift
lines.append("Translation outcomes: scheduled \(translationEvents("caption_translation_scheduled").count), attached \(translationEvents("caption_translation_attached").count), persisted \(translationEvents("caption_translation_persisted").count), rebound \(translationEvents("caption_translation_rebound").count), stale \(translationEvents("caption_translation_stale").count), cancelled \(translationEvents("caption_translation_cancelled").count), provider_error \(translationEvents("caption_translation_provider_error").count)")
```

- [ ] **Step 5: Run analysis tests**

Run:

```bash
swift test --filter MeetingPerformanceAnalysisScriptTests
```

Expected: PASS.

- [ ] **Step 6: Commit analysis updates**

Run:

```bash
git add scripts/analyze-meeting-performance.swift Tests/MeetingAgentCoreTests/MeetingPerformanceAnalysisScriptTests.swift
git commit -m "feat: count persisted final caption translations"
```

---

### Task 6: Add Latest Meeting Failure-Mode Fixture And Full Verification

**Files:**
- Modify: `Tests/MeetingAgentCoreTests/CaptionTranslationSchedulerTests.swift`
- Modify: `Tests/MeetingAgentCoreTests/MeetingPerformanceAnalysisScriptTests.swift`

- [ ] **Step 1: Add scheduler fixture test matching the latest meeting failure mode**

Add this test to `CaptionTranslationSchedulerTests`:

```swift
func testLatestMeetingFinalCompletionPatternAttachesOrPersistsInsteadOfStale() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("caption-translation-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let eventsURL = root.appendingPathComponent("performance-events.jsonl")
    let longFinalText = String(repeating: "planning owner timeline risk ", count: 20).trimmingCharacters(in: .whitespaces)
    var originalStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
    originalStore.upsert(hardSealedTurn(id: "deepgram-transcribe-stream-26.38", text: longFinalText, sourceLocale: "en-US", targetLocale: "zh-CN"))
    let provider = RecordingTextTranslationProvider(translations: ["deepgram-transcribe-stream-26.38": "完整上下文翻译"])
    var persisted: [(String, String)] = []
    let scheduler = CaptionTranslationScheduler(
        provider: provider,
        performanceEventLogger: PerformanceEventLogger(url: eventsURL),
        persistTranslation: { target, text, _ in
            persisted.append((target.primarySourceSegmentID, text))
            return true
        },
        configuration: CaptionTranslationSchedulerConfiguration(draftDebounceNanoseconds: 0, maxConcurrentTranslationRequests: 1)
    )

    let update = try XCTUnwrap(await scheduler.translationUpdates(for: originalStore).first)
    var reshapedStore = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "zh-CN")
    var reshaped = draftTurn(id: "deepgram-transcribe-stream-42.43", text: "short current text", sourceLocale: "en-US", targetLocale: "zh-CN")
    reshaped.id = "current-merged-turn"
    reshaped.sourceSegmentIDs = ["deepgram-transcribe-stream-26.38", "deepgram-transcribe-stream-42.43"]
    reshapedStore.upsert(reshaped)

    let outcome = scheduler.apply(update, to: &reshapedStore)

    XCTAssertTrue(outcome == .rebound(originalTurnID: "deepgram-transcribe-stream-26.38", reboundTurnID: "current-merged-turn") || outcome == .persisted(segmentID: "deepgram-transcribe-stream-26.38"))
    let events = try readEvents(from: eventsURL)
    XCTAssertFalse(events.contains { $0.event == "caption_translation_stale" && $0.metadata["reason"] == "final_no_longer_current" })
    XCTAssertTrue(events.contains { $0.event == "caption_translation_attached" || $0.event == "caption_translation_persisted" })
}
```

- [ ] **Step 2: Run latest-meeting fixture test**

Run:

```bash
swift test --filter CaptionTranslationSchedulerTests/testLatestMeetingFinalCompletionPatternAttachesOrPersistsInsteadOfStale
```

Expected: PASS.

- [ ] **Step 3: Run focused suites**

Run:

```bash
swift test --filter CaptionTranslationSchedulerTests
swift test --filter LiveCaptionPipelineTests
swift test --filter MeetingPerformanceAnalysisScriptTests
```

Expected: PASS.

- [ ] **Step 4: Run full verification**

Run:

```bash
make test
```

Expected: PASS with the coverage gate.

- [ ] **Step 5: Analyze the latest meeting again**

Run:

```bash
swift scripts/analyze-meeting-performance.swift "$HOME/Library/Application Support/MeetingAgent/Meetings/CC0E70A1-CBF5-402E-82C0-3F0A7530DA22/performance-events.jsonl"
```

Expected on the original log: still shows the old 0% final attached result because historical events do not contain new persisted/rebound events. Use this command to confirm the script remains backward-compatible. The new fixture tests prove how the same failure mode is handled after code changes.

- [ ] **Step 6: Commit final verification fixture**

Run:

```bash
git add Tests/MeetingAgentCoreTests/CaptionTranslationSchedulerTests.swift Tests/MeetingAgentCoreTests/MeetingPerformanceAnalysisScriptTests.swift
git commit -m "test: cover latest meeting final translation stale pattern"
```

---

## Self-Review

- Spec coverage: final stable identity is covered by Task 1; rebind attach by Task 2; persist-only success by Task 3; replay/flush draft suppression by Task 4; analysis metrics by Task 5; latest meeting validation by Task 6.
- Placeholder scan: no `TBD`, `TODO`, or open-ended "handle edge cases" steps remain.
- Type consistency: `CaptionTranslationAttachmentTarget`, `CaptionTranslationApplyOutcome`, `finalTranslationUpdates`, `publishedVisibleText`, and the persistence closure are introduced before later tasks use them.
- Scope check: this remains one implementation plan because all tasks serve one pipeline outcome: final translation reliability with measurable draft waste improvements. The full `TranslationUnit` model remains out of scope.
