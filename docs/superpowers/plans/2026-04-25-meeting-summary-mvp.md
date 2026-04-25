# Meeting Summary MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a first post-meeting summary flow that reads structured transcript segments, writes `summary.json` and `summary.md`, and renders/regenerates the summary in the macOS app.

**Architecture:** Add summary models, a deterministic extractive provider behind `MeetingSummaryProvider`, and a writer that persists JSON and Markdown together. Extend meeting metadata with summary artifact URLs and add a view model method that regenerates summaries from `transcript.json`.

**Tech Stack:** Swift 5.9, Foundation, SwiftUI, XCTest, existing `JSONEncoder.meetingAgent` and `TranscriptFileWriter` conventions.

---

### Task 1: Summary Models And Meeting Metadata

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingRecord.swift`
- Modify: `Sources/MeetingAgentCore/MeetingStore.swift`
- Create: `Sources/MeetingAgentCore/MeetingSummary.swift`
- Modify: `Tests/MeetingAgentCoreTests/MeetingRecordTests.swift`
- Modify: `Tests/MeetingAgentCoreTests/MeetingStoreTests.swift`
- Create: `Tests/MeetingAgentCoreTests/MeetingSummaryTests.swift`

- [ ] **Step 1: Write failing metadata and model tests**

Add summary URL assertions to `MeetingStoreTests.testCreatesMeetingDirectoryAndMetadata`:

```swift
XCTAssertEqual(created.record.summaryJSONURL?.lastPathComponent, "summary.json")
XCTAssertEqual(created.record.summaryMarkdownURL?.lastPathComponent, "summary.md")
```

Update `MeetingRecordTests.testMeetingRecordEncodesAndDecodes` to pass summary URLs:

```swift
summaryJSONURL: URL(fileURLWithPath: "/tmp/summary.json"),
summaryMarkdownURL: URL(fileURLWithPath: "/tmp/summary.md")
```

Update `testDecodesMetadataWithoutDiagnosticsURL` assertions:

```swift
XCTAssertNil(decoded.summaryJSONURL)
XCTAssertNil(decoded.summaryMarkdownURL)
```

Create `Tests/MeetingAgentCoreTests/MeetingSummaryTests.swift` with:

```swift
import XCTest
@testable import MeetingAgentCore

