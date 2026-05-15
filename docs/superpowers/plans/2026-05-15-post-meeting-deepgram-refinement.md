# Post-Meeting Deepgram Refinement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Deepgram-only post-meeting batch transcript refinement with settings, persistence metadata, and safe fallback to live captions.

**Architecture:** Add batch provider/model settings, a focused Deepgram batch provider, and a refinement service that runs after recording stops. The service only replaces the in-memory and persisted transcript after a successful non-empty refined caption document is produced.

**Tech Stack:** Swift 5.9, SwiftUI Settings view, XCTest, existing `CaptionDocument`, `MeetingRecord`, `MeetingAgentViewModel`, `TranscriptRepository`, and Deepgram HTTP conventions.

---

### Task 1: Batch Settings

**Files:**
- Modify: `Sources/MeetingAgentCore/SpeechTranscriptionConfiguration.swift`
- Modify: `Sources/MeetingAgentCore/SpeechProviderCatalog.swift`
- Modify: `Sources/MeetingAgentApp/SettingsView.swift`
- Test: `Tests/MeetingAgentCoreTests/SpeechTranscriptionConfigurationTests.swift`
- Test: `Tests/MeetingAgentCoreTests/SettingsViewLayoutTests.swift`

- [ ] Add `defaultBatchTranscriptionProviderID = "deepgram-batch-transcribe"` and `defaultBatchTranscriptionModelID = "nova-3"`.
- [ ] Add stored properties `batchTranscriptionProviderID` and `batchTranscriptionModelID`.
- [ ] Decode missing legacy values to the defaults.
- [ ] Encode the new fields.
- [ ] Update `saveSpeechConfiguration` sanitization to preserve the batch fields.
- [ ] Add `SpeechProviderCatalog.batchTranscriptionModelOptions` with Nova 3 and Nova 2.
- [ ] Add a Settings panel named `Post-Meeting Refinement` with pickers for provider and model.
- [ ] Run focused tests:

```bash
swift test --filter SpeechTranscriptionConfigurationTests
swift test --filter SettingsViewLayoutTests
```

### Task 2: Refinement Metadata

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingRecord.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingRecordTests.swift`

- [ ] Add `TranscriptRefinementStatus` with `notStarted`, `running`, `refined`, and `failed`.
- [ ] Add `TranscriptRefinementMetadata` with provider ID, model ID, status, failure reason, duration seconds, and updated timestamp.
- [ ] Add optional `transcriptRefinement` to `MeetingRecord`.
- [ ] Decode missing metadata as nil for old records.
- [ ] Add tests for encoding and legacy decoding.

### Task 3: Deepgram Batch Provider

**Files:**
- Create: `Sources/MeetingAgentCore/DeepgramBatchTranscriptionProvider.swift`
- Test: `Tests/MeetingAgentCoreTests/DeepgramBatchTranscriptionProviderTests.swift`

- [ ] Define `DeepgramBatchTranscriptionProviding`.
- [ ] Implement Deepgram prerecorded `/v1/listen` request construction with `model`, `language`, `diarize=true`, `utterances=true`, `smart_format=true`, and `punctuate=true`.
- [ ] Parse utterance output into final `TranscriptSegment` values with speaker IDs.
- [ ] Test URL query construction and diarized utterance parsing using a custom `URLProtocol`.

### Task 4: Refinement Service

**Files:**
- Create: `Sources/MeetingAgentCore/PostMeetingTranscriptRefinementService.swift`
- Test: `Tests/MeetingAgentCoreTests/PostMeetingTranscriptRefinementServiceTests.swift`

- [ ] Add a service method that accepts record, live document, and configuration.
- [ ] Fail without replacing live transcript when audio URL is nil, missing, unreadable, provider throws, or output is empty.
- [ ] Convert successful batch segments to a provider-marked `CaptionDocument`.
- [ ] Generate stable `Speaker N` labels by first appearance order.
- [ ] Save refined document through `TranscriptRepository` only on success.
- [ ] Save `MeetingRecord.transcriptRefinement` metadata for success and failure.

### Task 5: ViewModel Integration

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] Inject `PostMeetingTranscriptRefining`.
- [ ] After `stopRecording` succeeds, run refinement for the stopped record.
- [ ] On success, update `selectedMeetingSessionState.transcript` and `liveCaptionTurns` for the selected meeting.
- [ ] On failure, refresh meeting metadata but keep the current transcript state.
- [ ] Ensure `stopRecordingAndGenerateSummary` runs summary after refinement so summary consumes refined in-memory transcript when available.
- [ ] Add focused ViewModel tests for success and failure fallback.

### Task 6: Verification And Commit

**Files:**
- All changed files

- [ ] Run `swift build --product MeetingAgentApp`.
- [ ] Run `make test` with a unique coverage scratch path if another worktree is using coverage.
- [ ] Review the diff for #155 overlap, especially `MeetingRecord`, `MeetingRecorder`, and `MeetingAgentViewModel`.
- [ ] Commit implementation with:

```bash
git add <changed files>
git commit -m "feat: refine completed transcripts with Deepgram (#156)"
```
