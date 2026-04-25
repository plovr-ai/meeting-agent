# Product Readiness Export Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add testable meeting export and readiness report support for Phase 1E validation.

**Architecture:** Core owns artifact-aware export generation through `MeetingExportService`. `MeetingRecord` stores a backward-compatible `summaryURL`, and the SwiftUI app delegates export/copy actions through `MeetingAgentViewModel` so UI code stays thin.

**Tech Stack:** Swift 5.9, Swift Package Manager, XCTest, SwiftUI/AppKit on macOS.

---

### Task 1: Meeting Record Summary Artifact

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingRecord.swift`
- Modify: `Sources/MeetingAgentCore/MeetingStore.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingRecordTests.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingStoreTests.swift`

- [ ] Add optional `summaryURL` to `MeetingRecord`, include it in coding keys, initialize it with a default `nil`, and decode it with `decodeIfPresent` so old metadata still loads.
- [ ] Update `MeetingStore.createMeeting` so new records reserve `summary.md`.
- [ ] Add tests asserting `summary.md` is assigned for new meetings and old JSON without `summaryURL` decodes with `nil`.

### Task 2: Core Export Service

**Files:**
- Create: `Sources/MeetingAgentCore/MeetingExportService.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingExportServiceTests.swift`

- [ ] Write failing tests for transcript export, summary export, metadata JSON export, readiness Markdown export, and missing summary errors.
- [ ] Implement `MeetingExportService` with methods:
  - `exportTranscript(for:to:)`
  - `exportSummary(for:to:)`
  - `exportMeetingData(for:to:)`
  - `exportReadinessReport(for:to:)`
  - `summaryText(for:)`
- [ ] Use `TranscriptFileWriter.renderedTranscript` for transcript rendering so structured transcript JSON remains the preferred source of truth.
- [ ] Keep errors explicit through a small public `MeetingExportError`.

### Task 3: View Model Export Actions

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] Inject `MeetingExportService` into `MeetingAgentViewModel`.
- [ ] Add methods for exporting transcript, summary, meeting data, readiness report, and loading summary text for clipboard use.
- [ ] Update `statusText` with success and failure messages that include the failed operation.
- [ ] Test export success and missing-summary failure using temporary destinations.

### Task 4: App UI Hooks

**Files:**
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift`

- [ ] Add an export section to `MeetingDetailView`.
- [ ] Use `NSSavePanel` in the app target to choose export destinations.
- [ ] Use `NSPasteboard` in the app target to copy summary text returned by the view model.
- [ ] Disable summary copy/export when `summaryURL` is missing.

### Task 5: Verify and Commit

**Files:**
- All modified files.

- [ ] Run `swift test`.
- [ ] Run `swift build --product MeetingAgentApp`.
- [ ] Fix any failures caused by the change.
- [ ] Commit the spec, plan, implementation, and tests with `feat: add product readiness exports (#7)`.
