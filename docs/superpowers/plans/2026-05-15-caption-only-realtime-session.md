# Caption-Only Realtime Session Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove obsolete realtime caption translation APIs and keep active recording caption-only.

**Architecture:** `RealtimeCaptionSession` remains the active recording boundary and only forwards caption operations to `LiveCaptionPipeline`. `LiveCaptionPipeline` keeps caption projection and health snapshots, but no longer owns translation scheduling, result attachment, or backfill state. Tests enforce the boundary with source-level guards and caption-only behavior checks.

**Tech Stack:** Swift 5.9, Swift Package Manager, XCTest, macOS 14.2 package target.

---

### Task 1: Add Boundary Regression Tests

**Files:**
- Modify: `Tests/MeetingAgentCoreTests/LiveCaptionPipelineTests.swift`

- [ ] **Step 1: Add tests near the top of `LiveCaptionPipelineTests`**

Add tests that read source files and assert the active boundary cannot expose or call translation scheduling:

```swift
    func testRealtimeCaptionSessionExposesOnlyCaptionOperations() throws {
        let source = try Self.sourceFile(named: "Sources/MeetingAgentCore/RealtimeCaptionSession.swift")

        XCTAssertFalse(source.contains("scheduleLegacyReplayBackfillTranslations"))
        XCTAssertFalse(source.contains("scheduleLivePendingTranslations"))
        XCTAssertFalse(source.contains("attachTranslationResults"))
        XCTAssertFalse(source.contains("TranslationResult"))
        XCTAssertTrue(source.contains("func apply("))
        XCTAssertTrue(source.contains("func flushCaptionsOnly("))
    }

    func testMeetingAgentViewModelDoesNotCallForbiddenRealtimeTranslationComponents() throws {
        let source = try Self.sourceFile(named: "Sources/MeetingAgentCore/MeetingAgentViewModel.swift")

        XCTAssertFalse(source.contains("scheduleLegacyReplayBackfillTranslations"))
        XCTAssertFalse(source.contains("scheduleLivePendingTranslations"))
        XCTAssertFalse(source.contains("attachTranslationResults"))
        XCTAssertFalse(source.contains("TranslationRuntime"))
        XCTAssertFalse(source.contains("TranslationExperiencePipeline"))
        XCTAssertFalse(source.contains("LiveTranslationScheduler"))
        XCTAssertFalse(source.contains("ReplayTranslationBackfillScheduler"))
    }
```

Add a helper at the bottom of the test class:

```swift
    private static func sourceFile(named relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
```

- [ ] **Step 2: Run the focused tests and verify they fail before implementation**

Run: `swift test --filter LiveCaptionPipelineTests/testRealtimeCaptionSessionExposesOnlyCaptionOperations`

Expected: FAIL because `RealtimeCaptionSession` still contains the translation methods.

Run: `swift test --filter LiveCaptionPipelineTests/testMeetingAgentViewModelDoesNotCallForbiddenRealtimeTranslationComponents`

Expected: PASS or FAIL depending on current source; either result is acceptable before implementation because Task 2 removes any remaining forbidden references.

### Task 2: Remove Translation APIs From Active Caption Pipeline

**Files:**
- Modify: `Sources/MeetingAgentCore/RealtimeCaptionSession.swift`
- Modify: `Sources/MeetingAgentCore/LiveCaptionPipeline.swift`
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`

- [ ] **Step 1: Remove translation forwarding from `RealtimeCaptionSession`**

Delete these methods entirely:

```swift
    func scheduleLegacyReplayBackfillTranslations() async -> LiveCaptionPipelineSnapshot
    func scheduleLivePendingTranslations() async -> LiveCaptionPipelineSnapshot
    func attachTranslationResults(_ results: [TranslationResult]) -> LiveCaptionPipelineSnapshot
```

Keep only:

```swift
    func replacePipeline(_ pipeline: LiveCaptionPipeline)
    func apply(_ result: TranscriptSegmentAccumulationResult) async -> LiveCaptionPipelineSnapshot
    func flushCaptionsOnly(reason: LiveCaptionFreezeReason) -> LiveCaptionPipelineSnapshot
```

- [ ] **Step 2: Remove translation-owned state from `LiveCaptionPipeline`**

Delete `LiveCaptionTranslationMode`, the `translationProvider`, `persistTranslation`, `translationMode`, and `translationBackfillScheduler` stored properties, and remove those parameters from the initializer. Keep `performanceEventLogger` because caption visibility events still use it.

- [ ] **Step 3: Remove scheduling and result attachment APIs from `LiveCaptionPipeline`**

Delete these public methods:

```swift
    public func scheduleLegacyReplayBackfillTranslations() async -> LiveCaptionPipelineSnapshot
    public func scheduleLivePendingTranslations() async -> LiveCaptionPipelineSnapshot
    public func attachTranslationResults(_ results: [TranslationResult], visibleUpdatedAt: Date = Date()) -> LiveCaptionPipelineSnapshot
