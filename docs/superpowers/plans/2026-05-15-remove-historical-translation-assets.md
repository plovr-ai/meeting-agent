# Remove Historical Translation Assets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove historical translation and bilingual architecture from the active product while preserving caption-only meeting behavior.

**Architecture:** Delete translation-specific Swift modules and their direct tests, then repair configuration, scripts, fixtures, and guard tests around the caption-only product surface. Keep legacy tolerance only where old artifact files may exist beside current transcript/caption documents.

**Tech Stack:** Swift 5.9, SwiftUI, XCTest, Swift Package Manager, Makefile `make test`.

---

### Task 1: Add Removal Guard Coverage

**Files:**
- Modify: `Tests/MeetingAgentCoreTests/SpeechTranscriptionConfigurationTests.swift`
- Modify: `Tests/MeetingAgentCoreTests/SettingsViewLayoutTests.swift`
- Modify: `Tests/MeetingAgentCoreTests/CaptureRegressionFixtureScriptTests.swift`
- Modify: `Tests/MeetingAgentCoreTests/MeetingPerformanceAnalysisScriptTests.swift`

- [ ] Add or update tests proving configuration and settings no longer expose bilingual pipeline or hosted translation provider selection.
- [ ] Add or update script tests proving new fixture capture does not require `translation-results.jsonl`.
- [ ] Add or update performance analyzer tests so caption-only analysis does not mention translation E2E metrics.
- [ ] Run focused tests and confirm they describe the desired caption-only behavior.

### Task 2: Remove Product Configuration Translation Surface

**Files:**
- Modify: `Sources/MeetingAgentCore/SpeechTranscriptionConfiguration.swift`
- Modify: `Sources/MeetingAgentCore/PrimaryChainPreflight.swift`
- Modify: `Sources/MeetingAgentApp/SettingsView.swift`
- Modify: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`
- Modify: `Tests/MeetingAgentCoreTests/PrimaryChainPreflightTests.swift`
- Modify: `Tests/MeetingAgentCoreTests/SpeechTranscriptionConfigurationTests.swift`

- [ ] Remove bilingual pipeline profile and hosted translation provider configuration fields, defaults, validation, persistence store keys, and test expectations.
- [ ] Keep Codable compatibility only if needed for older settings payloads; decoded legacy translation keys must be ignored.
- [ ] Run focused configuration and preflight tests.

### Task 3: Delete Translation and Bilingual Source Modules

**Files:**
- Delete: `Sources/MeetingAgentCore/BilingualProvider.swift`
- Delete: `Sources/MeetingAgentCore/BilingualPipelineFactory.swift`
- Delete: `Sources/MeetingAgentCore/BilingualPipelineProfile.swift`
- Delete: `Sources/MeetingAgentCore/BilingualSubtitlePipelineOrchestrator.swift`
- Delete: `Sources/MeetingAgentCore/BilingualTranscript.swift`
- Delete: `Sources/MeetingAgentCore/BilingualTranscriptStore.swift`
- Delete: `Sources/MeetingAgentCore/OpenRouterBilingualProviders.swift`
- Delete: `Sources/MeetingAgentCore/AccurateTranslationScheduler.swift`
- Delete: `Sources/MeetingAgentCore/TranslationContextStore.swift`
- Delete: `Sources/MeetingAgentCore/TranslationExperienceModels.swift`
- Delete: `Sources/MeetingAgentCore/TranslationResultPersistenceStore.swift`
- Delete: `Sources/MeetingAgentCore/TranslationResultStore.swift`
- Delete: `Sources/MeetingAgentCore/TranslationUnitBuilder.swift`

- [ ] Delete direct translation/bilingual modules.
- [ ] Use `rg` and compiler errors to remove residual references from active source.

### Task 4: Delete Translation-Only Tests and Repair Remaining Tests

**Files:**
- Delete translation-only tests under `Tests/MeetingAgentCoreTests`.
- Modify caption, fixture, view-model, and configuration tests that referenced removed configuration fields only as setup noise.

- [ ] Delete tests for deleted modules.
- [ ] Update remaining tests to assert caption-only behavior without translation fixtures.
- [ ] Run focused tests for modified files.

### Task 5: Simplify Tooling and Fixtures

**Files:**
- Modify: `scripts/check-unit-coverage.swift`
- Modify: `scripts/capture-regression-fixture.swift`
- Modify: `scripts/analyze-meeting-performance.swift`
- Modify fixture tests and fixture data only where required by the scripts.

- [ ] Remove deleted files from coverage exclusions.
- [ ] Stop copying/decoding `translation-results.jsonl` in regression fixture capture.
- [ ] Remove translation E2E metrics and flags from meeting performance analysis.
- [ ] Run script-focused tests.

### Task 6: Final Verification and Commit

**Files:**
- All modified files.

- [ ] Run final forbidden-symbol grep over active source, tests, and scripts.
- [ ] Run `swift build --product MeetingAgentApp`.
- [ ] Run `make test` with a worktree-specific coverage scratch path if needed.
- [ ] Commit the implementation with `Closes #151`.