final class MeetingSummaryTests: XCTestCase {
    func testMeetingSummaryEncodesAndDecodes() throws {
        let summary = MeetingSummary(
            overview: "The team aligned on launch scope.",
            keyTopics: ["Launch"],
            decisions: [
                MeetingDecision(
                    description: "Approved the launch date.",
                    participants: ["User A"],
                    sourceSegmentIDs: ["segment-1"],
                    confidence: 0.8
                )
            ],
            actionItems: [
                MeetingActionItem(
                    description: "Follow up with legal.",
                    owner: "User B",
                    dueDate: nil,
                    sourceSegmentIDs: ["segment-2"],
                    confidence: 0.7
                )
            ],
            openQuestions: ["Can support staff the launch?"],
            risks: ["Legal review may delay launch."],
            followUps: ["Schedule launch review."],
            language: "en-US",
            sourceSegmentIDs: ["segment-1", "segment-2"],
            generatedAt: Date(timeIntervalSince1970: 1_777_000_000),
            provider: "extractive-local",
            status: .succeeded,
            failureReason: nil
        )

        let data = try JSONEncoder.meetingAgent.encode(summary)
        let decoded = try JSONDecoder.meetingAgent.decode(MeetingSummary.self, from: data)

        XCTAssertEqual(decoded, summary)
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter MeetingSummaryTests`

Expected: FAIL because summary model types do not exist.

- [ ] **Step 3: Implement models and metadata URLs**

Create `Sources/MeetingAgentCore/MeetingSummary.swift`:

```swift
import Foundation

public enum MeetingSummaryStatus: String, Codable, Equatable {
    case succeeded
    case failed
}

public struct MeetingActionItem: Codable, Equatable {
    public let description: String
    public let owner: String?
    public let dueDate: String?
    public let sourceSegmentIDs: [String]
    public let confidence: Double
}

public struct MeetingDecision: Codable, Equatable {
    public let description: String
    public let participants: [String]
    public let sourceSegmentIDs: [String]
    public let confidence: Double
}

public struct MeetingSummary: Codable, Equatable {
    public let overview: String
    public let keyTopics: [String]
    public let decisions: [MeetingDecision]
    public let actionItems: [MeetingActionItem]
    public let openQuestions: [String]
    public let risks: [String]
    public let followUps: [String]
    public let language: String?
    public let sourceSegmentIDs: [String]
    public let generatedAt: Date
    public let provider: String
    public let status: MeetingSummaryStatus
    public let failureReason: String?
}
```

Add `summaryJSONURL` and `summaryMarkdownURL` optional properties and initializer parameters to `MeetingRecord`. In `MeetingStore.createMeeting`, set them to `summary.json` and `summary.md`.

- [ ] **Step 4: Run tests to verify pass**

Run: `swift test --filter MeetingSummaryTests && swift test --filter MeetingStoreTests && swift test --filter MeetingRecordTests`

Expected: PASS.

- [ ] **Step 5: Commit**

Run:

```bash
git add Sources/MeetingAgentCore/MeetingRecord.swift Sources/MeetingAgentCore/MeetingStore.swift Sources/MeetingAgentCore/MeetingSummary.swift Tests/MeetingAgentCoreTests/MeetingRecordTests.swift Tests/MeetingAgentCoreTests/MeetingStoreTests.swift Tests/MeetingAgentCoreTests/MeetingSummaryTests.swift
git commit -m "feat: add meeting summary metadata models (#6)"
```

### Task 2: Summary Provider And Persistence

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingSummary.swift`
- Create: `Tests/MeetingAgentCoreTests/MeetingSummaryProviderTests.swift`

- [ ] **Step 1: Write failing provider and writer tests**

Create tests that instantiate `ExtractiveMeetingSummaryProvider`, verify decision/action/question/risk extraction from segments, verify empty transcript returns `status == .failed`, and verify `MeetingSummaryWriter.write` persists matching JSON and Markdown files.

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter MeetingSummaryProviderTests`

Expected: FAIL because provider and writer types do not exist.

- [ ] **Step 3: Implement provider, renderer, and writer**

Add to `MeetingSummary.swift`:

- `MeetingSummaryInput`
- `MeetingSummaryProvider`
- `ExtractiveMeetingSummaryProvider`
- `MeetingSummaryMarkdownRenderer`
- `MeetingSummaryWriter`

Use deterministic keyword extraction from the spec. `MeetingSummaryWriter.write` must encode JSON with `JSONEncoder.meetingAgent` and render Markdown from the same `MeetingSummary`.

- [ ] **Step 4: Run tests to verify pass**

Run: `swift test --filter MeetingSummaryProviderTests && swift test --filter MeetingSummaryTests`

Expected: PASS.

- [ ] **Step 5: Commit**

Run:

```bash
git add Sources/MeetingAgentCore/MeetingSummary.swift Tests/MeetingAgentCoreTests/MeetingSummaryProviderTests.swift
git commit -m "feat: add extractive meeting summary provider (#6)"
```

### Task 3: View Model Summary Regeneration

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Modify: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] **Step 1: Write failing view model test**

Add a test that creates a stored meeting, writes `transcript.json` with decision/action segments, calls `await viewModel.generateSummary(for:)`, then reads `summary.json` and asserts `status == .succeeded`.

- [ ] **Step 2: Run test to verify failure**

Run: `swift test --filter MeetingAgentViewModelTests/testGenerateSummaryWritesArtifacts`

Expected: FAIL because `generateSummary` does not exist.

- [ ] **Step 3: Implement view model method**

Add `generateSummary(for meetingID: UUID, generatedAt: Date = Date()) async` to `MeetingAgentViewModel`. It should read `TranscriptDocument` from the selected meeting's `transcriptJSONURL`, build `MeetingSummaryInput`, call `ExtractiveMeetingSummaryProvider`, write summary artifacts through `MeetingSummaryWriter`, and update `statusText`.

- [ ] **Step 4: Run tests to verify pass**

Run: `swift test --filter MeetingAgentViewModelTests`

Expected: PASS.

- [ ] **Step 5: Commit**

Run:

```bash
git add Sources/MeetingAgentCore/MeetingAgentViewModel.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift
git commit -m "feat: regenerate summaries from view model (#6)"
```

### Task 4: App Summary UI

**Files:**
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift`

- [ ] **Step 1: Implement summary section**

Pass a `regenerateSummary` closure from `MainWindowView` to `MeetingDetailView`. Add a Summary section above Transcript that reads `summary.json`, shows overview, decisions, action items, open questions, risks, failure reason, and a disabled-while-recording regenerate button.

- [ ] **Step 2: Build app**

Run: `swift build --product MeetingAgentApp`

Expected: PASS.

- [ ] **Step 3: Commit**

Run:

```bash
git add Sources/MeetingAgentApp/MainWindowView.swift
git commit -m "feat: show meeting summaries in app (#6)"
```

### Task 5: Final Verification

**Files:**
- No source changes expected.

- [ ] **Step 1: Run full unit test suite**

Run: `swift test`

Expected: PASS.

- [ ] **Step 2: Run app build**

Run: `swift build --product MeetingAgentApp`

Expected: PASS.

- [ ] **Step 3: Run CLI build**

Run: `swift build --product CoreAudioTapProbe`

Expected: PASS.

- [ ] **Step 4: Inspect diff and status**

Run: `git status --short` and `git log --oneline -5`

Expected: clean worktree with issue #6 commits on `feat/issue-6-summary-mvp`.
