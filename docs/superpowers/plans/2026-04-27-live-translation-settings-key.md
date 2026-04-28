# Live Translation Settings Key Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Settings-managed OpenAI Realtime API key for Live Translation.

**Architecture:** Store the key on `SpeechTranscriptionConfiguration`, render it in `SettingsView`, and have `MeetingAgentViewModel` pass it into `RealtimeTranslationConfiguration` when starting Live Translation. If the field is empty, preserve the existing `MEETING_AGENT_OPENAI_API_KEY` fallback.

**Tech Stack:** Swift Package, SwiftUI, XCTest.

---

### Task 1: Configuration Persistence

**Files:**
- Modify: `Sources/MeetingAgentCore/SpeechTranscriptionConfiguration.swift`
- Test: `Tests/MeetingAgentCoreTests/SpeechTranscriptionConfigurationTests.swift`

- [x] **Step 1: Write the failing tests**

Add tests that assert `openAIRealtimeAPIKey` is normalized, encoded, decoded, and absent-compatible.

- [x] **Step 2: Run focused tests to verify failure**

Run: `swift test --filter SpeechTranscriptionConfigurationTests`

Expected: FAIL because `SpeechTranscriptionConfiguration` has no `openAIRealtimeAPIKey` member.

- [x] **Step 3: Implement configuration storage**

Add optional `openAIRealtimeAPIKey`, include it in defaults, initializer, coding keys, and decode path using `decodeIfPresent`.

- [x] **Step 4: Re-run focused tests**

Run: `swift test --filter SpeechTranscriptionConfigurationTests`

Expected: PASS.

### Task 2: Settings UI

**Files:**
- Modify: `Sources/MeetingAgentApp/SettingsView.swift`
- Test: `Tests/MeetingAgentCoreTests/SettingsViewLayoutTests.swift`

- [x] **Step 1: Write the failing layout test**

Assert Settings includes `Section("Live Translation")`, `SecureField("OpenAI Realtime API Key"`, and an `openAIRealtimeAPIKeyBinding`.

- [x] **Step 2: Run focused tests to verify failure**

Run: `swift test --filter SettingsViewLayoutTests`

Expected: FAIL because the field is not present.

- [x] **Step 3: Implement Settings field**

Add a dedicated Live Translation section and binding that normalizes empty strings to `nil`.

- [x] **Step 4: Re-run focused tests**

Run: `swift test --filter SettingsViewLayoutTests`

Expected: PASS.

### Task 3: Live Translation Startup

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [x] **Step 1: Write the failing behavior test**

Assert `startRealtimeTranslation()` passes the configured `openAIRealtimeAPIKey` into the realtime provider.

- [x] **Step 2: Run focused tests to verify failure**

Run: `swift test --filter MeetingAgentViewModelTests`

Expected: FAIL because startup still uses environment-only defaults.

- [x] **Step 3: Implement startup configuration**

Resolve the configured key first and pass it to `RealtimeTranslationConfiguration`; use `MEETING_AGENT_OPENAI_API_KEY` when the setting is empty.

- [x] **Step 4: Re-run focused tests**

Run: `swift test --filter MeetingAgentViewModelTests`

Expected: PASS.

### Task 4: Full Verification

**Files:**
- No new files.

- [x] **Step 1: Run full tests**

Run: `swift test`

Expected: PASS.

- [x] **Step 2: Build the app**

Run: `swift build --product MeetingAgentApp`

Expected: PASS.
