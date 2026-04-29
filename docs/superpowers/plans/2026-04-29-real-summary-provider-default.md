# Real Summary Provider Default Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the mock extractive summary provider default and make meeting summaries use the Settings-backed OpenRouter model by default.

**Architecture:** Keep `OpenRouterMeetingSummaryProvider` as the only configurable meeting summary provider. `MeetingAgentViewModel` builds it from `SpeechTranscriptionConfiguration`, using environment variables only as fallback credentials. Tests inject deterministic providers for view-model behavior that should not require network access.

**Tech Stack:** Swift 5.9, Swift Package Manager, XCTest.

---

### Task 1: Lock In OpenRouter Default Selection

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] **Step 1: Write default-provider assertions**

Add tests that call `MeetingAgentViewModel.summaryProvider(for:environment:)` with a configured `SpeechTranscriptionConfiguration` and assert:

```swift
XCTAssertEqual(provider.providerName, "openrouter:openai/gpt-4.1-mini")
```

Also pass `["MEETING_AGENT_SUMMARY_PROVIDER": "extractive-local"]` and assert the provider still starts with `openrouter`.

- [ ] **Step 2: Implement OpenRouter-only selection**

Remove the summary-provider environment switch. Always return:

```swift
OpenRouterMeetingSummaryProvider(configuration: OpenRouterChatConfiguration(
    apiKey: SpeechTranscriptionConfiguration.normalized(configuration.openRouterAPIKey)
        ?? environment["MEETING_AGENT_OPENROUTER_API_KEY"],
    model: SpeechTranscriptionConfiguration.normalized(configuration.hostedSummaryModelID)
        ?? environment["MEETING_AGENT_OPENROUTER_MODEL"]
))
```

- [ ] **Step 3: Run focused tests**

Run:

```bash
swift test --filter MeetingAgentViewModelTests
```

Expected: PASS.

### Task 2: Remove Extractive Provider

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingSummary.swift`
- Modify: `Tests/MeetingAgentCoreTests/MeetingSummaryProviderTests.swift`
- Modify: `Tests/MeetingAgentCoreTests/MeetingSummaryTests.swift`
- Modify: `AGENTS.md`

- [ ] **Step 1: Delete provider and heuristic tests**

Remove `ExtractiveMeetingSummaryProvider` and its private `SummarySegment` helper. Delete tests that instantiate it directly.

- [ ] **Step 2: Update remaining fixture provider names**

Use OpenRouter-style provider strings in summary rendering and serialization fixtures:

```swift
provider: "openrouter:openai/gpt-4.1-mini"
```

- [ ] **Step 3: Update docs for current defaults**

Change AGENTS guidance so the default summary provider is documented as OpenRouter, configured through app Settings or `MEETING_AGENT_OPENROUTER_API_KEY` and `MEETING_AGENT_OPENROUTER_MODEL`.

- [ ] **Step 4: Run focused provider tests**

Run:

```bash
swift test --filter MeetingSummaryProviderTests --filter MeetingSummaryTests
```

Expected: PASS.

### Task 3: Full Verification And Commit

**Files:**
- All changed source, tests, and docs.

- [ ] **Step 1: Run required verification**

Run:

```bash
make test
```

Expected: PASS with coverage enforcement.

- [ ] **Step 2: Commit implementation**

Run:

```bash
git add AGENTS.md docs/superpowers/specs/2026-04-29-real-summary-provider-default-design.md docs/superpowers/plans/2026-04-29-real-summary-provider-default.md Sources/MeetingAgentCore/MeetingAgentViewModel.swift Sources/MeetingAgentCore/MeetingSummary.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift Tests/MeetingAgentCoreTests/MeetingSummaryProviderTests.swift Tests/MeetingAgentCoreTests/MeetingSummaryTests.swift
git commit -m "feat: use real summary provider by default (#67)"
```

Expected: commit succeeds.

