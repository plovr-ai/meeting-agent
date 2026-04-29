# Persist Caption Translations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist translated caption text into meeting artifacts so reopening a meeting does not translate the same caption again.

**Architecture:** Store caption translation cache metadata on `TranscriptSegment`, update it through `TranscriptFileWriter`, and hydrate `LiveCaptionStore` from cached segment translations during transcript replay. Keep cache invalidation tied to source text edits and changed segment content.

**Tech Stack:** Swift 5.9, Swift Package Manager, XCTest, existing `MeetingAgentCore` transcript and view-model types.

---

### Task 1: Add Translation Cache Fields To Transcript Segments

**Files:**
- Modify: `Sources/MeetingAgentCore/TranscriptSegment.swift`
- Test: `Tests/MeetingAgentCoreTests/TranscriptFileWriterTests.swift`

- [ ] Add optional `translatedText`, `translationTargetLocale`, and `translationIsFinal` properties to `TranscriptSegment`.
- [ ] Update the initializer and decoder with nil defaults so legacy transcript JSON decodes.
- [ ] Add a writer test that saves a translated segment, reads it back, and verifies all cache fields.

### Task 2: Add Writer APIs And Cache Invalidation

**Files:**
- Modify: `Sources/MeetingAgentCore/TranscriptFileWriter.swift`
- Test: `Tests/MeetingAgentCoreTests/TranscriptFileWriterTests.swift`

- [ ] Add `TranscriptFileWriter.updateSegmentTranslation(segmentID:text:targetLocale:isFinal:textURL:structuredURL:)`.
- [ ] Preserve existing cache fields when assigning speaker labels.
- [ ] Clear cache fields when `updateSegmentText` changes source text.
- [ ] Preserve cache fields during `upsert` only when the incoming segment has the same id and source text.
- [ ] Run `swift test --filter TranscriptFileWriterTests`.

### Task 3: Persist And Hydrate View-Model Caption Translations

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] Persist successful draft and final caption translations to the selected meeting's structured transcript.
- [ ] During transcript replay, attach cached segment translations to generated live caption turns when target locale matches the current caption target.
- [ ] Mark hydrated final translations final and set the scheduler's draft/final keys so cached turns are treated as already translated.
- [ ] Add a regression that translates once, opens the same meeting in a new view model, and verifies the provider is not called again.
- [ ] Run `swift test --filter MeetingAgentViewModelTests`.

### Task 4: Verify And Commit

**Files:**
- All files changed above.

- [ ] Run `swift build --product MeetingAgentApp`.
- [ ] Run `make test`.
- [ ] Stage only issue-related files.
- [ ] Commit with `feat: persist caption translations (#81)`.
