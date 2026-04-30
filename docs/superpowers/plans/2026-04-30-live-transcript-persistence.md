# Live Transcript Persistence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build active-recording transcript persistence that avoids full artifact rewrites for every live segment and translation update.

**Architecture:** Add a focused `RecordingTranscriptPersistenceStore` that owns active in-memory transcript state, JSONL mutation logging, recovery, debounced snapshots, and forced final flushes. Wire `MeetingRecorder` and live caption translation persistence to this active store while keeping `TranscriptFileWriter` as the final artifact renderer and legacy helper.

**Tech Stack:** Swift 5.9, Foundation file APIs, XCTest, existing `TranscriptSegmentAccumulator`, `TranscriptFileWriter`, `MeetingRecorder`, and `LiveCaptionPipeline`.

---

### Task 1: Extend Transcript Mutation Semantics

**Files:**
- Modify: `Sources/MeetingAgentCore/TranscriptSegmentAccumulator.swift`
- Test: `Tests/MeetingAgentCoreTests/TranscriptSegmentAccumulatorTests.swift`

- [ ] Add a `translationPatch(segmentID:text:targetLocale:isFinal:)` case to `TranscriptSegmentUpdate`.
- [ ] Implement accumulator support that updates the matching segment translation fields in memory.
- [ ] Return the patched segment ID in `changedSegmentIDs`.
- [ ] Add tests for successful patch and missing-segment no-op behavior.
- [ ] Run `swift test --filter TranscriptSegmentAccumulatorTests`.

### Task 2: Add Recording Transcript Persistence Store

**Files:**
- Create: `Sources/MeetingAgentCore/RecordingTranscriptPersistenceStore.swift`
- Test: `Tests/MeetingAgentCoreTests/RecordingTranscriptPersistenceStoreTests.swift`

- [ ] Define a Codable JSONL event wrapper for segment updates.
- [ ] Initialize from `transcript.json`, then replay `transcript-events.jsonl`.
- [ ] Append every mutation to `transcript-events.jsonl` immediately.
- [ ] Keep `TranscriptDocument` canonical in memory.
- [ ] Snapshot through `TranscriptFileWriter.replace(...)` only when forced or the configured interval has elapsed.
- [ ] Add tests for no immediate text rewrite, debounced snapshot, forced flush, translation patch, and recovery.
- [ ] Run `swift test --filter RecordingTranscriptPersistenceStoreTests`.

### Task 3: Wire Active Store Into MeetingRecorder

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingRecorder.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingRecorderTests.swift`

- [ ] Replace the private sink's direct `TranscriptFileWriter.replace(...)` persistence with `RecordingTranscriptPersistenceStore`.
- [ ] Keep pending UI drain results unchanged.
- [ ] Force `flushSnapshot()` when the sink closes.
- [ ] Add a recorder-level test proving stop writes final `transcript.json` and `transcript.txt`.
- [ ] Run `swift test --filter MeetingRecorderTests`.

### Task 4: Route Active Caption Translation Patches

**Files:**
- Modify: `Sources/MeetingAgentCore/SpeechTranscriptionProvider.swift`
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] Add an optional translation-patch capability without breaking existing `TranscriptUpdateSink` conformers.
- [ ] Make `MeetingRecorder` expose a method that patches active transcript translation if an active sink exists.
- [ ] In `MeetingAgentViewModel.makeLiveCaptionPipeline`, try the active recorder patch before falling back to `TranscriptFileWriter.updateSegmentTranslation(...)`.
- [ ] Add or update tests so active recording translation persistence does not require full artifact rewrite per translation.
- [ ] Run focused affected tests.

### Task 5: Full Verification and Commit

**Files:**
- Verify all modified source and test files.

- [ ] Run `swift build --product MeetingAgentApp`.
- [ ] Run `make test`.
- [ ] Inspect `git diff`.
- [ ] Commit implementation with `feat: buffer active transcript persistence (#85)`.