```

Update `replay(_:)` and `flush(reason:)` so they only replay or flush captions and return a snapshot with translation health idle.

- [ ] **Step 4: Remove private translation scheduling helpers from `LiveCaptionPipeline`**

Delete helpers that only support translation scheduling or projection, including `scheduleFinalTranslationsOnly`, `scheduleLiveTranslations`, `attachTranslationResult`, and translation projection mismatch logging. Keep caption visibility logging.

- [ ] **Step 5: Simplify `MeetingAgentViewModel` pipeline construction**

Remove `realtimeCaptionSessionUsesCaptionTranslationProvider` and any logic that toggles it. Ensure active caption application always uses the caption-only `realtimeCaptionSession.apply(result)` path.

### Task 3: Delete Unreferenced Legacy Translation Runtime Files And Tests

**Files:**
- Delete if unreferenced: `Sources/MeetingAgentCore/TranslationRuntime.swift`
- Delete if unreferenced: `Sources/MeetingAgentCore/TranslationExperiencePipeline.swift`
- Delete if unreferenced: `Sources/MeetingAgentCore/LiveTranslationScheduler.swift`
- Delete if unreferenced: `Sources/MeetingAgentCore/ReplayTranslationBackfillScheduler.swift`
- Delete if unreferenced: `Sources/MeetingAgentCore/ReplayTranslationBackfillPlanner.swift`
- Delete matching tests that only cover deleted types.
- Modify any remaining tests that imported deleted helpers.

- [ ] **Step 1: Search references after Task 2**

Run: `rg -n "TranslationRuntime|TranslationExperiencePipeline|LiveTranslationScheduler|ReplayTranslationBackfillScheduler|ReplayTranslationBackfillPlanner|scheduleLivePendingTranslations|scheduleLegacyReplayBackfillTranslations|attachTranslationResults" Sources Tests`

Expected: remaining references should be either deleted-test candidates or historical fixture strings.

- [ ] **Step 2: Delete source files whose only remaining references are their own tests**

Remove source and test files together when the type is now dead product code. Keep data model files such as `TranslationResult` only if another retained compatibility path still compiles against them.

- [ ] **Step 3: Update fixture support**

If `Tests/MeetingAgentCoreTests/RegressionFixtureSupport.swift` uses `LiveCaptionPipeline.attachTranslationResults`, remove that helper or rewrite the fixture test to assert caption-only projection from transcripts.

### Task 4: Verify Caption-Only Behavior

**Files:**
- Modify tests as needed under `Tests/MeetingAgentCoreTests/`

- [ ] **Step 1: Run source-boundary tests**

Run: `swift test --filter LiveCaptionPipelineTests/testRealtimeCaptionSessionExposesOnlyCaptionOperations`

Expected: PASS.

Run: `swift test --filter LiveCaptionPipelineTests/testMeetingAgentViewModelDoesNotCallForbiddenRealtimeTranslationComponents`

Expected: PASS.

- [ ] **Step 2: Run focused caption pipeline tests**

Run: `swift test --filter LiveCaptionPipelineTests`

Expected: PASS after removing obsolete translation tests and keeping caption-only tests.

- [ ] **Step 3: Run the required full verification**

Run: `MEETING_AGENT_COVERAGE_SCRATCH_PATH=/tmp/meeting-agent-issue-143-coverage make test`

Expected: PASS, including the repository coverage gate.

### Task 5: Commit Implementation

**Files:**
- Stage only files changed for issue #143.

- [ ] **Step 1: Inspect changes**

Run: `git status --short`

Expected: only source, tests, and issue design/plan docs for #143 are changed.

Run: `git diff --stat`

Expected: translation cleanup and boundary tests only.

- [ ] **Step 2: Commit**

Run:

```bash
git add <changed-files>
git commit -m "feat: remove realtime caption translation legacy (#143)"
```

Expected: commit succeeds and closes the implementation step for issue #143.

## Self-Review

- Spec coverage: Tasks 1-4 cover boundary API removal, ViewModel safety, pipeline cleanup, obsolete legacy deletion, and verification.
- Placeholder scan: no placeholder steps remain.
- Type consistency: method names match current source names found during issue investigation.
