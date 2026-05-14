# Meeting Audio Replay Button Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the disabled post-recording `Record` button with an in-app `Replay / Pause / Continue` control for the saved `audio.wav`.

**Architecture:** Keep playback entirely in `MeetingAgentApp`. Add a small `MeetingAudioReplayController` backed by `AVAudioPlayer`, then inject it through `MainWindowView` into the meeting workspace so the top command row can render replay state for the selected meeting. Core recording, transcription, translation, summary, and persistence code remain unchanged.

**Tech Stack:** Swift 5.9, SwiftUI, AppKit, AVFoundation `AVAudioPlayer`, existing XCTest source-structure tests in `MeetingAgentCoreTests`.

---

## File Structure

- Create `Sources/MeetingAgentApp/MeetingAudioReplayController.swift`
  - Owns local WAV playback.
  - Publishes replay state.
  - Exposes play/pause/resume/stop helpers for a meeting ID and URL.
  - Uses `AVAudioPlayerDelegate` to reset state when playback ends or decode fails.
- Modify `Sources/MeetingAgentApp/MainWindowView.swift`
  - Adds `@StateObject private var audioReplayController`.
  - Stops replay before starting a new recording.
  - Passes the controller down to `MeetingDetailView` and `MeetingCommandCenterView`.
  - Replaces the disabled non-recording `Record` button with the replay state button.
- Modify `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`
  - Adds source-structure tests for the controller and button integration.
  - Updates the existing consolidated-actions test so it expects replay instead of disabled record as the post-recording primary action.

## Task 1: Add Failing Controller Structure Tests

**Files:**
- Modify: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`
- Future create: `Sources/MeetingAgentApp/MeetingAudioReplayController.swift`

- [ ] **Step 1: Add tests for the app-layer replay controller**

Append these tests before `private func appSource(named:)` in `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`:

```swift
    func testMeetingAudioReplayControllerIsAppLayerAVAudioPlayerWrapper() throws {
        let source = try appSource(named: "MeetingAudioReplayController.swift")

        XCTAssertTrue(source.contains("import AVFoundation"))
        XCTAssertTrue(source.contains("final class MeetingAudioReplayController"))
        XCTAssertTrue(source.contains("ObservableObject"))
        XCTAssertTrue(source.contains("AVAudioPlayerDelegate"))
        XCTAssertTrue(source.contains("enum State: Equatable"))
        XCTAssertTrue(source.contains("case idle"))
        XCTAssertTrue(source.contains("case playing(UUID)"))
        XCTAssertTrue(source.contains("case paused(UUID)"))
        XCTAssertTrue(source.contains("@Published private(set) var state: State = .idle"))
        XCTAssertTrue(source.contains("func toggleReplay(for meetingID: UUID, audioURL: URL) throws"))
        XCTAssertTrue(source.contains("func stop()"))
        XCTAssertTrue(source.contains("AVAudioPlayer(contentsOf: audioURL)"))
        XCTAssertTrue(source.contains("audioPlayerDidFinishPlaying"))
        XCTAssertTrue(source.contains("audioPlayerDecodeErrorDidOccur"))
    }

    func testMeetingAudioReplayControllerStaysOutOfCoreLayer() throws {
        let packageSource = try String(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Package.swift"))

        XCTAssertTrue(packageSource.contains(".executableTarget("))
        XCTAssertTrue(packageSource.contains("name: \"MeetingAgentApp\""))
        XCTAssertFalse(packageSource.contains("MeetingAudioReplayController"))
    }
```

- [ ] **Step 2: Run the targeted tests and verify they fail**

Run:

```bash
swift test --filter MainWindowViewLayoutTests/testMeetingAudioReplayControllerIsAppLayerAVAudioPlayerWrapper
```

Expected: fail because `Sources/MeetingAgentApp/MeetingAudioReplayController.swift` does not exist.

- [ ] **Step 3: Commit only the failing tests**

```bash
git add Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift
git commit -m "test: specify meeting audio replay controller"
```

## Task 2: Implement MeetingAudioReplayController

**Files:**
- Create: `Sources/MeetingAgentApp/MeetingAudioReplayController.swift`
- Test: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

- [ ] **Step 1: Create the controller**

Create `Sources/MeetingAgentApp/MeetingAudioReplayController.swift` with this implementation:

```swift
import AppKit
import AVFoundation
import Foundation

@MainActor
final class MeetingAudioReplayController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    enum State: Equatable {
        case idle
        case playing(UUID)
        case paused(UUID)
    }

    @Published private(set) var state: State = .idle

    private var player: AVAudioPlayer?
    private var activeMeetingID: UUID?

    func toggleReplay(for meetingID: UUID, audioURL: URL) throws {
        switch state {
        case .playing(meetingID):
            pause()
        case .paused(meetingID):
            resume()
        default:
            try play(meetingID: meetingID, audioURL: audioURL)
        }
    }

    func stop() {
        player?.stop()
        player = nil
        activeMeetingID = nil
        state = .idle
    }

    private func play(meetingID: UUID, audioURL: URL) throws {
        stop()
        let nextPlayer = try AVAudioPlayer(contentsOf: audioURL)
        nextPlayer.delegate = self
        nextPlayer.prepareToPlay()
        activeMeetingID = meetingID
        player = nextPlayer
        if nextPlayer.play() {
            state = .playing(meetingID)
        } else {
            stop()
            NSSound.beep()
        }
    }

    private func pause() {
        guard let activeMeetingID else { return }
        player?.pause()
        state = .paused(activeMeetingID)
    }

    private func resume() {
        guard let activeMeetingID else { return }
        if player?.play() == true {
            state = .playing(activeMeetingID)
        } else {
            stop()
            NSSound.beep()
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.stop()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            self?.stop()
            NSSound.beep()
        }
    }
}
```

- [ ] **Step 2: Run the controller structure tests**

Run:

```bash
swift test --filter MainWindowViewLayoutTests/testMeetingAudioReplayController
```

Expected: both controller tests pass.

- [ ] **Step 3: Commit the controller**

```bash
git add Sources/MeetingAgentApp/MeetingAudioReplayController.swift
git commit -m "feat: add meeting audio replay controller"
```

## Task 3: Add Failing Workspace Button Integration Tests

**Files:**
- Modify: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`
- Future modify: `Sources/MeetingAgentApp/MainWindowView.swift`

