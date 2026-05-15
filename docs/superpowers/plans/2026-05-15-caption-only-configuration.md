# Caption-Only Configuration Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove translation and bilingual concepts from the active caption-only settings and transcript UI surface while preserving legacy config decoding.

**Architecture:** Treat old bilingual and translation settings as migration-only decode inputs. Keep active configuration, settings UI, and transcript rendering named around transcription, summary, and captions. Leave legacy translation artifacts untouched.

**Tech Stack:** Swift 5.9, SwiftUI, XCTest, Swift Package Manager, repository `make test` coverage gate.

---

### Task 1: Make legacy translation configuration decode-only

**Files:**
- Modify: `Sources/MeetingAgentCore/SpeechTranscriptionConfiguration.swift`
- Test: `Tests/MeetingAgentCoreTests/SpeechTranscriptionConfigurationTests.swift`

- [ ] Add tests that decode JSON containing `bilingualPipelineProfileID`, `translationExecutionMode`, `localTranslationProviderID`, `hostedTranslationProviderID`, and `hostedTranslationModelID`.
- [ ] Add tests that encoding `SpeechTranscriptionConfiguration.default` omits those legacy keys.
- [ ] Replace first-class translation config properties with decode-only coding keys and legacy compatibility comments.
- [ ] Run `swift test --filter SpeechTranscriptionConfigurationTests`.

### Task 2: Save only active caption-era settings

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] Update settings save tests to assert transcription, summary, and credentials persist.
- [ ] Remove derived bilingual profile logic from `saveSpeechConfiguration`.
- [ ] Delete the now-unused derived profile helper.
- [ ] Run `swift test --filter MeetingAgentViewModelTests/testSaveSpeechConfiguration`.

### Task 3: Remove bilingual profile settings dependency

**Files:**
- Modify: `Sources/MeetingAgentApp/SettingsView.swift`
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift`
- Test: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

- [ ] Remove the `profiles` property and initializer argument from `SettingsView`.
- [ ] Stop passing `BilingualPipelineFactory.builtInProfiles` when constructing `SettingsView`.
- [ ] Replace the meeting header pipeline display helper with a transcription-chain display helper.
- [ ] Update layout tests to assert settings no longer receives built-in bilingual profiles.

### Task 4: Rename caption-only transcript UI types

**Files:**
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift`
- Test: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

- [ ] Rename `BilingualTranscriptGroup` to `CaptionTranscriptGroup`.
- [ ] Rename `BilingualTranscriptBlock` to `CaptionTranscriptBlock`.
- [ ] Update source-layout tests that reference those private view names.
- [ ] Run `swift test --filter MainWindowViewLayoutTests`.

### Task 5: Verify and commit

**Files:**
- All modified source, test, and plan/spec files.

- [ ] Run `swift build --product MeetingAgentApp`.
- [ ] Run required `make test`, using a worktree-specific `MEETING_AGENT_COVERAGE_SCRATCH_PATH` if the shared coverage scratch is busy.
- [ ] Review `git diff --check` and `git status --short`.
- [ ] Commit relevant files with `feat: clean caption-only configuration surface (#146)`.
