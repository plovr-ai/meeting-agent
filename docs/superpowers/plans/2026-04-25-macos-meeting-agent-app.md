# macOS Meeting Agent App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first runnable macOS Meeting Agent app with a menu bar item, split list/detail main window, meeting process detection, user-confirmed recording, live transcript display, and Application Support persistence.

**Architecture:** Refactor the existing CLI implementation into a shared `MeetingAgentCore` library target. Keep `CoreAudioTapProbe` as a debugging CLI, and add `MeetingAgentApp` as a SwiftUI/AppKit menu bar application that depends on the shared core. Core business logic lives in testable services; SwiftUI views remain thin.

**Tech Stack:** Swift 5.9, Swift Package Manager, macOS 14+, SwiftUI, AppKit `NSStatusItem`, UserNotifications, XCTest, Core Audio Process Tap, macOS Speech.

---

## File Structure

Create and modify these files:

- Modify `Package.swift`: add `MeetingAgentCore` library product/target, add `MeetingAgentApp` executable target, update CLI/test dependencies.
- Move or copy core implementation files from `Sources/CoreAudioTapProbe/` to `Sources/MeetingAgentCore/`.
- Keep `Sources/CoreAudioTapProbe/ProbeMain.swift` as the CLI entry point.
- Create `Sources/MeetingAgentApp/MeetingAgentApp.swift`: SwiftUI app entry point.
- Create `Sources/MeetingAgentApp/AppDelegate.swift`: menu bar item, app lifecycle, notification delegate.
- Create `Sources/MeetingAgentApp/MainWindowView.swift`: split list/detail UI.
- Create `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`: app state, process prompts, recording actions.
- Create `Sources/MeetingAgentCore/MeetingRecord.swift`: persisted meeting model.
- Create `Sources/MeetingAgentCore/MeetingStore.swift`: Application Support storage.
- Create `Sources/MeetingAgentCore/MeetingProcessMonitor.swift`: polling/detection/deduplication.
- Create `Sources/MeetingAgentCore/MeetingRecorder.swift`: active recording coordinator.
- Create `Sources/MeetingAgentCore/AudioCaptureSession.swift`: reusable capture session extracted from CLI flow.
- Create `Tests/MeetingAgentCoreTests/MeetingRecordTests.swift`.
- Create `Tests/MeetingAgentCoreTests/MeetingStoreTests.swift`.
- Create `Tests/MeetingAgentCoreTests/MeetingProcessMonitorTests.swift`.
- Create `Tests/MeetingAgentCoreTests/MeetingRecorderTests.swift`.
- Move existing tests into `Tests/MeetingAgentCoreTests/` and update imports to `@testable import MeetingAgentCore`.

---

## Task 1: Create Shared Core Target

**Files:**
- Modify: `Package.swift`
- Move/Create: `Sources/MeetingAgentCore/*.swift`
- Modify: `Sources/CoreAudioTapProbe/ProbeMain.swift`
- Move/Modify tests from `Tests/CoreAudioTapProbeTests/` to `Tests/MeetingAgentCoreTests/`

- [ ] **Step 1: Update package targets**

Edit `Package.swift` so it has one library, two executables, and one core test target:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MeetingAgent",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MeetingAgentCore", targets: ["MeetingAgentCore"]),
        .executable(name: "CoreAudioTapProbe", targets: ["CoreAudioTapProbe"]),
        .executable(name: "MeetingAgentApp", targets: ["MeetingAgentApp"])
    ],
    targets: [
        .target(
            name: "MeetingAgentCore"
        ),
        .executableTarget(
            name: "CoreAudioTapProbe",
            dependencies: ["MeetingAgentCore"],
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/CoreAudioTapProbe/Info.plist"
                ])
            ]
        ),
        .executableTarget(
            name: "MeetingAgentApp",
            dependencies: ["MeetingAgentCore"]
        ),
        .testTarget(
            name: "MeetingAgentCoreTests",
            dependencies: ["MeetingAgentCore"]
        )
    ]
)
```

- [ ] **Step 2: Move reusable source files into `MeetingAgentCore`**

Create `Sources/MeetingAgentCore/` and move every file from `Sources/CoreAudioTapProbe/` except `ProbeMain.swift` and `Info.plist` into it:

```text
AggregateDeviceManager.swift
AudioFrameRingBuffer.swift
AudioIOReader.swift
AudioSampleConverter.swift
AudioTapManager.swift
CoreAudioHelpers.swift
Models.swift
RecordingOutput.swift
RunningProcessDiscovery.swift
SpeechTranscriptionProvider.swift
SystemSpeechTranscriber.swift
WavFileWriter.swift
```

- [ ] **Step 3: Make core APIs public enough for the CLI and app**

In moved core files, mark these declarations `public`: `AudioCaptureTarget`, `RunningAppSnapshot`, `AudioFrame`, `ProbeError`, `RunningProcessDiscovery`, `AudioFrameRingBuffer`, `AudioIOReader`, `WavFileWriter`, `RecordingOutput`, `TranscriptFileWriter`, `SpeechProvider`, `AudioFrameTranscriber`, `SpeechTranscriptionProvider`, `LocalSpeechTranscriptionProvider`, `SpeechTranscriptionProviderFactory`, and `SystemSpeechTranscriber`.

Expose only initializers, properties, and methods currently used by `ProbeMain.swift` and the future app. Keep helper extensions private.

- [ ] **Step 4: Import core in the CLI**

At the top of `Sources/CoreAudioTapProbe/ProbeMain.swift`, add:

```swift
import MeetingAgentCore
```

- [ ] **Step 5: Move tests to the core test target**

Move all files from `Tests/CoreAudioTapProbeTests/` to `Tests/MeetingAgentCoreTests/`.

In each moved test file, change:

```swift
@testable import CoreAudioTapProbe
```

to:

```swift
@testable import MeetingAgentCore
```

- [ ] **Step 6: Run tests and fix access-control compile errors**

Run:

```bash
swift test
```

Expected at first: access-control compile errors for internal initializers/properties.

Fix by making the specific required members public. Do not make unrelated helper functions public.

- [ ] **Step 7: Verify green**

Run:

```bash
swift test
```

Expected: all existing tests pass.

- [ ] **Step 8: Commit**

```bash
git add Package.swift Sources Tests
git commit -m "Extract shared meeting agent core"
```

---

## Task 2: Add Meeting Record Model

**Files:**
- Create: `Sources/MeetingAgentCore/MeetingRecord.swift`
- Create: `Tests/MeetingAgentCoreTests/MeetingRecordTests.swift`

- [ ] **Step 1: Write failing model tests**

Create `Tests/MeetingAgentCoreTests/MeetingRecordTests.swift`:

```swift
import XCTest
@testable import MeetingAgentCore

