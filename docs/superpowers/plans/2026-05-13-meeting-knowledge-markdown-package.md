# Meeting Knowledge Markdown Package Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Export completed meetings as a three-file Markdown knowledge package: `meeting.md`, `transcript.md`, and `knowledge.md`.

**Architecture:** Add focused core models and renderers in `MeetingKnowledgePackage.swift`, then expose a synchronous package export through `MeetingExportService`. The first milestone renders knowledge from existing summaries and typed internal items so the external package stays Markdown-only.

**Tech Stack:** Swift 5.9, XCTest, existing `MeetingRecord`, `MeetingSummary`, `TranscriptDocument`, and `MeetingExportService`.

---

### Task 1: Markdown Renderers And Models

**Files:**
- Create: `Sources/MeetingAgentCore/MeetingKnowledgePackage.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingKnowledgePackageTests.swift`

- [ ] **Step 1: Write failing renderer tests**

Add tests covering `meeting.md`, `transcript.md`, and `knowledge.md` rendering with stable frontmatter, sections, IDs, fields, empty sections, and evidence links.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MeetingKnowledgePackageTests`

Expected: fail because `MeetingKnowledgePackageMarkdownRenderer` and related models do not exist.

- [ ] **Step 3: Implement minimal models and renderer**

Create `MeetingKnowledgePackage.swift` with:

- `MeetingKnowledgeConfidence`
- `MeetingKnowledgeEvidence`
- `MeetingKnowledgeItem`
- `MeetingKnowledge`
- `MeetingKnowledgePackage`
- `MeetingKnowledgePackageMarkdownRenderer`

The renderer must produce deterministic Markdown for all three files.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MeetingKnowledgePackageTests`

Expected: pass.

### Task 2: Export Service Integration

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingExportService.swift`
- Modify: `Tests/MeetingAgentCoreTests/MeetingExportServiceTests.swift`

- [ ] **Step 1: Write failing export tests**

Add tests proving `exportKnowledgePackage(for:summary:knowledge:to:)` writes exactly `meeting.md`, `transcript.md`, and `knowledge.md`, fails when transcript is missing, and renders a knowledge failure note when requested.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MeetingExportServiceTests`

Expected: fail because the export method does not exist.

- [ ] **Step 3: Implement package export**

Add a synchronous export method that reads structured transcript segments, creates the destination directory, renders all three Markdown files, and writes them atomically.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MeetingExportServiceTests`

Expected: pass.

### Task 3: Summary-To-Knowledge Fallback

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingKnowledgePackage.swift`
- Modify: `Tests/MeetingAgentCoreTests/MeetingKnowledgePackageTests.swift`

- [ ] **Step 1: Write failing summary conversion tests**

Add tests proving decisions, actions, open questions, risks, and key topics from `MeetingSummary` can seed `knowledge.md` with evidence from `sourceSegmentIDs` when a separate knowledge provider is not available.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MeetingKnowledgePackageTests`

Expected: fail because summary conversion does not exist.

- [ ] **Step 3: Implement summary conversion**

Add a small `MeetingKnowledgeExtractor.fromSummary(_:segments:)` helper that maps:

- summary key topics to facts
- summary risks to judgments
- summary decisions to decisions
- summary action items to actions
- summary open questions to open questions

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MeetingKnowledgePackageTests`

Expected: pass.

### Task 4: Full Verification

**Files:**
- All touched files

- [ ] **Step 1: Run focused tests**

Run:

```sh
swift test --filter MeetingKnowledgePackageTests
swift test --filter MeetingExportServiceTests
```

Expected: both pass.

- [ ] **Step 2: Run required suite**

Run: `make test`

Expected: all tests and coverage gate pass.

- [ ] **Step 3: Review diff**

Run: `git diff --stat` and `git diff --check`.

Expected: no whitespace errors, changes limited to package implementation, tests, and this plan.
