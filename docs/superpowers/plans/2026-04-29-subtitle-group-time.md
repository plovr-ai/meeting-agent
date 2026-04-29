# Subtitle Group Time Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show local hour-minute-second time beside each live subtitle speaker group label, using the first subtitle in that group.

**Architecture:** The grouping model owns the first-subtitle timestamp because it already defines consecutive speaker-group boundaries. The SwiftUI transcript header formats that timestamp for display while preserving the existing speaker edit menu.

**Tech Stack:** Swift 5.9, SwiftUI, XCTest, Swift Package Manager.

---

### Task 1: Add First-Turn Timestamp To Speaker Groups

**Files:**
- Modify: `Sources/MeetingAgentCore/LiveMeetingCockpit.swift`
- Test: `Tests/MeetingAgentCoreTests/LiveCaptionStoreTests.swift`

- [ ] **Step 1: Write the failing grouping test**

Add this test near the existing `LiveCaptionSpeakerGroup` tests in `Tests/MeetingAgentCoreTests/LiveCaptionStoreTests.swift`:

```swift
func testSpeakerGroupStartedAtUsesFirstTurnTimestamp() {
    let speaker = TranscriptSpeaker(identifier: "speaker-1", label: "User A")
    let firstTime = Date(timeIntervalSince1970: 100)
    let secondTime = Date(timeIntervalSince1970: 140)

    let groups = LiveCaptionSpeakerGroup.groups(from: [
        LiveCaptionTurn(sourceSegmentID: "s1", speaker: speaker, originalText: "First block.", isFinal: true, createdAt: firstTime),
        LiveCaptionTurn(sourceSegmentID: "s2", speaker: speaker, originalText: "Second block.", isFinal: true, createdAt: secondTime)
    ])

    XCTAssertEqual(groups.count, 1)
    XCTAssertEqual(groups[0].startedAt, firstTime)
    XCTAssertEqual(groups[0].turns.map(\.createdAt), [firstTime, secondTime])
}
```

- [ ] **Step 2: Run the focused test and verify it fails**

Run: `swift test --filter LiveCaptionStoreTests/testSpeakerGroupStartedAtUsesFirstTurnTimestamp`

Expected: compile failure because `LiveCaptionSpeakerGroup` has no `startedAt` member.

- [ ] **Step 3: Add the model field and grouping behavior**

In `Sources/MeetingAgentCore/LiveMeetingCockpit.swift`, update `LiveCaptionSpeakerGroup`:

```swift
public struct LiveCaptionSpeakerGroup: Equatable, Identifiable {
    public var id: String
    public var speaker: TranscriptSpeaker
    public var turns: [LiveCaptionTurn]
    public var startedAt: Date

    public init(id: String, speaker: TranscriptSpeaker, turns: [LiveCaptionTurn], startedAt: Date) {
        self.id = id
        self.speaker = speaker
        self.turns = turns
        self.startedAt = startedAt
    }

    public static func groups(from turns: [LiveCaptionTurn]) -> [LiveCaptionSpeakerGroup] {
        var groups: [LiveCaptionSpeakerGroup] = []
        for turn in turns {
            if let lastIndex = groups.indices.last,
               groups[lastIndex].speaker == turn.speaker {
                groups[lastIndex].turns.append(turn)
            } else {
                groups.append(LiveCaptionSpeakerGroup(
                    id: turn.id,
                    speaker: turn.speaker,
                    turns: [turn],
                    startedAt: turn.createdAt
                ))
            }
        }
        return groups
    }
}
```

- [ ] **Step 4: Run the focused test and verify it passes**

Run: `swift test --filter LiveCaptionStoreTests/testSpeakerGroupStartedAtUsesFirstTurnTimestamp`

Expected: PASS.

### Task 2: Render Group Time Beside Speaker Label

**Files:**
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift`
- Test: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

- [ ] **Step 1: Write the failing layout guard**

Add this test near the existing unified transcript tests:

```swift
func testUnifiedTranscriptRendersSpeakerGroupStartTimeBesideSpeakerName() throws {
    let source = try appSource(named: "MainWindowView.swift")

    XCTAssertTrue(source.contains("speakerStartTimeText"))
    XCTAssertTrue(source.contains("group.startedAt.formatted(date: .omitted, time: .standard)"))
    XCTAssertTrue(source.contains("Text(speakerStartTimeText)"))
}
```

- [ ] **Step 2: Run the focused test and verify it fails**

Run: `swift test --filter MainWindowViewLayoutTests/testUnifiedTranscriptRendersSpeakerGroupStartTimeBesideSpeakerName`

Expected: FAIL because the timestamp renderer is not present.

- [ ] **Step 3: Update the speaker header UI**

In `Sources/MeetingAgentApp/MainWindowView.swift`, add this helper inside `BilingualTranscriptGroup`:

```swift
private var speakerStartTimeText: String {
    group.startedAt.formatted(date: .omitted, time: .standard)
}
```

Then update both editable and non-editable branches of `speakerLabel` so the speaker name and timestamp appear together:

```swift
HStack(spacing: 6) {
    Text(speakerDisplayName)
        .commandCenterMono()
    Text(speakerStartTimeText)
        .font(CommandCenterTypography.caption)
        .foregroundStyle(CommandCenterPalette.secondaryText)
}
```

Keep the menu chevron only in the editable menu label.

- [ ] **Step 4: Run the focused layout test and verify it passes**

Run: `swift test --filter MainWindowViewLayoutTests/testUnifiedTranscriptRendersSpeakerGroupStartTimeBesideSpeakerName`

Expected: PASS.

### Task 3: Full Verification And Commit

**Files:**
- Modify: `Sources/MeetingAgentCore/LiveMeetingCockpit.swift`
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift`
- Modify: `Tests/MeetingAgentCoreTests/LiveCaptionStoreTests.swift`
- Modify: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

- [ ] **Step 1: Run full test suite**

Run: `make test`

Expected: PASS with coverage check passing.

- [ ] **Step 2: Review diff**

Run: `git diff -- Sources/MeetingAgentCore/LiveMeetingCockpit.swift Sources/MeetingAgentApp/MainWindowView.swift Tests/MeetingAgentCoreTests/LiveCaptionStoreTests.swift Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

Expected: diff only includes the speaker group timestamp model, UI rendering, and regression tests.

- [ ] **Step 3: Commit implementation**

Run:

```bash
git add Sources/MeetingAgentCore/LiveMeetingCockpit.swift Sources/MeetingAgentApp/MainWindowView.swift Tests/MeetingAgentCoreTests/LiveCaptionStoreTests.swift Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift
git commit -m "feat: show subtitle group times (#58)"
```
