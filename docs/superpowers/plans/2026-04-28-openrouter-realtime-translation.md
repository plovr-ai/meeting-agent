# OpenRouter Realtime Translation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automatically translate final diarized live caption turns through OpenRouter using Gemini 2.5 Flash by default.

**Architecture:** Keep translation model selection in `SpeechTranscriptionConfiguration` and `BilingualPipelineFactory`. Use `LiveCaptionTranslationAdapter` as the final-turn translation boundary, and let `MeetingAgentViewModel` schedule OpenRouter translation for pending final caption turns after transcript refreshes.

**Tech Stack:** Swift 5.9, SwiftUI, XCTest, Swift Package Manager.

---

### Task 1: Translation Model Defaults And Settings

**Files:**
- Modify: `Sources/MeetingAgentCore/SpeechTranscriptionConfiguration.swift`
- Modify: `Sources/MeetingAgentCore/BilingualPipelineFactory.swift`
- Modify: `Sources/MeetingAgentApp/SettingsView.swift`
- Modify: `Tests/MeetingAgentCoreTests/SpeechTranscriptionConfigurationTests.swift`
- Modify: `Tests/MeetingAgentCoreTests/SettingsViewLayoutTests.swift`

- [ ] **Step 1: Write failing default and settings tests**

Add assertions that `SpeechTranscriptionConfiguration.default.hostedTranslationModelID` is `google/gemini-2.5-flash`, that Gemini is first in `BilingualPipelineFactory.hostedTranslationModelOptions`, and that `SettingsView.swift` contains `Picker("Hosted Translation Model"`.

- [ ] **Step 2: Run focused tests**

Run: `swift test --filter SpeechTranscriptionConfigurationTests/testDefaultBilingualSettings --filter SettingsViewLayoutTests/testSettingsViewUsesPickersForAllEditableFields`

Expected: fail because the default is still GPT-4.1 Mini and settings intentionally hides the hosted translation model picker.

- [ ] **Step 3: Implement defaults and settings picker**

Change `defaultHostedTranslationModelID` to `google/gemini-2.5-flash`, order `hostedTranslationModelOptions` with Gemini first, and add a hosted translation model picker to the OpenRouter settings panel. Add `ensureHostedTranslationModel()` and call it when saving or changing relevant settings.

- [ ] **Step 4: Run focused tests**

Run: `swift test --filter SpeechTranscriptionConfigurationTests/testDefaultBilingualSettings --filter SettingsViewLayoutTests/testSettingsViewUsesPickersForAllEditableFields`

Expected: pass.

### Task 2: Provider Prompt And Final-Turn Boundary

**Files:**
- Modify: `Sources/MeetingAgentCore/OpenRouterBilingualProviders.swift`
- Modify: `Sources/MeetingAgentCore/LiveMeetingCockpit.swift`
- Modify: `Tests/MeetingAgentCoreTests/OpenRouterBilingualProviderTests.swift`
- Modify: `Tests/MeetingAgentCoreTests/LiveCaptionTranslationAdapterTests.swift`

- [ ] **Step 1: Write failing provider and adapter tests**

Add a test that the OpenRouter translation system prompt asks for natural localized meeting language, intent preservation, JSON-only output, and exact ID preservation. Add a fake-provider call count test proving `LiveCaptionTranslationAdapter.translate` does not call the provider for a partial turn.

- [ ] **Step 2: Run focused tests**

Run: `swift test --filter OpenRouterBilingualProviderTests --filter LiveCaptionTranslationAdapterTests`

Expected: fail until the prompt and partial-turn guard are added.

- [ ] **Step 3: Implement prompt and partial guard**

Update `OpenRouterTextTranslationProvider.messages` system content to specify natural localized phrasing, speaker intent, meeting context, JSON-only output, and exact ID preservation. In `LiveCaptionTranslationAdapter.translate`, return immediately for `!turn.isFinal`.

- [ ] **Step 4: Run focused tests**

Run: `swift test --filter OpenRouterBilingualProviderTests --filter LiveCaptionTranslationAdapterTests`

Expected: pass.

### Task 3: View Model OpenRouter Final Caption Translation

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Modify: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] **Step 1: Write failing view model test**

Add an injectable text translation provider factory to `MeetingAgentViewModel` tests. Verify that after `drainRecordingFrames()` reads a final structured transcript segment, the view model translates the pending final caption through the configured OpenRouter model and attaches translated text to the live caption.

- [ ] **Step 2: Run focused test**

Run: `swift test --filter MeetingAgentViewModelTests/testDrainRecordingFramesTranslatesFinalCaptionsWithConfiguredOpenRouterModel`

Expected: fail because the view model does not schedule OpenRouter text translation.

- [ ] **Step 3: Implement translation scheduling**

Add private state to track in-flight or completed translation keys by turn ID and source text. After `refreshLiveCaptionTurnsFromSelectedMeeting()`, call a helper that builds `OpenRouterTextTranslationProvider` only when hosted translation is OpenRouter and an OpenRouter API key/model exists, then translates final pending turns asynchronously through `LiveCaptionTranslationAdapter`.

- [ ] **Step 4: Run focused test**

Run: `swift test --filter MeetingAgentViewModelTests/testDrainRecordingFramesTranslatesFinalCaptionsWithConfiguredOpenRouterModel`

Expected: pass.

### Task 4: Verification And Commit

**Files:**
- All modified source, test, spec, and plan files.

- [ ] **Step 1: Run full verification**

Run: `make test`

Expected: pass.

- [ ] **Step 2: Review local diff**

Run: `git diff --stat` and `git diff`

Expected: only issue #33 files changed.

- [ ] **Step 3: Commit**

Run:

```bash
git add docs/superpowers/specs/2026-04-28-openrouter-realtime-translation-design.md docs/superpowers/plans/2026-04-28-openrouter-realtime-translation.md Sources/MeetingAgentCore/SpeechTranscriptionConfiguration.swift Sources/MeetingAgentCore/BilingualPipelineFactory.swift Sources/MeetingAgentCore/OpenRouterBilingualProviders.swift Sources/MeetingAgentCore/LiveMeetingCockpit.swift Sources/MeetingAgentCore/MeetingAgentViewModel.swift Sources/MeetingAgentApp/SettingsView.swift Tests/MeetingAgentCoreTests/SpeechTranscriptionConfigurationTests.swift Tests/MeetingAgentCoreTests/SettingsViewLayoutTests.swift Tests/MeetingAgentCoreTests/OpenRouterBilingualProviderTests.swift Tests/MeetingAgentCoreTests/LiveCaptionTranslationAdapterTests.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift
git commit -m "feat: add OpenRouter final caption translation (#33)"
```

Expected: commit created on `feat/issue-33-openrouter-translation`.
