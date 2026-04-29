# Remove Realtime Speech Translation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the unused realtime speech translation chain while preserving STT-driven live captions and caption text translation.

**Architecture:** Delete the independent audio-to-translation path instead of keeping it disconnected. `MeetingRecorder` remains responsible for capture, WAV writing, and STT frame delivery. `MeetingAgentViewModel` remains responsible for live caption state, caption text translation scheduling, meeting progress, summaries, and exports.

**Tech Stack:** Swift 5.9, Swift Package Manager, SwiftUI, XCTest.

---

### Task 1: Remove Realtime Recorder Hook

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingRecorder.swift`
- Modify: `Tests/MeetingAgentCoreTests/MeetingRecorderTests.swift`

- [ ] Remove `public weak var realtimeFrameConsumer`.
- [ ] Remove `deliverFramesToRealtimeConsumerForTesting(_:)`.
- [ ] Remove the call to `deliverFramesToRealtimeConsumerForTesting(frames)` from `drainFrames()`.
- [ ] Delete MeetingRecorder tests that exist only to validate realtime frame consumer delivery.
- [ ] Run `swift test --filter MeetingRecorderTests`.

### Task 2: Remove View-Model Realtime Translation State

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Modify: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] Remove published realtime speech translation properties from the view model.
- [ ] Remove `RealtimeTranslationController` injection and recorder wiring from the initializer.
- [ ] Remove `startRealtimeTranslation(targetLocale:)`, `stopRealtimeTranslation()`, and `syncRealtimeTranslationState()`.
- [ ] Remove `attachRealtimeTranslationsToLiveCaptions()`, `realtimeTranslationAttachmentCount(for:)`, and realtime-status-driven health updates.
- [ ] Remove tests that validate realtime translation start/stop and order-based caption attachment.
- [ ] Keep tests that validate caption text translation through `LiveCaptionTranslationAdapter` and OpenRouter.
- [ ] Run `swift test --filter MeetingAgentViewModelTests`.

### Task 3: Remove Realtime Translation Types and Provider

**Files:**
- Delete: `Sources/MeetingAgentCore/RealtimeTranslation.swift`
- Delete: `Sources/MeetingAgentCore/RealtimeTranslationController.swift`
- Delete: `Sources/MeetingAgentCore/OpenAIRealtimeTranslationProvider.swift`
- Delete: `Tests/MeetingAgentCoreTests/RealtimeTranslationControllerTests.swift`
- Delete: `Tests/MeetingAgentCoreTests/OpenAIRealtimeTranslationProviderTests.swift`
- Delete: `Tests/MeetingAgentCoreTests/RealtimeTranslationStoreTests.swift`

- [ ] Delete the source files for the unused speech translation chain.
- [ ] Delete the dedicated tests for those files.
- [ ] Search for remaining `RealtimeTranslation`, `LiveTranslationTurn`, `RealtimeFrameConsumer`, and `OpenAIRealtimeSpeechTranslationProvider` references.
- [ ] Run `swift build --product MeetingAgentApp`.

### Task 4: Remove Settings Configuration

**Files:**
- Modify: `Sources/MeetingAgentApp/SettingsView.swift`
- Modify: `Sources/MeetingAgentCore/SpeechTranscriptionConfiguration.swift`
- Modify: settings/configuration tests as needed.

- [ ] Remove settings UI controls that only configure realtime speech translation.
- [ ] Preserve OpenAI realtime transcription fields, because they configure the STT provider path.
- [ ] Remove persisted configuration fields only if they are exclusively for realtime speech translation.
- [ ] Update source-layout tests that assert realtime speech translation controls are absent.
- [ ] Run `swift test --filter SettingsViewLayoutTests`.

### Task 5: Full Verification and Commit

**Files:**
- All files changed above.

- [ ] Run `make test`.
- [ ] Search for stale removed-chain terms with `rg -n "RealtimeTranslation|realtimeTranslation|LiveTranslationTurn|RealtimeFrameConsumer|OpenAIRealtimeSpeechTranslationProvider" Sources Tests`.
- [ ] Stage only related files.
- [ ] Commit with `feat: remove realtime speech translation chain (#88)`.
