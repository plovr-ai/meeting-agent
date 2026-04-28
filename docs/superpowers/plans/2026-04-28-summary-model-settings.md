# Summary Model Settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add independent OpenRouter summary model configuration in Settings and use it for meeting summary generation.

**Architecture:** Store the summary model beside the existing transcription and translation settings in `SpeechTranscriptionConfiguration`. Expose curated summary model options from `BilingualPipelineFactory`, render a separate Settings picker, and pass the configured model into `OpenRouterMeetingSummaryProvider` from `MeetingAgentViewModel`.

**Tech Stack:** Swift 5.9, SwiftUI, Swift Package Manager, XCTest.

---

### Task 1: Configuration Model And Settings Picker

**Files:**
- Modify: `Sources/MeetingAgentCore/SpeechTranscriptionConfiguration.swift`
- Modify: `Sources/MeetingAgentCore/BilingualPipelineFactory.swift`
- Modify: `Sources/MeetingAgentApp/SettingsView.swift`
- Test: `Tests/MeetingAgentCoreTests/SpeechTranscriptionConfigurationTests.swift`
- Test: `Tests/MeetingAgentCoreTests/SettingsViewLayoutTests.swift`

- [ ] **Step 1: Write failing configuration and layout assertions**

Add assertions that:

```swift
XCTAssertEqual(configuration.hostedSummaryModelID, "openai/gpt-4.1-mini")
XCTAssertEqual(BilingualPipelineFactory.hostedSummaryModelOptions.first?.id, "openai/gpt-4.1-mini")
```

Update round-trip test setup with:

```swift
hostedSummaryModelID: "google/gemini-2.5-flash",
```

Add decode fallback assertion:

```swift
XCTAssertEqual(configuration.hostedSummaryModelID, "openai/gpt-4.1-mini")
```

Add layout assertion:

```swift
XCTAssertTrue(source.contains("Picker(\"Hosted Summary Model\""))
```

- [ ] **Step 2: Run focused failing tests**

Run:

```bash
swift test --filter SpeechTranscriptionConfigurationTests --filter SettingsViewLayoutTests
```

Expected: FAIL because `hostedSummaryModelID` and the summary picker do not exist yet.

- [ ] **Step 3: Implement summary model configuration**

In `SpeechTranscriptionConfiguration`, add:

```swift
public static let defaultHostedSummaryModelID = "openai/gpt-4.1-mini"
public var hostedSummaryModelID: String
```

Add an initializer parameter:

```swift
hostedSummaryModelID: String = defaultHostedSummaryModelID,
```

Normalize it in `init`:

```swift
self.hostedSummaryModelID = Self.normalized(
    hostedSummaryModelID,
    fallback: Self.defaultHostedSummaryModelID
) ?? Self.defaultHostedSummaryModelID
```

Add it to `CodingKeys` and decode with default fallback.

- [ ] **Step 4: Implement summary model options and Settings picker**

In `BilingualPipelineFactory`, add:

```swift
public static let hostedSummaryModelOptions: [ModelOption] = [
    ModelOption(id: "openai/gpt-4.1-mini", displayName: "GPT-4.1 Mini"),
    ModelOption(id: "google/gemini-2.5-flash", displayName: "Gemini 2.5 Flash")
]
```

In `SettingsView`, add a picker in the OpenRouter panel:

```swift
Picker("Hosted Summary Model", selection: $draft.hostedSummaryModelID) {
    ForEach(BilingualPipelineFactory.hostedSummaryModelOptions) { model in
        Text(model.displayName).tag(model.id)
    }
}
```

- [ ] **Step 5: Run focused tests**

Run:

```bash
swift test --filter SpeechTranscriptionConfigurationTests --filter SettingsViewLayoutTests
```

Expected: PASS.

### Task 2: Summary Provider Uses Configured Model

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] **Step 1: Write failing model-selection test**

Add or update view-model summary coverage so a configuration with:

```swift
hostedTranslationModelID: "google/gemini-2.5-flash",
hostedSummaryModelID: "openai/gpt-4.1-mini",
openRouterAPIKey: "test-key"
```

generates an OpenRouter summary whose provider is:

```swift
XCTAssertEqual(summary.provider, "openrouter:openai/gpt-4.1-mini")
```

Use `MEETING_AGENT_SUMMARY_PROVIDER=openrouter` and a fake `OpenRouterChatClient`.

- [ ] **Step 2: Run the failing focused test**

Run:

```bash
swift test --filter MeetingAgentViewModelTests
```

Expected: FAIL because the view model still gets the summary model only from `MEETING_AGENT_OPENROUTER_MODEL`.

- [ ] **Step 3: Pass configuration into summary provider creation**

Update `generateSummary` to call a provider factory that accepts `speechConfiguration`. Update the static factory to prefer:

```swift
configuration.hostedSummaryModelID
```

and fall back to:

```swift
environment["MEETING_AGENT_OPENROUTER_MODEL"]
```

Keep the OpenRouter API key resolution behavior unchanged.

- [ ] **Step 4: Run focused tests**

Run:

```bash
swift test --filter MeetingAgentViewModelTests
```

Expected: PASS.

### Task 3: Full Verification And Commit

**Files:**
- All files changed in Tasks 1 and 2.

- [ ] **Step 1: Run full unit verification**

Run:

```bash
make test
```

Expected: PASS with coverage enforcement.

- [ ] **Step 2: Commit implementation**

Run:

```bash
git add docs/superpowers/specs/2026-04-28-summary-model-settings-design.md docs/superpowers/plans/2026-04-28-summary-model-settings.md Sources/MeetingAgentCore/SpeechTranscriptionConfiguration.swift Sources/MeetingAgentCore/BilingualPipelineFactory.swift Sources/MeetingAgentCore/MeetingAgentViewModel.swift Sources/MeetingAgentApp/SettingsView.swift Tests/MeetingAgentCoreTests/SpeechTranscriptionConfigurationTests.swift Tests/MeetingAgentCoreTests/SettingsViewLayoutTests.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift
git commit -m "feat: add summary model settings (#57)"
```

Expected: commit succeeds.