final class MeetingRecordTests: XCTestCase {
    func testMeetingRecordEncodesAndDecodes() throws {
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let startedAt = Date(timeIntervalSince1970: 1_777_000_000)
        let endedAt = Date(timeIntervalSince1970: 1_777_000_600)
        let record = MeetingRecord(
            id: id,
            name: "Google Meet",
            startedAt: startedAt,
            endedAt: endedAt,
            audioURL: URL(fileURLWithPath: "/tmp/audio.wav"),
            transcriptURL: URL(fileURLWithPath: "/tmp/transcript.txt")
        )

        let data = try JSONEncoder.meetingAgent.encode(record)
        let decoded = try JSONDecoder.meetingAgent.decode(MeetingRecord.self, from: data)

        XCTAssertEqual(decoded, record)
    }

    func testActiveRecordHasNoEndTime() {
        let record = MeetingRecord(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            name: "zoom.us",
            startedAt: Date(timeIntervalSince1970: 1_777_000_000),
            endedAt: nil,
            audioURL: nil,
            transcriptURL: nil
        )

        XCTAssertNil(record.endedAt)
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
swift test --filter MeetingRecordTests
```

Expected: FAIL because `MeetingRecord` and JSON helpers do not exist.

- [ ] **Step 3: Implement model**

Create `Sources/MeetingAgentCore/MeetingRecord.swift`:

```swift
import Foundation

public struct MeetingRecord: Codable, Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var startedAt: Date
    public var endedAt: Date?
    public var audioURL: URL?
    public var transcriptURL: URL?

    public init(
        id: UUID,
        name: String,
        startedAt: Date,
        endedAt: Date?,
        audioURL: URL?,
        transcriptURL: URL?
    ) {
        self.id = id
        self.name = name
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.audioURL = audioURL
        self.transcriptURL = transcriptURL
    }
}

public extension JSONEncoder {
    static var meetingAgent: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

public extension JSONDecoder {
    static var meetingAgent: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
```

- [ ] **Step 4: Run tests**

Run:

```bash
swift test --filter MeetingRecordTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingAgentCore/MeetingRecord.swift Tests/MeetingAgentCoreTests/MeetingRecordTests.swift
git commit -m "Add meeting record model"
```

---

## Task 3: Add Meeting Store

**Files:**
- Create: `Sources/MeetingAgentCore/MeetingStore.swift`
- Create: `Tests/MeetingAgentCoreTests/MeetingStoreTests.swift`

- [ ] **Step 1: Write failing store tests**

Create `Tests/MeetingAgentCoreTests/MeetingStoreTests.swift`:

```swift
import XCTest
@testable import MeetingAgentCore

final class MeetingStoreTests: XCTestCase {
    func testCreatesMeetingDirectoryAndMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let id = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

        let created = try store.createMeeting(
            id: id,
            name: "Google Chrome",
            startedAt: Date(timeIntervalSince1970: 1_777_000_000)
        )

        XCTAssertEqual(created.record.name, "Google Chrome")
        XCTAssertEqual(created.record.audioURL?.lastPathComponent, "audio.wav")
        XCTAssertEqual(created.record.transcriptURL?.lastPathComponent, "transcript.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.metadataURL.path))
    }

    func testLoadsMeetingsSortedByStartTimeDescending() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)

        _ = try store.createMeeting(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            name: "Older",
            startedAt: Date(timeIntervalSince1970: 100)
        )
        _ = try store.createMeeting(
            id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            name: "Newer",
            startedAt: Date(timeIntervalSince1970: 200)
        )

