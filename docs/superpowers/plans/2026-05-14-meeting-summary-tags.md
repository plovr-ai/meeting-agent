# Meeting Summary Tags Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add structured, agent-generated meeting summary tags and show them as hoverable chips in the Summary UI.

**Architecture:** Store tags directly on `MeetingSummary` as backward-compatible structured data. Extend the OpenRouter summary JSON contract to return freeform insight tags, render them in summary Markdown, and display them in the macOS Summary panel with native hover help. Keep tags out of `MeetingKnowledge` so they remain meeting-level metadata rather than durable knowledge facts.

**Tech Stack:** Swift 5.9, SwiftUI, XCTest, OpenRouter JSON mode.

---

## File Map

- Modify `Sources/MeetingAgentCore/MeetingSummary.swift`: add `MeetingSummaryTag`, add `MeetingSummary.tags`, decode missing tags as `[]`, and render tags in Markdown.
- Modify `Sources/MeetingAgentCore/OpenRouterMeetingSummaryProvider.swift`: include tags in prompt and payload decoding, preserve empty tags on failure.
- Modify `Sources/MeetingAgentApp/MainWindowView.swift`: render Summary tag chips with `.help(...)` hover text.
- Modify `Tests/MeetingAgentCoreTests/MeetingSummaryTests.swift`: encode/decode tags and legacy default coverage.
- Modify `Tests/MeetingAgentCoreTests/MeetingSummaryProviderTests.swift`: provider tags, failed summary tags, and Markdown tags.
- Modify `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`: source-level coverage for tag chips and hover help.

## Task 1: Summary Tag Model And Markdown

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingSummary.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingSummaryTests.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingSummaryProviderTests.swift`

- [ ] **Step 1: Write the failing tests**

Add `tags` to `testMeetingSummaryEncodesAndDecodes`, assert legacy JSON decodes `tags == []`, and add `testMarkdownRendererIncludesTagsWithConfidenceAndRationale` using a `MeetingSummaryTag(label:rationale:confidence:sourceSegmentIDs:)`.

- [ ] **Step 2: Run tests to verify RED**

Run:

```bash
swift test --filter MeetingSummaryTests
swift test --filter MeetingSummaryProviderTests/testMarkdownRendererIncludesTagsWithConfidenceAndRationale
```

Expected: compile failure because `MeetingSummaryTag` and `MeetingSummary.tags` do not exist.

- [ ] **Step 3: Implement model and renderer**

Add `MeetingSummaryTag`, add defaulted `tags: [MeetingSummaryTag] = []` to `MeetingSummary`, decode missing tags as `[]`, and render a `## Tags` Markdown section after Key Topics. Format confidence with `Int((tag.confidence * 100).rounded())`; include rationale only when nonblank.

- [ ] **Step 4: Run tests to verify GREEN**

Run:

```bash
swift test --filter MeetingSummaryTests
swift test --filter MeetingSummaryProviderTests/testMarkdownRendererIncludesTagsWithConfidenceAndRationale
```

Expected: tests pass.

## Task 2: OpenRouter Summary Tags

**Files:**
- Modify: `Sources/MeetingAgentCore/OpenRouterMeetingSummaryProvider.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingSummaryProviderTests.swift`

- [ ] **Step 1: Write failing provider tests**

In `testOpenRouterProviderBuildsRequestAndParsesSummary`, add a `tags` item to the fake JSON response and assert `label`, `rationale`, `confidence`, `sourceSegmentIDs`, plus prompt text containing `tags` and `2-4`. In the failed-configuration test, assert `summary.tags == []`.

- [ ] **Step 2: Run tests to verify RED**

Run:

```bash
swift test --filter MeetingSummaryProviderTests
```

Expected: failure because provider payload does not decode or pass through tags yet.

- [ ] **Step 3: Implement provider schema and failure behavior**

Update the system message to include `tags` and require 2-4 freeform insight tags with `label`, `rationale`, `confidence`, and `sourceSegmentIDs`. Pass `tags: payload.tags` to `MeetingSummary`, pass `tags: []` in `failedSummary`, and make `OpenRouterSummaryPayload` decode missing tags as `[]`.

- [ ] **Step 4: Run provider tests to verify GREEN**

Run:

```bash
swift test --filter MeetingSummaryProviderTests
```

Expected: tests pass.

## Task 3: Summary Tag Chips With Hover Help

**Files:**
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift`
- Test: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

- [ ] **Step 1: Write failing UI source test**

Add `testSummaryOverviewRendersTagChipsWithHoverHelp`, asserting the source contains `SummaryTagChipsView(tags: summary.tags)`, `private struct SummaryTagChipsView`, `CommandCenterChip(title: tag.label`, `.help(helpText(for: tag))`, `Confidence: \(confidencePercent(for: tag))%`, and `Evidence: \(tag.sourceSegmentIDs.count) segments`.

- [ ] **Step 2: Run test to verify RED**

Run:

```bash
swift test --filter MainWindowViewLayoutTests/testSummaryOverviewRendersTagChipsWithHoverHelp
```

Expected: failure because the tag chip view is not implemented.

- [ ] **Step 3: Implement tag chips and hover help**

In `phaseSummary`, render `SummaryTagChipsView(tags: summary.tags)` after the Summary eyebrow when tags are present. Add `SummaryTagChipsView` near `SummaryListView`; it should filter blank labels, render `CommandCenterChip(title: tag.label, tint: CommandCenterPalette.primary, filled: false)`, and attach `.help(helpText(for: tag))`. Tooltip lines should include label, optional rationale, `Confidence: N%`, and `Evidence: N segments`.

- [ ] **Step 4: Run UI source test to verify GREEN**

Run:

```bash
swift test --filter MainWindowViewLayoutTests/testSummaryOverviewRendersTagChipsWithHoverHelp
```

Expected: test passes.

## Task 4: Integration Verification

**Files:**
- Modify tests as needed only if earlier tasks reveal constructor call sites missed by compile checks.

- [ ] **Step 1: Run focused summary and UI tests**

Run:

```bash
swift test --filter MeetingSummaryTests
swift test --filter MeetingSummaryProviderTests
swift test --filter MainWindowViewLayoutTests/testSummaryOverviewRendersTagChipsWithHoverHelp
```

Expected: all focused tests pass.

- [ ] **Step 2: Run required project test gate**

Run:

```bash
make test
```

Expected: all tests pass and coverage gate remains above 95%.

- [ ] **Step 3: Review diff**

Run:

```bash
git diff --stat
git diff -- Sources/MeetingAgentCore/MeetingSummary.swift Sources/MeetingAgentCore/OpenRouterMeetingSummaryProvider.swift Sources/MeetingAgentApp/MainWindowView.swift Tests/MeetingAgentCoreTests/MeetingSummaryTests.swift Tests/MeetingAgentCoreTests/MeetingSummaryProviderTests.swift Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift
```

Expected: diff is limited to summary tags, provider schema, Markdown rendering, and Summary UI chips.

