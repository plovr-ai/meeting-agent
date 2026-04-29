# Recommended Questions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a context-driven recommended questions module that shows at most two accurate manager questions during a meeting.

**Architecture:** Reuse `MeetingProgressState.suggestedQuestions` as the data path. Generate suggestions deterministically in `DeterministicMeetingProgressAnalyzer`, expose them through `MeetingAgentViewModel`, and conditionally render them in `MainWindowView`.

**Tech Stack:** Swift 5.9, SwiftUI, XCTest, Swift Package Manager.

---

### Task 1: Analyzer Recommendations

**Files:**
- Modify: `Sources/MeetingAgentCore/LiveMeetingCockpit.swift`
- Test: `Tests/MeetingAgentCoreTests/DeterministicMeetingProgressAnalyzerTests.swift`

- [ ] **Step 1: Write failing analyzer tests**

Add tests that prove recommendations are generated from unresolved objectives without `requiredQuestions`, capped at two, and empty when no objective/topic context exists.

- [ ] **Step 2: Run focused analyzer tests**

Run: `swift test --filter DeterministicMeetingProgressAnalyzerTests`

Expected: new tests fail before implementation.

- [ ] **Step 3: Implement deterministic question generation**

Replace the current `requiredQuestions.prefix(3)` logic with a helper that chooses unresolved objectives, then uncovered agenda topics, and emits at most two `FollowUpQuestionSuggestion` values.

- [ ] **Step 4: Re-run analyzer tests**

Run: `swift test --filter DeterministicMeetingProgressAnalyzerTests`

Expected: PASS.

### Task 2: View Model Surface

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] **Step 1: Write failing view-model test**

Add a test that refreshes meeting progress and asserts `viewModel.recommendedQuestions` contains the generated recommendation.

- [ ] **Step 2: Add published derived property**

Expose `recommendedQuestions` as a public computed property returning `meetingProgressState?.suggestedQuestions.prefix(2)` or `[]`.

- [ ] **Step 3: Run focused view-model test**

Run: `swift test --filter MeetingAgentViewModelTests/testRefreshMeetingProgressPublishesRecommendedQuestions`

Expected: PASS.

### Task 3: Insights UI

**Files:**
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift`
- Test: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

- [ ] **Step 1: Add layout guard**

Assert that `MainWindowView.swift` wires `recommendedQuestions`, defines `RecommendedQuestionsPanel`, includes the `Recommended Questions` heading, and does not include a placeholder empty-state for that panel.

- [ ] **Step 2: Render panel only when non-empty**

Pass `viewModel.recommendedQuestions` into `MeetingDetailView`, `MeetingCommandCenterView`, and `InsightPaneView`. Render `RecommendedQuestionsPanel` before summary/export panels only when the array is non-empty.

- [ ] **Step 3: Run layout test**

Run: `swift test --filter MainWindowViewLayoutTests/testInsightsPaneShowsRecommendedQuestionsOnlyWhenAvailable`

Expected: PASS.

### Task 4: Full Verification and Commit

**Files:**
- All changed implementation, tests, spec, and plan files.

- [ ] **Step 1: Build**

Run: `swift build --product MeetingAgentApp`

Expected: PASS.

- [ ] **Step 2: Unit coverage entrypoint**

Run: `make test`

Expected: PASS.

- [ ] **Step 3: Commit implementation**

Commit all issue-related files with:

```bash
git add Sources/MeetingAgentCore/LiveMeetingCockpit.swift Sources/MeetingAgentCore/MeetingAgentViewModel.swift Sources/MeetingAgentApp/MainWindowView.swift Tests/MeetingAgentCoreTests/DeterministicMeetingProgressAnalyzerTests.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift docs/superpowers/plans/2026-04-29-recommended-questions.md
git commit -m "feat: add recommended questions module (#76)"
```

## Self-Review

- Spec coverage: the plan covers deterministic generation, at-most-two behavior, hidden empty UI, and tests.
- Placeholder scan: no TBD/TODO placeholders remain.
- Type consistency: all steps use existing `FollowUpQuestionSuggestion`, `MeetingProgressState`, and `MeetingAgentViewModel` names.