        let meetings = try store.loadMeetings()

        XCTAssertEqual(meetings.map(\.name), ["Newer", "Older"])
    }

    func testUpdatesMeetingMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        var created = try store.createMeeting(
            id: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!,
            name: "Teams",
            startedAt: Date(timeIntervalSince1970: 100)
        )
        created.record.endedAt = Date(timeIntervalSince1970: 300)

        try store.save(created.record)
        let loaded = try store.loadMeetings()

        XCTAssertEqual(loaded.first?.endedAt, Date(timeIntervalSince1970: 300))
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
swift test --filter MeetingStoreTests
```

Expected: FAIL because `MeetingStore` does not exist.

- [ ] **Step 3: Implement store**

Create `Sources/MeetingAgentCore/MeetingStore.swift`:

```swift
import Foundation

public struct StoredMeeting: Equatable {
    public var record: MeetingRecord
    public let directory: URL
    public let metadataURL: URL

    public init(record: MeetingRecord, directory: URL, metadataURL: URL) {
        self.record = record
        self.directory = directory
        self.metadataURL = metadataURL
    }
}

public final class MeetingStore {
    private let baseDirectory: URL
    private let fileManager: FileManager

    public init(baseDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else {
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.baseDirectory = appSupport.appendingPathComponent("MeetingAgent", isDirectory: true)
        }
    }

    public var meetingsDirectory: URL {
        baseDirectory.appendingPathComponent("Meetings", isDirectory: true)
    }

    public func createMeeting(id: UUID = UUID(), name: String, startedAt: Date = Date()) throws -> StoredMeeting {
        let directory = meetingsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let record = MeetingRecord(
            id: id,
            name: name,
            startedAt: startedAt,
            endedAt: nil,
            audioURL: directory.appendingPathComponent("audio.wav"),
            transcriptURL: directory.appendingPathComponent("transcript.txt")
        )
        try save(record)
        return StoredMeeting(
            record: record,
            directory: directory,
            metadataURL: metadataURL(for: record.id)
        )
    }

