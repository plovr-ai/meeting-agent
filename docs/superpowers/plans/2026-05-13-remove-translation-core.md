# Remove Translation Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove translation from the active meeting agent product while keeping old transcript JSON readable.

**Architecture:** Make the app transcription-first: configuration, settings, live captions, replay, and exports no longer instantiate translation providers or render translated text. Keep compatibility at the transcript schema boundary by decoding legacy translation fields without using them in runtime projection.

**Tech Stack:** Swift 5.9, SwiftUI, XCTest, Swift Package Manager, Makefile `make test`.

---

### Task 1: Add Removal Guard Tests

**Files:**
- Modify: `Tests/MeetingAgentCoreTests/SpeechTranscriptionConfigurationTests.swift`
- Modify: `Tests/MeetingAgentCoreTests/SettingsViewLayoutTests.swift`
- Modify: `Tests/MeetingAgentCoreTests/LiveCaptionPipelineTests.swift`
- Modify: `Tests/MeetingAgentCoreTests/TranscriptSegmentTests.swift`

- [ ] Add tests proving settings source does not contain `Hosted Translation Model`, configuration validation ignores translation model fields, live caption pipeline does not surface translated text from legacy fields, and transcript decoding still accepts legacy translation fields.
- [ ] Run targeted tests and confirm they fail before implementation.

### Task 2: Strip Configuration and Settings Translation Surface

**Files:**
- Modify: `Sources/MeetingAgentCore/SpeechTranscriptionConfiguration.swift`
- Modify: `Sources/MeetingAgentCore/BilingualPipelineFactory.swift`
- Modify: `Sources/MeetingAgentCore/PrimaryChainPreflight.swift`
- Modify: `Sources/MeetingAgentApp/SettingsView.swift`
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift`

- [ ] Remove translation model/provider/profile controls from current settings and status text.
- [ ] Ensure OpenRouter validation only depends on transcription/summary use, not translation settings.
- [ ] Keep meeting language as the source language for transcription and summary target language.

### Task 3: Make Live Captions Caption-Only

**Files:**
- Modify: `Sources/MeetingAgentCore/LiveMeetingCockpit.swift`
- Modify: `Sources/MeetingAgentCore/LiveCaptionPipeline.swift`
- Modify: `Sources/MeetingAgentCore/RealtimeCaptionSession.swift`
- Modify: `Sources/MeetingAgentCore/CaptionTurnAssembler.swift`
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`

- [ ] Remove translation provider dependencies from live caption construction.
- [ ] Remove translation scheduling, overlay publication, and runtime finalization from the view model.
- [ ] Stop hydrating `translatedText` into visible live caption turns.
- [ ] Keep caption health and meeting progress behavior unchanged.

### Task 4: Delete Translation Modules and Tests

**Files:**
- Delete translation-specific source files under `Sources/MeetingAgentCore/`.
- Delete translation-specific test files under `Tests/MeetingAgentCoreTests/`.

- [ ] Delete standalone translation providers, schedulers, runtime, stores, persistence, unit builders, replay backfill, and bilingual orchestrator files.
- [ ] Delete tests that cover only removed translation behavior.
- [ ] Use compiler errors and `rg` to clean residual references.

### Task 5: Verify

**Files:**
- All modified Swift source and tests.

- [ ] Run `swift test` for targeted tests while iterating.
- [ ] Run `make test` from the repository root before handoff.
- [ ] Check `git status --short` and report user-owned pre-existing changes separately from this work.
