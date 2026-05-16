# Transcript Quality Metadata Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist and expose transcript quality source metadata across transcript projection, refinement fallback, summary input, readiness export, and the meeting UI.

**Architecture:** Store durable quality metadata on `CaptionDocument`, derive trustworthy metrics during projection, and pass the result through existing in-memory `MeetingSessionState` consumers. Refinement success and failure are the only paths that override the default live transcript source.

**Tech Stack:** Swift 5.9, Swift Package Manager, XCTest, SwiftUI source-layout tests.

---

### Task 1: Persist Transcript Quality Metadata

**Files:**
- Modify: `Sources/MeetingAgentCore/CaptionDocument.swift`
- Test: `Tests/MeetingAgentCoreTests/CaptionDocumentTests.swift`

- [ ] Add `TranscriptQualitySource`, `TranscriptQualityMetrics`, and `TranscriptQualityMetadata` beside `CaptionDocument`.
- [ ] Add optional `qualityMetadata` to `CaptionDocument` with Codable compatibility for legacy JSON.
- [ ] Add tests that encode/decode metadata and decode legacy documents without metadata.

### Task 2: Project Quality For Consumers

**Files:**
- Modify: `Sources/MeetingAgentCore/TranscriptConsumptionView.swift`
- Test: `Tests/MeetingAgentCoreTests/TranscriptConsumptionViewTests.swift`

- [ ] Extend `TranscriptConsumptionQuality` with `source` and `fallbackReason`.
- [ ] Recompute metrics from turns during projection while preserving persisted source and reason.
- [ ] Add tests for live-only defaults, refinement failure reason, unknown speakers, drafts, and empty final turns.

### Task 3: Mark Refinement Outcomes

**Files:**
- Modify: `Sources/MeetingAgentCore/PostMeetingTranscriptRefinementService.swift`
- Test: `Tests/MeetingAgentCoreTests/PostMeetingTranscriptRefinementServiceTests.swift`

- [ ] Mark refined documents as `postProcessed`.
- [ ] On failure, save the preserved live document with `refinementFailed` or `fallbackLive` metadata and the failure reason.
- [ ] Add tests for successful refinement and failed fallback persistence.

### Task 4: Carry Quality Into Product Surfaces

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingArtifactSnapshot.swift`
- Modify: `Sources/MeetingAgentCore/MeetingExportService.swift`
- Modify: `Sources/MeetingAgentCore/OpenRouterMeetingSummaryProvider.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingArtifactSnapshotTests.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingSummaryProviderTests.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] Add a quality label/details to `MeetingArtifactSnapshot`.
- [ ] Add a `Transcript Quality` section to readiness reports.
- [ ] Add transcript quality context to the OpenRouter summary prompt.
- [ ] Add focused tests for each product surface.

### Task 5: Display Quality In The Meeting UI

**Files:**
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift`
- Test: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

- [ ] Pass `artifactSnapshot` quality text into `TranscriptPaneView`.
- [ ] Render compact transcript quality chips near the transcript metadata.
- [ ] Add a source-layout guard for the visible labels.

### Task 6: Verify And Commit

**Files:**
- All modified files.

- [ ] Run focused tests for changed areas serially.
- [ ] Run `make test` with a worktree-specific coverage scratch path if the default scratch is busy.
- [ ] Commit only issue-related files.