    public func save(_ record: MeetingRecord) throws {
        let directory = meetingsDirectory.appendingPathComponent(record.id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.meetingAgent.encode(record)
        try data.write(to: metadataURL(for: record.id), options: .atomic)
    }

    public func loadMeetings() throws -> [MeetingRecord] {
        guard fileManager.fileExists(atPath: meetingsDirectory.path) else { return [] }
        let directories = try fileManager.contentsOfDirectory(
            at: meetingsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        let records = try directories.compactMap { directory -> MeetingRecord? in
            let metadataURL = directory.appendingPathComponent("metadata.json")
            guard fileManager.fileExists(atPath: metadataURL.path) else { return nil }
            let data = try Data(contentsOf: metadataURL)
            return try JSONDecoder.meetingAgent.decode(MeetingRecord.self, from: data)
        }

        return records.sorted { $0.startedAt > $1.startedAt }
    }

    public func metadataURL(for id: UUID) -> URL {
        meetingsDirectory
            .appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent("metadata.json")
    }
}
```

- [ ] **Step 4: Run store tests**

Run:

```bash
swift test --filter MeetingStoreTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingAgentCore/MeetingStore.swift Tests/MeetingAgentCoreTests/MeetingStoreTests.swift
git commit -m "Add meeting persistence store"
```

---

## Task 4: Add Meeting Process Monitor

**Files:**
- Create: `Sources/MeetingAgentCore/MeetingProcessMonitor.swift`
- Create: `Tests/MeetingAgentCoreTests/MeetingProcessMonitorTests.swift`

- [ ] **Step 1: Write failing monitor tests**

Create `Tests/MeetingAgentCoreTests/MeetingProcessMonitorTests.swift`:

```swift
import XCTest
@testable import MeetingAgentCore

final class MeetingProcessMonitorTests: XCTestCase {
    func testDetectsNewPreferredTargetOnce() {
        let zoom = AudioCaptureTarget(processID: 123, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
        let monitor = MeetingProcessMonitor()

        let first = monitor.detectNewCandidates(in: [zoom], isRecording: false)
        let second = monitor.detectNewCandidates(in: [zoom], isRecording: false)

        XCTAssertEqual(first, [zoom])
        XCTAssertEqual(second, [])
    }

    func testIgnoresRejectedProcessUntilItExits() {
        let zoom = AudioCaptureTarget(processID: 123, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
        let monitor = MeetingProcessMonitor()

        _ = monitor.detectNewCandidates(in: [zoom], isRecording: false)
        monitor.ignore(processID: 123)
        let ignored = monitor.detectNewCandidates(in: [zoom], isRecording: false)
        monitor.reconcileRunningProcessIDs([])
        let afterExitAndReturn = monitor.detectNewCandidates(in: [zoom], isRecording: false)

        XCTAssertEqual(ignored, [])
        XCTAssertEqual(afterExitAndReturn, [zoom])
    }

    func testDoesNotDetectWhileRecording() {
        let chrome = AudioCaptureTarget(processID: 456, displayName: "Google Chrome", bundleIdentifier: "com.google.Chrome")
        let monitor = MeetingProcessMonitor()

        let candidates = monitor.detectNewCandidates(in: [chrome], isRecording: true)

        XCTAssertEqual(candidates, [])
    }

    func testFiltersNonPreferredTargets() {
        let notes = AudioCaptureTarget(processID: 789, displayName: "Notes", bundleIdentifier: "com.apple.Notes")
        let monitor = MeetingProcessMonitor()

        let candidates = monitor.detectNewCandidates(in: [notes], isRecording: false)

        XCTAssertEqual(candidates, [])
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
swift test --filter MeetingProcessMonitorTests
```

Expected: FAIL because `MeetingProcessMonitor` does not exist.

- [ ] **Step 3: Implement monitor**

Create `Sources/MeetingAgentCore/MeetingProcessMonitor.swift`:

```swift
import Foundation

public final class MeetingProcessMonitor {
    private var promptedProcessIDs: Set<pid_t> = []
    private var ignoredProcessIDs: Set<pid_t> = []

    public init() {}

    public func detectNewCandidates(
        in targets: [AudioCaptureTarget],
        isRecording: Bool
    ) -> [AudioCaptureTarget] {
        guard !isRecording else { return [] }

        let candidates = targets.filter { target in
            let isPreferred = target.bundleIdentifier.map(RunningProcessDiscovery.preferredBundleIDs.contains) ?? false
            guard isPreferred else { return false }
            guard !promptedProcessIDs.contains(target.processID) else { return false }
            guard !ignoredProcessIDs.contains(target.processID) else { return false }
            return true
        }

        for candidate in candidates {
            promptedProcessIDs.insert(candidate.processID)
        }

        return candidates
    }

    public func ignore(processID: pid_t) {
        ignoredProcessIDs.insert(processID)
    }

    public func reconcileRunningProcessIDs(_ runningProcessIDs: Set<pid_t>) {
        promptedProcessIDs = promptedProcessIDs.intersection(runningProcessIDs)
        ignoredProcessIDs = ignoredProcessIDs.intersection(runningProcessIDs)
    }
}
```

- [ ] **Step 4: Run monitor tests**

Run:

```bash
swift test --filter MeetingProcessMonitorTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingAgentCore/MeetingProcessMonitor.swift Tests/MeetingAgentCoreTests/MeetingProcessMonitorTests.swift
git commit -m "Add meeting process monitor"
```

---

## Task 5: Extract Reusable Audio Capture Session

**Files:**
- Create: `Sources/MeetingAgentCore/AudioCaptureSession.swift`
- Modify: `Sources/CoreAudioTapProbe/ProbeMain.swift`
- Create: `Tests/MeetingAgentCoreTests/AudioCaptureSessionTests.swift`

- [ ] **Step 1: Write failing session state test**

Create `Tests/MeetingAgentCoreTests/AudioCaptureSessionTests.swift`:

```swift
import XCTest
@testable import MeetingAgentCore

final class AudioCaptureSessionTests: XCTestCase {
    func testSessionStartsInactive() {
        let session = AudioCaptureSession()

        XCTAssertFalse(session.isRunning)
    }
}
```

- [ ] **Step 2: Run test to verify failure**

Run:

```bash
swift test --filter AudioCaptureSessionTests
```

Expected: FAIL because `AudioCaptureSession` does not exist.

- [ ] **Step 3: Implement capture session wrapper**

Create `Sources/MeetingAgentCore/AudioCaptureSession.swift`:

```swift
import Foundation

public final class AudioCaptureSession {
    private let tapManager = AudioTapManager()
    private let aggregateManager = AggregateDeviceManager()
    public let frameBuffer: AudioFrameRingBuffer
    private var reader: AudioIOReader?

    public private(set) var isRunning = false
    public private(set) var outputSampleRate: Double = 48_000
    public private(set) var outputChannelCount: Int = 1

    public init(frameBuffer: AudioFrameRingBuffer = AudioFrameRingBuffer(capacity: 512)) {
        self.frameBuffer = frameBuffer
    }

    public func start(target: AudioCaptureTarget) throws {
        guard !isRunning else { return }
        let reader = AudioIOReader(frameBuffer: frameBuffer)
        let tapID = try tapManager.createTap(for: target)
        _ = tapID
        let tapUID = try tapManager.tapUID()
        let aggregateID = try aggregateManager.createAggregateDevice(
            named: "MeetingAgent Probe Aggregate",
            tapUID: tapUID
        )
        try reader.start(deviceID: aggregateID)
        outputSampleRate = reader.outputSampleRate
        outputChannelCount = reader.outputChannelCount
        self.reader = reader
        isRunning = true
    }

    public func stop() {
        reader?.stop()
        reader = nil
        aggregateManager.destroyAggregateDevice()
        tapManager.destroyTap()
        isRunning = false
    }

    deinit {
        stop()
    }
}
```

- [ ] **Step 4: Run session test**

Run:

```bash
swift test --filter AudioCaptureSessionTests
```

Expected: PASS.

- [ ] **Step 5: Refactor CLI to use `AudioCaptureSession`**

In `Sources/CoreAudioTapProbe/ProbeMain.swift`, replace the direct `AudioTapManager`, `AggregateDeviceManager`, and `AudioIOReader` setup with:

```swift
let captureSession = AudioCaptureSession()
let frameBuffer = captureSession.frameBuffer
defer {
    captureSession.stop()
}

try captureSession.start(target: target)

log("Capture started target=\(target.displayName)")

let recordingOutput = try options.wavPath.map {
    try RecordingOutput.defaultOutput(forRequestedWavPath: $0)
}
let writer = try recordingOutput.map {
    try WavFileWriter(
        url: $0.wavURL,
        sampleRate: UInt32(captureSession.outputSampleRate.rounded()),
        channelCount: UInt16(captureSession.outputChannelCount)
    )
}
```

Keep the existing drain loop, writer append, and transcriber append logic.

- [ ] **Step 6: Run full tests**

Run:

```bash
swift test
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/MeetingAgentCore/AudioCaptureSession.swift Sources/CoreAudioTapProbe/ProbeMain.swift Tests/MeetingAgentCoreTests/AudioCaptureSessionTests.swift
git commit -m "Extract reusable audio capture session"
```

---

## Task 6: Add Meeting Recorder

**Files:**
- Create: `Sources/MeetingAgentCore/MeetingRecorder.swift`
- Create: `Tests/MeetingAgentCoreTests/MeetingRecorderTests.swift`

- [ ] **Step 1: Write failing recorder tests**

Create `Tests/MeetingAgentCoreTests/MeetingRecorderTests.swift`:

```swift
import XCTest
@testable import MeetingAgentCore

final class MeetingRecorderTests: XCTestCase {
    func testRecorderStartsAndStopsMeeting() throws {
        let storeRoot = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-recorder-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storeRoot) }
        let store = MeetingStore(baseDirectory: storeRoot)
        let recorder = MeetingRecorder(store: store)
        let target = AudioCaptureTarget(processID: 1, displayName: "Google Chrome", bundleIdentifier: "com.google.Chrome")

        let record = try recorder.prepareRecord(for: target, startedAt: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(record.name, "Google Chrome")
        XCTAssertEqual(recorder.state, .prepared(record.id))

        let stopped = try recorder.markStopped(at: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(stopped?.endedAt, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(recorder.state, .idle)
    }

    func testRecorderRejectsSecondPreparedMeeting() throws {
        let storeRoot = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-recorder-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storeRoot) }
        let store = MeetingStore(baseDirectory: storeRoot)
        let recorder = MeetingRecorder(store: store)
        let target = AudioCaptureTarget(processID: 1, displayName: "Google Chrome", bundleIdentifier: "com.google.Chrome")

        _ = try recorder.prepareRecord(for: target, startedAt: Date(timeIntervalSince1970: 100))

        XCTAssertThrowsError(try recorder.prepareRecord(for: target, startedAt: Date(timeIntervalSince1970: 101)))
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
swift test --filter MeetingRecorderTests
```

Expected: FAIL because `MeetingRecorder` does not exist.

- [ ] **Step 3: Implement recorder state shell**

Create `Sources/MeetingAgentCore/MeetingRecorder.swift`:

```swift
import Foundation

public enum MeetingRecorderState: Equatable {
    case idle
    case prepared(UUID)
    case recording(UUID)
}

public final class MeetingRecorder {
    private let store: MeetingStore
    private var activeRecord: MeetingRecord?

    public private(set) var state: MeetingRecorderState = .idle

    public init(store: MeetingStore = MeetingStore()) {
        self.store = store
    }

    public func prepareRecord(
        for target: AudioCaptureTarget,
        startedAt: Date = Date()
    ) throws -> MeetingRecord {
        guard case .idle = state else {
            throw ProbeError.invalidArguments("A meeting recording is already active")
        }

        let stored = try store.createMeeting(
            name: target.displayName,
            startedAt: startedAt
        )
        activeRecord = stored.record
        state = .prepared(stored.record.id)
        return stored.record
    }

    public func markStopped(at endedAt: Date = Date()) throws -> MeetingRecord? {
        guard var record = activeRecord else {
            state = .idle
            return nil
        }

        record.endedAt = endedAt
        try store.save(record)
        activeRecord = nil
        state = .idle
        return record
    }
}
```

- [ ] **Step 4: Run recorder tests**

Run:

```bash
swift test --filter MeetingRecorderTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingAgentCore/MeetingRecorder.swift Tests/MeetingAgentCoreTests/MeetingRecorderTests.swift
git commit -m "Add meeting recorder state"
```

---

## Task 7: Add Meeting Agent View Model

**Files:**
- Create: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Create: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] **Step 1: Write failing view model tests**

Create `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`:

```swift
import XCTest
@testable import MeetingAgentCore

@MainActor
final class MeetingAgentViewModelTests: XCTestCase {
    func testLoadsMeetingsOnStart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        _ = try store.createMeeting(name: "Google Chrome", startedAt: Date(timeIntervalSince1970: 100))

        let viewModel = MeetingAgentViewModel(store: store)
        try viewModel.loadMeetings()

        XCTAssertEqual(viewModel.meetings.map(\.name), ["Google Chrome"])
    }

    func testCandidateCanBeAcceptedAndRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let viewModel = MeetingAgentViewModel(store: store)
        let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")

        viewModel.setPendingCandidate(target)
        XCTAssertEqual(viewModel.pendingCandidate?.processID, 10)

        try viewModel.acceptPendingCandidate(startedAt: Date(timeIntervalSince1970: 100))
        XCTAssertNil(viewModel.pendingCandidate)
        XCTAssertEqual(viewModel.meetings.first?.name, "zoom.us")
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
swift test --filter MeetingAgentViewModelTests
```

Expected: FAIL because `MeetingAgentViewModel` does not exist.

- [ ] **Step 3: Implement view model**

Create `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`:

```swift
import Combine
import Foundation

@MainActor
public final class MeetingAgentViewModel: ObservableObject {
    @Published public private(set) var meetings: [MeetingRecord] = []
    @Published public private(set) var selectedMeetingID: UUID?
    @Published public private(set) var pendingCandidate: AudioCaptureTarget?
    @Published public private(set) var statusText: String = "Idle"

    private let store: MeetingStore
    private let recorder: MeetingRecorder

    public init(store: MeetingStore = MeetingStore(), recorder: MeetingRecorder? = nil) {
        self.store = store
        self.recorder = recorder ?? MeetingRecorder(store: store)
    }

    public func loadMeetings() throws {
        meetings = try store.loadMeetings()
        selectedMeetingID = meetings.first?.id
    }

    public func setPendingCandidate(_ target: AudioCaptureTarget) {
        pendingCandidate = target
        statusText = "Meeting detected: \(target.displayName)"
    }

    public func rejectPendingCandidate() {
        pendingCandidate = nil
        statusText = "Idle"
    }

    public func acceptPendingCandidate(startedAt: Date = Date()) throws {
        guard let candidate = pendingCandidate else { return }
        let record = try recorder.prepareRecord(for: candidate, startedAt: startedAt)
        meetings.insert(record, at: 0)
        selectedMeetingID = record.id
        pendingCandidate = nil
        statusText = "Recording \(record.name)"
    }

    public var selectedMeeting: MeetingRecord? {
        meetings.first { $0.id == selectedMeetingID }
    }
}
```

- [ ] **Step 4: Run view model tests**

Run:

```bash
swift test --filter MeetingAgentViewModelTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests Package.swift
git commit -m "Add meeting agent view model"
```

---

## Task 8: Add SwiftUI Main Window

**Files:**
- Create: `Sources/MeetingAgentApp/MainWindowView.swift`
- Create or Modify: `Sources/MeetingAgentApp/MeetingAgentApp.swift`

- [ ] **Step 1: Create app entry point**

Create `Sources/MeetingAgentApp/MeetingAgentApp.swift`:

```swift
import MeetingAgentCore
import SwiftUI

@main
struct MeetingAgentApp: App {
    @StateObject private var viewModel = MeetingAgentViewModel()

    var body: some Scene {
        WindowGroup("Meeting Agent") {
            MainWindowView(viewModel: viewModel)
                .frame(minWidth: 900, minHeight: 600)
                .task {
                    try? viewModel.loadMeetings()
                }
        }
    }
}
```

- [ ] **Step 2: Create split list/detail UI**

Create `Sources/MeetingAgentApp/MainWindowView.swift`:

```swift
import MeetingAgentCore
import SwiftUI

struct MainWindowView: View {
    @ObservedObject var viewModel: MeetingAgentViewModel

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { viewModel.selectedMeetingID },
                set: { viewModel.selectMeeting($0) }
            )) {
                ForEach(viewModel.meetings) { meeting in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(meeting.name)
                            .font(.headline)
                        Text(meeting.startedAt, style: .date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(Optional(meeting.id))
                }
            }
            .navigationTitle("Meetings")
        } detail: {
            MeetingDetailView(meeting: viewModel.selectedMeeting, statusText: viewModel.statusText)
        }
    }
}

private struct MeetingDetailView: View {
    let meeting: MeetingRecord?
    let statusText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let meeting {
                Text(meeting.name)
                    .font(.largeTitle)
                Text(statusText)
                    .foregroundStyle(.secondary)
                LabeledContent("Started", value: meeting.startedAt.formatted(date: .abbreviated, time: .standard))
                if let endedAt = meeting.endedAt {
                    LabeledContent("Ended", value: endedAt.formatted(date: .abbreviated, time: .standard))
                }
                LabeledContent("Audio", value: meeting.audioURL?.path ?? "Not recorded")
                Divider()
                Text("Transcript")
                    .font(.headline)
                ScrollView {
                    Text(transcriptText(for: meeting))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            } else {
                ContentUnavailableView("No Meeting Selected", systemImage: "waveform", description: Text("Detected and recorded meetings will appear here."))
            }
        }
        .padding(20)
    }

    private func transcriptText(for meeting: MeetingRecord) -> String {
        guard let transcriptURL = meeting.transcriptURL,
              let text = try? String(contentsOf: transcriptURL, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return "Transcript will appear here while recording."
        }
        return text
    }
}
```

- [ ] **Step 3: Add `selectMeeting` to the view model**

In `MeetingAgentViewModel`, add:

```swift
public func selectMeeting(_ id: UUID?) {
    selectedMeetingID = id
}
```

- [ ] **Step 4: Build app target**

Run:

```bash
swift build --product MeetingAgentApp
```

Expected: build succeeds.

- [ ] **Step 5: Run all tests**

Run:

```bash
swift test
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/MeetingAgentApp Sources/MeetingAgentCore Package.swift Tests
git commit -m "Add meeting agent main window"
```

---

## Task 9: Add Menu Bar App Delegate and Notifications

**Files:**
- Create: `Sources/MeetingAgentApp/AppDelegate.swift`
- Modify: `Sources/MeetingAgentApp/MeetingAgentApp.swift`
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`

- [ ] **Step 1: Create AppKit delegate**

Create `Sources/MeetingAgentApp/AppDelegate.swift`:

```swift
import AppKit
import MeetingAgentCore
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem?
    var viewModel: MeetingAgentViewModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        configureStatusItem()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Meeting"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Meeting Agent", action: #selector(openMainWindow), keyEquivalent: "o"))
        menu.addItem(NSMenuItem(title: "Idle", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    @objc private func openMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func notifyMeetingDetected(_ target: AudioCaptureTarget) {
        let content = UNMutableNotificationContent()
        content.title = "Meeting detected"
        content.body = "\(target.displayName) meeting detected. Open Meeting Agent to start recording."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "meeting-detected-\(target.processID)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
```

- [ ] **Step 2: Attach delegate to SwiftUI app**

Modify `Sources/MeetingAgentApp/MeetingAgentApp.swift`:

```swift
import MeetingAgentCore
import SwiftUI

@main
struct MeetingAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = MeetingAgentViewModel()

    var body: some Scene {
        WindowGroup("Meeting Agent") {
            MainWindowView(viewModel: viewModel)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear {
                    appDelegate.viewModel = viewModel
                }
                .task {
                    try? viewModel.loadMeetings()
                }
        }
    }
}
```

- [ ] **Step 3: Build app target**

Run:

```bash
swift build --product MeetingAgentApp
```

Expected: build succeeds.

- [ ] **Step 4: Run all tests**

Run:

```bash
swift test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingAgentApp
git commit -m "Add menu bar app delegate"
```

---

## Task 10: Wire Process Monitoring into the App

**Files:**
- Modify: `Sources/MeetingAgentApp/MeetingAgentApp.swift`
- Modify: `Sources/MeetingAgentApp/AppDelegate.swift`
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`

- [ ] **Step 1: Add polling API to view model**

In `MeetingAgentViewModel`, add:

```swift
private let processMonitor = MeetingProcessMonitor()

public func pollForMeetingCandidates() -> AudioCaptureTarget? {
    let targets = RunningProcessDiscovery.currentTargets()
    processMonitor.reconcileRunningProcessIDs(Set(targets.map(\.processID)))
    let candidates = processMonitor.detectNewCandidates(
        in: targets,
        isRecording: isRecording
    )
    guard let candidate = candidates.first else { return nil }
    setPendingCandidate(candidate)
    return candidate
}

public var isRecording: Bool {
    if case .recording = recorder.state { return true }
    if case .prepared = recorder.state { return true }
    return false
}

public func ignorePendingCandidate() {
    if let pendingCandidate {
        processMonitor.ignore(processID: pendingCandidate.processID)
    }
    rejectPendingCandidate()
}
```

- [ ] **Step 2: Add app polling loop**

In `MeetingAgentApp.swift`, add a timer task in the main view:

```swift
.task {
    try? viewModel.loadMeetings()
    while !Task.isCancelled {
        if let candidate = viewModel.pollForMeetingCandidates() {
            appDelegate.notifyMeetingDetected(candidate)
        }
        try? await Task.sleep(nanoseconds: 3_000_000_000)
    }
}
```

- [ ] **Step 3: Add prompt UI to main window**

In `MainWindowView`, add an alert:

```swift
.alert(
    "Meeting detected",
    isPresented: Binding(
        get: { viewModel.pendingCandidate != nil },
        set: { isPresented in
            if !isPresented {
                viewModel.ignorePendingCandidate()
            }
        }
    ),
    presenting: viewModel.pendingCandidate
) { target in
    Button("Start Recording") {
        try? viewModel.acceptPendingCandidate()
    }
    Button("Not Now", role: .cancel) {
        viewModel.ignorePendingCandidate()
    }
} message: { target in
    Text("\(target.displayName) detected. Start recording?")
}
```

- [ ] **Step 4: Build app target**

Run:

```bash
swift build --product MeetingAgentApp
```

Expected: build succeeds.

- [ ] **Step 5: Run all tests**

Run:

```bash
swift test
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/MeetingAgentApp Sources/MeetingAgentCore
git commit -m "Wire meeting process monitoring into app"
```

---

## Task 11: Connect Recording and Live Transcript

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingRecorder.swift`
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift`

- [ ] **Step 1: Extend MeetingRecorder with live transcript state**

In `MeetingRecorder`, add public async recording methods:

```swift
private var captureSession: AudioCaptureSession?
private var writer: WavFileWriter?
private var transcriber: AudioFrameTranscriber?

public func startRecording(
    target: AudioCaptureTarget,
    record: MeetingRecord,
    speechProvider: SpeechProvider = .local,
    localeIdentifier: String = "en-US"
) async throws {
    guard case .prepared(record.id) = state else {
        throw ProbeError.invalidArguments("Meeting must be prepared before recording starts")
    }

    let session = AudioCaptureSession()
    try session.start(target: target)
    captureSession = session

    if let audioURL = record.audioURL {
        writer = try WavFileWriter(
            url: audioURL,
            sampleRate: UInt32(session.outputSampleRate.rounded()),
            channelCount: UInt16(session.outputChannelCount)
        )
    }

    if let transcriptURL = record.transcriptURL {
        let provider = SpeechTranscriptionProviderFactory.provider(for: speechProvider)
        transcriber = try await provider.start(
            transcriptURL: transcriptURL,
            localeIdentifier: localeIdentifier
        )
    }

    state = .recording(record.id)
}

public func drainFrames() throws {
    guard let session = captureSession else { return }
    let frames = session.frameBuffer.drain()
    for frame in frames {
        try writer?.append(frame)
        try transcriber?.append(frame)
    }
}

public func stopRecording(at endedAt: Date = Date()) throws -> MeetingRecord? {
    try writer?.close()
    transcriber?.finish()
    captureSession?.stop()
    writer = nil
    transcriber = nil
    captureSession = nil
    return try markStopped(at: endedAt)
}
```

- [ ] **Step 2: Update view model start/stop methods**

In `MeetingAgentViewModel`, add:

```swift
private var activeTarget: AudioCaptureTarget?

public func startRecordingForPendingCandidate(localeIdentifier: String = "en-US") async throws {
    guard let candidate = pendingCandidate else { return }
    let record = try recorder.prepareRecord(for: candidate)
    meetings.insert(record, at: 0)
    selectedMeetingID = record.id
    activeTarget = candidate
    pendingCandidate = nil
    try await recorder.startRecording(
        target: candidate,
        record: record,
        speechProvider: .local,
        localeIdentifier: localeIdentifier
    )
    statusText = "Recording \(record.name)"
}

public func drainRecordingFrames() {
    try? recorder.drainFrames()
    objectWillChange.send()
}

public func stopRecording() {
    if let stopped = try? recorder.stopRecording(),
       let index = meetings.firstIndex(where: { $0.id == stopped.id }) {
        meetings[index] = stopped
    }
    activeTarget = nil
    statusText = "Idle"
}
```

- [ ] **Step 3: Update alert action to start real recording**

In `MainWindowView`, replace `try? viewModel.acceptPendingCandidate()` with:

```swift
Task {
    try? await viewModel.startRecordingForPendingCandidate()
}
```

- [ ] **Step 4: Add frame drain loop to app task**

In `MeetingAgentApp.swift`, inside the polling task loop, add:

```swift
viewModel.drainRecordingFrames()
```

before sleeping.

- [ ] **Step 5: Add Stop button in detail view**

Pass a stop closure from `MainWindowView` into `MeetingDetailView`, and render:

```swift
Button("Stop Recording") {
    viewModel.stopRecording()
}
.disabled(!viewModel.isRecording)
```

- [ ] **Step 6: Build app target**

Run:

```bash
swift build --product MeetingAgentApp
```

Expected: build succeeds.

- [ ] **Step 7: Run all tests**

Run:

```bash
swift test
```

Expected: PASS.

- [ ] **Step 8: Manual smoke test**

Run:

```bash
swift run MeetingAgentApp
```

Expected:

- A menu bar item appears.
- Main window can open.
- When a preferred meeting process is running, the app prompts.
- Accepting starts recording.
- A meeting row appears.
- Transcript text file is created under Application Support.

- [ ] **Step 9: Commit**

```bash
git add Sources
git commit -m "Connect app recording flow"
```

---

## Task 12: Final Documentation and Verification

**Files:**
- Modify: `AGENTS.md`
- Optional Modify: `docs/superpowers/specs/2026-04-25-macos-meeting-agent-app-design.md` if implementation differs from the spec.

- [ ] **Step 1: Update common commands**

In `AGENTS.md`, add:

```sh
swift build --product MeetingAgentApp
swift run MeetingAgentApp
```

Add a note:

```text
The app stores user meeting data under ~/Library/Application Support/MeetingAgent/Meetings/.
The CLI still writes debug output to .record/.
```

- [ ] **Step 2: Run full verification**

Run:

```bash
swift test
swift build --product MeetingAgentApp
swift build --product CoreAudioTapProbe
```

Expected: all commands succeed.

- [ ] **Step 3: Check git status**

Run:

```bash
git status --short
```

Expected: only intended documentation changes are present.

- [ ] **Step 4: Commit**

```bash
git add AGENTS.md docs/superpowers/specs/2026-04-25-macos-meeting-agent-app-design.md
git commit -m "Document macOS app workflow"
```