- [ ] **Step 1: Add source tests for replay button wiring**

Append these tests before `private func appSource(named:)`:

```swift
    func testMeetingWorkspaceWiresAudioReplayControllerThroughDetailViews() throws {
        let source = try appSource(named: "MainWindowView.swift")

        XCTAssertTrue(source.contains("@StateObject private var audioReplayController = MeetingAudioReplayController()"))
        XCTAssertTrue(source.contains("audioReplayController: audioReplayController"))
        XCTAssertTrue(source.contains("let audioReplayController: MeetingAudioReplayController"))
        XCTAssertTrue(source.contains("@ObservedObject var audioReplayController: MeetingAudioReplayController"))
        XCTAssertTrue(source.contains("audioReplayController.stop()"))
    }

    func testMeetingWorkspacePostRecordingCommandUsesReplayStates() throws {
        let source = try appSource(named: "MainWindowView.swift")

        guard let commandRange = source.range(of: "private var recordingCommand: some View") else {
            return XCTFail("recordingCommand is missing")
        }
        guard let menuRange = source.range(of: "private var overflowMenu: some View", range: commandRange.upperBound..<source.endIndex) else {
            return XCTFail("recordingCommand boundary is missing")
        }
        let commandSource = source[commandRange.lowerBound..<menuRange.lowerBound]

        XCTAssertTrue(commandSource.contains("Label(\"Stop Recording\", systemImage: \"stop.fill\")"))
        XCTAssertTrue(commandSource.contains("Label(\"Replay\", systemImage: \"play.fill\")"))
        XCTAssertTrue(commandSource.contains("Label(\"Pause\", systemImage: \"pause.fill\")"))
        XCTAssertTrue(commandSource.contains("Label(\"Continue\", systemImage: \"play.fill\")"))
        XCTAssertTrue(commandSource.contains("audioReplayController.toggleReplay(for: meeting.id, audioURL: audioURL)"))
        XCTAssertTrue(commandSource.contains("FileManager.default.fileExists(atPath: audioURL.path)"))
        XCTAssertTrue(commandSource.contains(".help(\"Audio recording is not available.\")"))
        XCTAssertFalse(commandSource.contains("Label(\"Record\", systemImage: \"record.circle\")"))
        XCTAssertFalse(commandSource.contains("Recording can be started from an agenda item."))
    }
```

- [ ] **Step 2: Update the existing consolidated-actions test expectations**

In `testMeetingWorkspaceConsolidatesActionsIntoTopRow`, replace:

```swift
        XCTAssertTrue(workspaceSource.contains("Label(\"Record\", systemImage: \"record.circle\")"))
```

with:

```swift
        XCTAssertTrue(workspaceSource.contains("Label(\"Replay\", systemImage: \"play.fill\")"))
        XCTAssertTrue(workspaceSource.contains("Label(\"Pause\", systemImage: \"pause.fill\")"))
        XCTAssertTrue(workspaceSource.contains("Label(\"Continue\", systemImage: \"play.fill\")"))
        XCTAssertFalse(workspaceSource.contains("Label(\"Record\", systemImage: \"record.circle\")"))
```

- [ ] **Step 3: Run the new targeted tests and verify they fail**

Run:

```bash
swift test --filter MainWindowViewLayoutTests/testMeetingWorkspace
```

Expected: fail because `MainWindowView.swift` has not been wired to the replay controller yet.

