# Remove Legacy Transcript Writer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove production legacy transcript writer fallback paths while preserving structured transcript intermediates for provider and migration logic.

**Architecture:** Realtime providers publish transcript updates only through explicit sinks, and existing-audio retry providers return `TranscriptDocument` values that callers save as `CaptionDocument`. `TranscriptFileWriter` may remain as a legacy bridge helper, but production callers must not instantiate it implicitly.

**Tech Stack:** Swift 5.9, SwiftPM, XCTest, macOS Speech, Deepgram/OpenAI realtime provider adapters, Whisper CLI adapter.

---

### Task 1: Change Existing-Audio Provider Contract

**Files:**
- Modify: `Sources/MeetingAgentCore/SpeechTranscriptionProvider.swift`
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Modify: `Sources/MeetingAgentCore/WhisperTranscriptionProvider.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`
- Test: `Tests/MeetingAgentCoreTests/WhisperTranscriptionProviderTests.swift`

- [ ] Update `SpeechTranscriptionProvider.transcribeExistingAudio(context:)` to return `TranscriptDocument`.
- [ ] Update default implementation to throw as before, with return type `TranscriptDocument`.
- [ ] Update `MeetingAgentViewModel.retryTranscription` so non-Deepgram providers save the returned document through `transcriptRepository.saveCaptionDocument(Self.captionDocument(from: document.segments), for: record)`.
- [ ] Delete creation, defer cleanup, and readback of `provider-transcript.legacy`.
- [ ] Update Whisper retry implementation to return the structured document it already builds.
- [ ] Run focused tests for retry transcription and Whisper existing-audio behavior.

### Task 2: Remove Realtime Writer Fallbacks

**Files:**
- Modify: `Sources/MeetingAgentCore/DeepgramTranscriptionProvider.swift`
- Modify: `Sources/MeetingAgentCore/OpenAIRealtimeTranscriptionProvider.swift`
- Modify: `Sources/MeetingAgentCore/SystemSpeechTranscriber.swift`
- Test: `Tests/MeetingAgentCoreTests/DeepgramStreamingTranscriptionProviderTests.swift`
- Test: `Tests/MeetingAgentCoreTests/OpenAIRealtimeTranscriptionProviderTests.swift`
- Test: `Tests/MeetingAgentCoreTests/SystemSpeechTranscriberTests.swift`

- [ ] Change Deepgram streaming startup to avoid creating `TranscriptFileWriter` when `speechEventSink` is nil.
- [ ] Let Deepgram reconciliation feed `TranscriptUpdateSink` directly and keep final in memory when no sink exists.
- [ ] Change OpenAI realtime startup to avoid creating `TranscriptFileWriter` when no sink exists.
- [ ] Require System Speech live output to use `TranscriptUpdateSink` in the active path; keep test-only writer injection out of production live environment.
- [ ] Update tests so realtime assertions read sink events or caption documents, not transcript.txt-style files.

### Task 3: Quarantine Legacy File Writer Helpers

**Files:**
- Modify: `Sources/MeetingAgentCore/TranscriptSegmentAccumulator.swift`
- Modify: `Tests/MeetingAgentCoreTests/TranscriptSegmentAccumulatorTests.swift`
- Modify: `Tests/MeetingAgentCoreTests/TranscriptConsumptionArchitectureTests.swift`

- [ ] Remove `FileBackedTranscriptUpdateSink` from active source if production callers no longer need it.
- [ ] If tests need equivalent behavior, keep it in test support only under an explicit legacy helper name.
- [ ] Strengthen architecture tests to grep `Sources` for `TranscriptFileWriter`, `FileBackedTranscriptUpdateSink`, `provider-transcript.legacy`, `transcript.txt`, `renderedTranscript`, and `TranscriptFileWriter.readDocument`.

### Task 4: Verify and Commit

**Files:**
- Modify only files touched by the implementation.

- [ ] Run `swift build --product MeetingAgentApp`.
- [ ] Run focused XCTest filters for provider, retry, and architecture tests.
- [ ] Run `make test`.
- [ ] Run the issue-required grep over `Sources`.
- [ ] Commit the implementation with a message that closes #152.
