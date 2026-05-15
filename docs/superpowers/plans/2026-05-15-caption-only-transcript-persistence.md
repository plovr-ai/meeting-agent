# Caption-Only Transcript Persistence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove redundant `transcript.txt` persistence from new realtime meeting flows while preserving on-demand text export from `CaptionDocument`.

**Architecture:** New meetings store only `transcript.json` for transcript state. Active recording and retry paths save `CaptionDocument` snapshots directly; UI and exports render text from that document when needed. `TranscriptFileWriter` remains for legacy isolated tests but leaves the realtime persistence boundary.

**Tech Stack:** Swift 5.9, SwiftPM, XCTest, existing `CaptionDocument`, `MeetingTranscriptStore`, `TranscriptRepository`, `make test`.

---

### Task 1: Stop Creating New `transcript.txt` Metadata

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingStore.swift`
- Modify: `Tests/MeetingAgentCoreTests/MeetingStoreTests.swift`

- [ ] **Step 1: Write failing tests**

Update the create-meeting test to expect `record.transcriptURL == nil` and `record.transcriptJSONURL?.lastPathComponent == "transcript.json"`.

- [ ] **Step 2: Run focused test**

Run: `swift test --filter MeetingStoreTests`
Expected: failure because `MeetingStore.createMeeting` still sets `transcriptURL`.

- [ ] **Step 3: Implement**

In `MeetingStore.createMeeting`, set `transcriptURL: nil` and keep `transcriptJSONURL`.

- [ ] **Step 4: Verify**

Run: `swift test --filter MeetingStoreTests`
Expected: pass.

### Task 2: Make Active Segment Persistence Caption-Only

**Files:**
- Modify: `Sources/MeetingAgentCore/RecordingTranscriptPersistenceStore.swift`
- Modify: `Sources/MeetingAgentCore/MeetingRecorder.swift`
- Modify: `Tests/MeetingAgentCoreTests/RecordingTranscriptPersistenceStoreTests.swift`
- Modify: `Tests/MeetingAgentCoreTests/MeetingRecorderTests.swift`

- [ ] **Step 1: Write failing tests**

Change `RecordingTranscriptPersistenceStoreTests` so fixtures pass a `transcriptJSONURL` or directory, and assert `transcript.txt` is not created after upsert, forced snapshot, close, replaceAll, and plain-text failure updates.

- [ ] **Step 2: Run focused tests**

Run: `swift test --filter RecordingTranscriptPersistenceStoreTests`
Expected: failure from old initializer/signature and text-file assertions.

- [ ] **Step 3: Implement caption-only store**

Update `RecordingTranscriptPersistenceStore` to accept `transcriptJSONURL`. Initialize from `MeetingTranscriptStore.readDocument(from:)`, convert that caption document to a `TranscriptDocument` for the accumulator, replay existing events, and write only encoded `CaptionDocument` snapshots to `transcriptJSONURL`.

- [ ] **Step 4: Update recorder sink**

Change `RecordingTranscriptUpdateSink` to initialize from `transcriptJSONURL` or the meeting directory instead of `transcriptURL`. The active recorder should start transcription when `transcriptJSONURL != nil`, while still passing a scratch URL to provider APIs that still require one.

- [ ] **Step 5: Verify**

Run: `swift test --filter RecordingTranscriptPersistenceStoreTests`
Run: `swift test --filter MeetingRecorderTests`
Expected: pass.

### Task 3: Remove Retry and Edit Writes to Rendered Text

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Modify: `Sources/MeetingAgentCore/WhisperTranscriptionProvider.swift`
- Modify: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`
- Modify: `Tests/MeetingAgentCoreTests/WhisperTranscriptionProviderTests.swift`

- [ ] **Step 1: Write failing tests**

Add or update tests so retry transcription succeeds when `record.transcriptURL == nil` and only `transcriptJSONURL` exists. Update edit tests to assert no `transcript.txt` is created after speaker or segment edits.

- [ ] **Step 2: Run focused tests**

Run: `swift test --filter MeetingAgentViewModelTests`
Expected: failure where retry and edit paths still require or write `transcriptURL`.

- [ ] **Step 3: Implement retry**

In retry flow, require `audioURL` and `transcriptJSONURL`. For Deepgram retry, save `document.captionDocument` through `transcriptRepository`. For provider retry paths that return segment updates, route final segments into a caption document and save it without `FileBackedTranscriptUpdateSink`.

- [ ] **Step 4: Implement edit persistence**

Rename `saveCaptionDocumentAndRenderedText` to `saveCaptionDocument` and remove the `transcriptURL` write.

- [ ] **Step 5: Verify**

Run: `swift test --filter MeetingAgentViewModelTests`
Run: `swift test --filter WhisperTranscriptionProviderTests`
Expected: pass or only unrelated pre-existing failures.

### Task 4: Update UI Readiness and Export Conditions

**Files:**
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift`
- Modify: `Sources/MeetingAgentApp/TodayAgendaView.swift`
- Modify: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

- [ ] **Step 1: Write failing source/layout tests**

Update tests that guard transcript export/readiness to assert source does not disable export solely on `meeting.transcriptURL == nil`.

- [ ] **Step 2: Implement UI checks**

Change export transcript enablement and agenda readiness to use `transcriptJSONURL` or existing artifact snapshot state.

- [ ] **Step 3: Verify**

Run: `swift test --filter MainWindowViewLayoutTests`
Expected: pass.

### Task 5: Architecture Guard and Full Verification

**Files:**
- Modify: `Tests/MeetingAgentCoreTests/TranscriptConsumptionArchitectureTests.swift`
- Possibly modify: `Tests/MeetingAgentCoreTests/TranscriptSegmentAccumulatorTests.swift`

- [ ] **Step 1: Add architecture guard**

Add a source-level regression that active realtime files do not contain `TranscriptFileWriter.readDocument`, `FileBackedTranscriptUpdateSink`, or direct `transcript.txt` writes in `RecordingTranscriptPersistenceStore` / `MeetingRecorder`.

- [ ] **Step 2: Run focused guards**

Run: `swift test --filter TranscriptConsumptionArchitectureTests`
Expected: pass after implementation.

- [ ] **Step 3: Run required verification**

Run: `MEETING_AGENT_COVERAGE_SCRATCH_PATH=/tmp/meeting-agent-issue-144-coverage make test`
Expected: pass with coverage gate.