- [ ] **Step 4: Commit only the failing integration tests**

```bash
git add Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift
git commit -m "test: specify meeting workspace replay button"
```

## Task 4: Wire Replay Into MainWindowView

**Files:**
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift`
- Test: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

- [ ] **Step 1: Add the controller to `MainWindowView`**

Near the existing `@State` properties in `MainWindowView`, add:

```swift
    @StateObject private var audioReplayController = MeetingAudioReplayController()
```

- [ ] **Step 2: Stop replay before starting recordings from agenda flows**

In each start-recording closure before calling `viewModel.startRecording...`, add:

```swift
                                audioReplayController.stop()
```

Apply this in:

- `startRecording` for agenda meetings.
- `startOfflineRecording`.
- detected-meeting alert `Start Recording`.

The agenda start block should look like:

```swift
                        Task {
                            do {
                                audioReplayController.stop()
                                try await viewModel.startRecording(for: target, meetingID: meeting.id)
                                workspaceReturnDestination = returnDestination
                                destination = .workspace
                            } catch {
                                viewModel.setRecordingStartError(error)
                            }
                        }
```

- [ ] **Step 3: Pass the controller through `MeetingDetailView`**

Add this argument when constructing `MeetingDetailView`:

```swift
                    audioReplayController: audioReplayController,
```

Add this stored property to `MeetingDetailView`:

```swift
    let audioReplayController: MeetingAudioReplayController
```

Pass it into `MeetingCommandCenterView`:

```swift
                    audioReplayController: audioReplayController,
```

- [ ] **Step 4: Observe the controller in `MeetingCommandCenterView`**

Add this property to `MeetingCommandCenterView`:

```swift
    @ObservedObject var audioReplayController: MeetingAudioReplayController
```

- [ ] **Step 5: Replace the non-recording disabled Record button**

Replace the current `else` branch inside `recordingCommand` with:

```swift
        } else if let audioURL = meeting.audioURL,
                  FileManager.default.fileExists(atPath: audioURL.path) {
            Button {
                do {
                    try audioReplayController.toggleReplay(for: meeting.id, audioURL: audioURL)
                } catch {
                    audioReplayController.stop()
                    NSSound.beep()
                }
            } label: {
                replayCommandLabel
            }
            .buttonStyle(CommandCenterActionButtonStyle())
        } else {
            Button {
            } label: {
                Label("Replay", systemImage: "play.fill")
            }
            .buttonStyle(CommandCenterActionButtonStyle())
            .disabled(true)
            .help("Audio recording is not available.")
        }
```

Add this helper below `recordingCommand`:

```swift
    @ViewBuilder
    private var replayCommandLabel: some View {
        switch audioReplayController.state {
        case .playing(meeting.id):
            Label("Pause", systemImage: "pause.fill")
        case .paused(meeting.id):
            Label("Continue", systemImage: "play.fill")
        default:
            Label("Replay", systemImage: "play.fill")
        }
    }
```

- [ ] **Step 6: Run the targeted workspace tests**

Run:

```bash
swift test --filter MainWindowViewLayoutTests/testMeetingWorkspace
```

Expected: pass.

- [ ] **Step 7: Commit the UI wiring**

```bash
git add Sources/MeetingAgentApp/MainWindowView.swift
git commit -m "feat: replay meeting audio from workspace"
```

## Task 5: Full Verification

**Files:**
- No new files.
- Verify all changed files.

- [ ] **Step 1: Run the required test entrypoint**

Run:

```bash
make test
```

Expected: all tests pass.

- [ ] **Step 2: Build the app product**

Run:

```bash
swift build --product MeetingAgentApp
```

Expected: build succeeds.

- [ ] **Step 3: Inspect git status**

Run:

```bash
git status --short
```

Expected: only the pre-existing untracked `.env` remains, or the working tree is otherwise clean.

- [ ] **Step 4: Commit any verification-only test fixes if needed**

Only if verification required small corrections:

```bash
git add Sources/MeetingAgentApp/MeetingAudioReplayController.swift Sources/MeetingAgentApp/MainWindowView.swift Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift
git commit -m "test: verify meeting audio replay button"
```

Do not commit `.env`.

## Self-Review

Spec coverage:

- Post-recording button becomes replay control: Task 3 and Task 4.
- Play, pause, continue only: Task 2 and Task 4.
- Missing audio disables control with explanation: Task 3 and Task 4.
- App-layer playback using `AVAudioPlayer`: Task 1 and Task 2.
- No Core persistence changes: file structure and Task 1 package test.
- Stop replay before new recording: Task 3 and Task 4.
- Run `make test`: Task 5.

Placeholder scan: no red-flag placeholder language remains.

Type consistency: `MeetingAudioReplayController.State`, `toggleReplay(for:audioURL:)`, `stop()`, and injected `audioReplayController` names are consistent across tests and implementation steps.
