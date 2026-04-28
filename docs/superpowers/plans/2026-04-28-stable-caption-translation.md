# Stable Caption Translation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent translated live caption text from disappearing while a same-speaker merged turn is being retranslated.

**Architecture:** Keep the fix at the `LiveCaptionStore` merge boundary, where the blank state is created. Preserve existing translated text while setting translation health back to pending, and rely on the existing view-model translation key to request and attach the updated full-turn translation.

**Tech Stack:** Swift 5.9, Swift Package Manager, XCTest.

---

### Task 1: Store-Level Regression

**Files:**
- Modify: `Tests/MeetingAgentCoreTests/LiveCaptionStoreTests.swift`
- Modify: `Sources/MeetingAgentCore/LiveMeetingCockpit.swift`

- [ ] **Step 1: Write the failing test**

Rename `testMergingSameSpeakerClearsStaleTranslation` to `testMergingSameSpeakerPreservesTranslationWhileRetranslating` and assert that after appending a second same-speaker final segment, `translatedText` remains the previous visible translation and `translationHealth` is `.pending`.

- [ ] **Step 2: Run focused test**

Run: `swift test --filter LiveCaptionStoreTests/testMergingSameSpeakerPreservesTranslationWhileRetranslating`

Expected before implementation: fail because `mergedTurn` clears `translatedText`.

- [ ] **Step 3: Implement minimal store change**

In `LiveCaptionStore.mergedTurn`, remove the assignment that sets `merged.translatedText = nil`. Keep `merged.translationHealth = .pending`.

- [ ] **Step 4: Run focused test**

Run: `swift test --filter LiveCaptionStoreTests/testMergingSameSpeakerPreservesTranslationWhileRetranslating`

Expected after implementation: pass.

### Task 2: View-Model Regression

**Files:**
- Modify: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] **Step 1: Add an async provider gate**

Extend `ViewModelFakeTextTranslationProvider` with an optional `delayNanoseconds` so the test can observe the in-flight pending state before translation finishes.

- [ ] **Step 2: Write the regression test**

Add `testExpandingTranslatedCaptionKeepsVisibleTranslationUntilFullTurnTranslationCompletes`. The test should translate `segment-1`, append `segment-2` from the same speaker, call `drainRecordingFrames()`, assert the merged turn still displays the first translation while `translationHealth` is pending, then wait for the delayed translation and assert the full-turn translation replaces it.

- [ ] **Step 3: Run focused test**

Run: `swift test --filter MeetingAgentViewModelTests/testExpandingTranslatedCaptionKeepsVisibleTranslationUntilFullTurnTranslationCompletes`

Expected after Task 1: pass.

### Task 3: Verification And Commit

**Files:**
- Modified source, test, spec, and plan files.

- [ ] **Step 1: Run full verification**

Run: `make test`

Expected: pass.

- [ ] **Step 2: Review local diff**

Run: `git diff --stat` and `git diff`

Expected: only issue #35 source, tests, spec, and plan files changed.

- [ ] **Step 3: Commit**

Run:

```bash
git add docs/superpowers/specs/2026-04-28-stable-caption-translation-design.md docs/superpowers/plans/2026-04-28-stable-caption-translation.md Sources/MeetingAgentCore/LiveMeetingCockpit.swift Tests/MeetingAgentCoreTests/LiveCaptionStoreTests.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift
git commit -m "feat: keep caption translation visible while updating (#35)"
```

