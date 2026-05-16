# Refined Transcript Summary Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ensure stop-and-generate summary waits for post-meeting transcript refinement, falls back clearly, and tells summary providers which transcript source they received.

**Architecture:** Reuse the existing `PostMeetingTranscriptRefining` gate inside `MeetingAgentViewModel`. Add a narrow `MeetingSummaryTranscriptSource` value to `MeetingSummaryInput` so providers and tests can distinguish refined, live, and fallback transcript sources without changing persistence architecture.

**Tech Stack:** Swift 5.9, SwiftUI ViewModel code, XCTest, existing `make test` coverage gate.

---

### Task 1: Summary Input Source Metadata

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingSummary.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingSummaryProviderTests.swift`

- [ ] **Step 1: Write the failing test**

Add a test that constructs `MeetingSummaryInput` with `.fallback(reason:)` and asserts the value is retained. Also construct a legacy-style input without the new argument and assert it defaults to `.live`.

- [ ] **Step 2: Run focused test**

Run: `swift test --filter MeetingSummaryProviderTests`
Expected: FAIL because `transcriptSource` does not exist.

- [ ] **Step 3: Implement metadata**

Add:

```swift
public enum MeetingSummaryTranscriptSource: Equatable {
    case live
    case refined
    case fallback(reason: String)
}
```

Then add `public let transcriptSource: MeetingSummaryTranscriptSource` to `MeetingSummaryInput` with a default `.live` initializer argument.

- [ ] **Step 4: Run focused test**

Run: `swift test --filter MeetingSummaryProviderTests`
Expected: PASS.

### Task 2: ViewModel Refinement Gate Behavior

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] **Step 1: Add test helpers**

Add a fake `PostMeetingTranscriptRefining` that records calls and returns configured success or failure results. Add a summary provider assertion hook that captures `MeetingSummaryInput.transcriptSource` and transcript turn text.

- [ ] **Step 2: Add failing success test**

Create a live transcript with text `Live wording`, configure the fake refiner to return a refined caption document with text `Refined wording`, call `stopRecordingAndGenerateSummary`, and assert the summary provider saw `Refined wording` with `.refined`.

- [ ] **Step 3: Add failing fallback test**

Configure the fake refiner to return a failed record with `failureReason = "Deepgram batch unavailable"` and no caption document. Assert the summary provider saw the live text with `.fallback(reason: "Deepgram batch unavailable")`.

- [ ] **Step 4: Add failing empty transcript test**

Stop and generate summary without live or refined turns. Assert the generated summary status is `.failed` and `statusText` is `Summary failed`.

- [ ] **Step 5: Add failing status-ordering test**

Configure a fake refiner and summary provider that capture status snapshots. Assert the observed sequence includes `Refining transcript`, `Generating summary`, and `Summary generated`.

- [ ] **Step 6: Implement status and source derivation**

Set `statusText = "Refining transcript"` before awaiting refinement in `stopRecordingAndGenerateSummary`. Set `statusText = "Generating summary"` before provider generation. Derive source from `MeetingRecord.transcriptRefinement` in a helper:

```swift
private func summaryTranscriptSource(for meeting: MeetingRecord) -> MeetingSummaryTranscriptSource
```

Return `.refined` for `.refined`, `.fallback(reason:)` for `.failed`, and `.live` otherwise.

- [ ] **Step 7: Pass metadata to provider**

Pass `transcriptSource: summaryTranscriptSource(for: meeting)` when constructing `MeetingSummaryInput`.

- [ ] **Step 8: Run focused ViewModel tests**

Run: `swift test --filter MeetingAgentViewModelTests`
Expected: PASS.

### Task 3: Full Verification And Commit

**Files:**
- Verify changed Swift files and docs.

- [ ] **Step 1: Build**

Run: `swift build --product MeetingAgentApp`
Expected: PASS.

- [ ] **Step 2: Required test entrypoint**

Run: `MEETING_AGENT_COVERAGE_SCRATCH_PATH=/private/tmp/meeting-agent-issue-157-coverage make test`
Expected: PASS.

- [ ] **Step 3: Commit implementation**

Stage only relevant files:

```bash
git add Sources/MeetingAgentCore/MeetingSummary.swift Sources/MeetingAgentCore/MeetingAgentViewModel.swift Tests/MeetingAgentCoreTests/MeetingSummaryProviderTests.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift docs/superpowers/specs/2026-05-16-refined-transcript-summary-gate-design.md docs/superpowers/plans/2026-05-16-refined-transcript-summary-gate.md
git commit -m "feat: gate summaries on transcript refinement (#157)"
```
