# Current User Speaker Label Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a high-confidence `Me` speaker label path for the current user's voice profile.

**Architecture:** Extend speaker identity profiles with a subject role, keep the resolver conservative about ambiguous matches, and reuse the existing ViewModel speaker identity projection so `Me` reaches live captions and active transcript state.

**Tech Stack:** Swift 5.9, XCTest, existing MeetingAgentCore speaker identification and caption projection types.

---

### Task 1: Current User Profile Semantics

**Files:**
- Modify: `Sources/MeetingAgentCore/SpeakerIdentification.swift`
- Test: `Tests/MeetingAgentCoreTests/SpeakerIdentificationTests.swift`
- Test: `Tests/MeetingAgentCoreTests/SpeakerProfileStoreTests.swift`

- [ ] Add `SpeakerProfileSubjectRole` with `participant` and `currentUser`.
- [ ] Add `subjectRole` to `SpeakerProfile`, defaulting decoded legacy profiles to `participant`.
- [ ] Make confirmed current-user profiles display as `Me`.
- [ ] Add resolver tests proving high-confidence current-user matches return `Me` and ambiguous current-user matches do not.
- [ ] Run `swift test --filter SpeakerIdentificationTests` and `swift test --filter SpeakerProfileStoreTests`.

### Task 2: Realtime Projection And Persistence

**Files:**
- Test: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] Add a ViewModel regression test that applies a current-user speaker identity resolution and asserts the visible live caption speaker label is `Me`.
- [ ] In the same test, assert the active in-memory `CaptionDocument` stores `speakerLabel == "Me"` while preserving the provider speaker id.
- [ ] Run `swift test --filter MeetingAgentViewModelTests`.

### Task 3: Verification And Commit

**Files:**
- All changed files

- [ ] Run targeted speaker and ViewModel tests serially.
- [ ] Run `swift build --product MeetingAgentApp`.
- [ ] Run `make test`.
- [ ] Review `git diff --check`.
- [ ] Commit the feature with `Closes #155`.
