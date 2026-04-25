# CoreAudioTapProbe Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a macOS 14.2+ debug probe that captures another process's output audio through Core Audio Process Tap and verifies the stream with live level output and an optional WAV file.

**Architecture:** Start with a Swift Package executable so the Core Audio path can be validated before investing in final app UI. The executable lists running apps, accepts a target PID, creates a process tap, attaches it to a temporary aggregate device, starts an IOProc, converts incoming buffers into `AudioFrame` values, and either prints levels or writes PCM to WAV.

**Tech Stack:** Swift 5.9+, macOS 14.2+, Swift Package Manager, AppKit `NSWorkspace`, CoreAudio HAL, AVFoundation for WAV writing tests/helpers where useful, XCTest.

---

## File Structure

- Create `Package.swift`: SwiftPM package definition, macOS 14.2 platform, executable and test targets.
- Create `Sources/CoreAudioTapProbe/ProbeMain.swift`: CLI entry point and argument parsing.
- Create `Sources/CoreAudioTapProbe/Models.swift`: shared value types such as `AudioCaptureTarget`, `AudioFrame`, and `ProbeError`.
- Create `Sources/CoreAudioTapProbe/RunningProcessDiscovery.swift`: lists running applications and maps them to capture targets.
- Create `Sources/CoreAudioTapProbe/CoreAudioHelpers.swift`: small Core Audio status-checking and property helpers.
- Create `Sources/CoreAudioTapProbe/AudioTapManager.swift`: creates/destroys `AudioHardwareCreateProcessTap` resources.
- Create `Sources/CoreAudioTapProbe/AggregateDeviceManager.swift`: creates/destroys aggregate device and attaches the tap UID.
- Create `Sources/CoreAudioTapProbe/AudioFrameRingBuffer.swift`: thread-safe bridge from realtime IO callback to async/CLI consumer.
- Create `Sources/CoreAudioTapProbe/AudioIOReader.swift`: starts/stops device IO and publishes audio frames.
- Create `Sources/CoreAudioTapProbe/WavFileWriter.swift`: writes captured PCM frames to a WAV file for verification.
- Create `Sources/CoreAudioTapProbe/Info.plist`: usage description for system audio capture permission.
- Create `Tests/CoreAudioTapProbeTests/RunningProcessDiscoveryTests.swift`: unit tests for process filtering and sorting.
- Create `Tests/CoreAudioTapProbeTests/AudioFrameRingBufferTests.swift`: unit tests for frame buffering.
- Create `Tests/CoreAudioTapProbeTests/WavFileWriterTests.swift`: unit tests for WAV header and payload output.

## Task 1: Swift Package Scaffold

**Files:**
- Create: `Package.swift`
- Create: `Sources/CoreAudioTapProbe/ProbeMain.swift`
- Create: `Sources/CoreAudioTapProbe/Info.plist`

- [ ] **Step 1: Create the package manifest**

Add `Package.swift`:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MeetingAgent",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CoreAudioTapProbe", targets: ["CoreAudioTapProbe"])
    ],
    targets: [
        .executableTarget(
            name: "CoreAudioTapProbe",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/CoreAudioTapProbe/Info.plist"
                ])
            ]
        ),
        .testTarget(
            name: "CoreAudioTapProbeTests",
            dependencies: ["CoreAudioTapProbe"]
        )
    ]
)
```

- [ ] **Step 2: Add the embedded Info.plist**

Add `Sources/CoreAudioTapProbe/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.meetingagent.CoreAudioTapProbe</string>
    <key>CFBundleName</key>
    <string>CoreAudioTapProbe</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>CoreAudioTapProbe captures meeting audio from the selected app so the meeting agent can transcribe and translate it.</string>
</dict>
</plist>
```

- [ ] **Step 3: Add a temporary entry point**

Add `Sources/CoreAudioTapProbe/ProbeMain.swift`:

```swift
import Foundation

@main
struct ProbeMain {
    static func main() async {
        print("CoreAudioTapProbe scaffold ready")
    }
}
```

- [ ] **Step 4: Build the scaffold**

Run: `swift build`

Expected: build succeeds and produces `.build/debug/CoreAudioTapProbe`.

- [ ] **Step 5: Run the scaffold**

Run: `swift run CoreAudioTapProbe`

Expected output contains:

```text
CoreAudioTapProbe scaffold ready
```

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/CoreAudioTapProbe/ProbeMain.swift Sources/CoreAudioTapProbe/Info.plist
git commit -m "Add CoreAudioTapProbe Swift package scaffold"
```

## Task 2: Shared Models and Process Discovery

**Files:**
- Create: `Sources/CoreAudioTapProbe/Models.swift`
- Create: `Sources/CoreAudioTapProbe/RunningProcessDiscovery.swift`
- Create: `Tests/CoreAudioTapProbeTests/RunningProcessDiscoveryTests.swift`
- Modify: `Sources/CoreAudioTapProbe/ProbeMain.swift`

- [ ] **Step 1: Write failing process discovery tests**

Add `Tests/CoreAudioTapProbeTests/RunningProcessDiscoveryTests.swift`:

```swift
import XCTest
@testable import CoreAudioTapProbe

final class RunningProcessDiscoveryTests: XCTestCase {
    func testTargetsExcludeCurrentProcessAndNamelessApps() {
        let currentPID = pid_t(42)
        let apps = [
            RunningAppSnapshot(processID: 42, displayName: "Probe", bundleIdentifier: "com.meetingagent.probe"),
            RunningAppSnapshot(processID: 100, displayName: nil, bundleIdentifier: "com.apple.hidden"),
            RunningAppSnapshot(processID: 101, displayName: "Zoom", bundleIdentifier: "us.zoom.xos")
        ]

        let targets = RunningProcessDiscovery.targets(from: apps, currentProcessID: currentPID)

        XCTAssertEqual(targets.count, 1)
        XCTAssertEqual(targets[0].processID, 101)
        XCTAssertEqual(targets[0].displayName, "Zoom")
    }

    func testMeetingAppsAndBrowsersSortBeforeOtherApps() {
        let apps = [
            RunningAppSnapshot(processID: 200, displayName: "Notes", bundleIdentifier: "com.apple.Notes"),
            RunningAppSnapshot(processID: 201, displayName: "Google Chrome", bundleIdentifier: "com.google.Chrome"),
            RunningAppSnapshot(processID: 202, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
        ]

        let targets = RunningProcessDiscovery.targets(from: apps, currentProcessID: 999)

        XCTAssertEqual(targets.map(\.displayName), ["Google Chrome", "zoom.us", "Notes"])
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter RunningProcessDiscoveryTests`

Expected: FAIL because `AudioCaptureTarget`, `RunningAppSnapshot`, and `RunningProcessDiscovery` do not exist.

- [ ] **Step 3: Add shared models**

Add `Sources/CoreAudioTapProbe/Models.swift`:

```swift
import Foundation

struct AudioCaptureTarget: Equatable, Identifiable {
    var id: pid_t { processID }
    let processID: pid_t
    let displayName: String
    let bundleIdentifier: String?
}

struct RunningAppSnapshot: Equatable {
    let processID: pid_t
    let displayName: String?
    let bundleIdentifier: String?
}

struct AudioFrame: Equatable {
    let pcm: Data
    let sampleRate: Double
    let channelCount: Int
    let timestampNanos: UInt64
}

enum ProbeError: Error, CustomStringConvertible {
    case invalidArguments(String)
    case targetNotFound(pid_t)
    case coreAudio(String)
    case captureNotStarted

    var description: String {
        switch self {
        case .invalidArguments(let message):
            return "Invalid arguments: \(message)"
        case .targetNotFound(let pid):
            return "No running process found for pid \(pid)"
        case .coreAudio(let message):
            return "Core Audio error: \(message)"
        case .captureNotStarted:
            return "Capture has not started"
        }
    }
}
```

- [ ] **Step 4: Implement process discovery**

Add `Sources/CoreAudioTapProbe/RunningProcessDiscovery.swift`:

```swift
import AppKit
import Foundation

struct RunningProcessDiscovery {
    static let preferredBundleIDs: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.google.Chrome",
        "company.thebrowser.Browser",
        "com.apple.Safari",
        "com.larksuite.Lark",
        "com.tencent.meeting"
    ]

    static func currentTargets() -> [AudioCaptureTarget] {
        let apps = NSWorkspace.shared.runningApplications.map {
            RunningAppSnapshot(
                processID: $0.processIdentifier,
                displayName: $0.localizedName,
                bundleIdentifier: $0.bundleIdentifier
            )
        }
        return targets(from: apps, currentProcessID: ProcessInfo.processInfo.processIdentifier)
    }

    static func targets(from apps: [RunningAppSnapshot], currentProcessID: pid_t) -> [AudioCaptureTarget] {
        apps.compactMap { app in
            guard app.processID != currentProcessID else { return nil }
            guard let name = app.displayName, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

            return AudioCaptureTarget(
                processID: app.processID,
                displayName: name,
                bundleIdentifier: app.bundleIdentifier
            )
        }
        .sorted { lhs, rhs in
            let lhsPreferred = lhs.bundleIdentifier.map(preferredBundleIDs.contains) ?? false
            let rhsPreferred = rhs.bundleIdentifier.map(preferredBundleIDs.contains) ?? false

            if lhsPreferred != rhsPreferred {
                return lhsPreferred && !rhsPreferred
            }

            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }
}
```

- [ ] **Step 5: Replace entry point with process listing**

Modify `Sources/CoreAudioTapProbe/ProbeMain.swift`:

```swift
import Foundation

@main
struct ProbeMain {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())

        if arguments.contains("--list") || arguments.isEmpty {
            print("Running capture targets:")
            for target in RunningProcessDiscovery.currentTargets() {
                let bundle = target.bundleIdentifier ?? "unknown-bundle"
                print("\(target.processID)\t\(target.displayName)\t\(bundle)")
            }
            print("")
            print("Usage: CoreAudioTapProbe --pid <process-id> [--seconds 10] [--wav /tmp/capture.wav]")
            return
        }

        print("Capture arguments accepted later: \(arguments.joined(separator: " "))")
    }
}
```

- [ ] **Step 6: Run tests**

Run: `swift test --filter RunningProcessDiscoveryTests`

Expected: PASS.

- [ ] **Step 7: Run process listing**

Run: `swift run CoreAudioTapProbe --list`

Expected: output lists running apps with PID, display name, and bundle identifier.

- [ ] **Step 8: Commit**

```bash
git add Sources/CoreAudioTapProbe Tests/CoreAudioTapProbeTests
git commit -m "Add running process discovery"
```

## Task 3: Core Audio Helpers and Tap Manager

**Files:**
- Create: `Sources/CoreAudioTapProbe/CoreAudioHelpers.swift`
- Create: `Sources/CoreAudioTapProbe/AudioTapManager.swift`

- [ ] **Step 1: Add Core Audio helper utilities**

Add `Sources/CoreAudioTapProbe/CoreAudioHelpers.swift`:

```swift
import CoreAudio
import Foundation

enum CoreAudioHelpers {
    static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw ProbeError.coreAudio("\(operation) failed with OSStatus \(status)")
        }
    }

    static func propertyAddress(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
    }

    static func stringProperty(objectID: AudioObjectID, selector: AudioObjectPropertySelector) throws -> String {
        var address = propertyAddress(selector)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)

        try check(
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value),
            "AudioObjectGetPropertyData(\(selector))"
        )

        return value as String
    }
}
```

- [ ] **Step 2: Add the tap manager**

Add `Sources/CoreAudioTapProbe/AudioTapManager.swift`:

```swift
import CoreAudio
import Foundation

final class AudioTapManager {
    private(set) var tapID = AudioObjectID(kAudioObjectUnknown)

    var isRunning: Bool {
        tapID != AudioObjectID(kAudioObjectUnknown)
    }

    func createTap(for target: AudioCaptureTarget) throws -> AudioObjectID {
        guard !isRunning else {
            return tapID
        }

        let description = CATapDescription()
        description.name = "MeetingAgent Tap: \(target.displayName)"
        description.processes = [NSNumber(value: target.processID)]
        description.isPrivate = true
        description.isExclusive = true
        description.isMixdown = true
        description.isMono = true
        description.muteBehavior = .unmuted

        var createdTapID = AudioObjectID(kAudioObjectUnknown)
        try CoreAudioHelpers.check(
            AudioHardwareCreateProcessTap(description, &createdTapID),
            "AudioHardwareCreateProcessTap"
        )

        tapID = createdTapID
        return createdTapID
    }

    func tapUID() throws -> String {
        guard isRunning else {
            throw ProbeError.captureNotStarted
        }
        return try CoreAudioHelpers.stringProperty(objectID: tapID, selector: kAudioTapPropertyUID)
    }

    func destroyTap() {
        guard isRunning else { return }
        AudioHardwareDestroyProcessTap(tapID)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit {
        destroyTap()
    }
}
```

- [ ] **Step 3: Build**

Run: `swift build`

Expected: PASS. If Swift reports a `CATapMuteBehavior` case-name mismatch, inspect the installed macOS 14.2+ SDK header and replace `.unmuted` with the SDK's non-muting case. Do not change the intended behavior: the captured app must remain audible to the user.

- [ ] **Step 4: Commit**

```bash
git add Sources/CoreAudioTapProbe/CoreAudioHelpers.swift Sources/CoreAudioTapProbe/AudioTapManager.swift
git commit -m "Add Core Audio process tap manager"
```

## Task 4: Aggregate Device Manager

**Files:**
- Create: `Sources/CoreAudioTapProbe/AggregateDeviceManager.swift`

- [ ] **Step 1: Add aggregate device lifecycle**

Add `Sources/CoreAudioTapProbe/AggregateDeviceManager.swift`:

```swift
import CoreAudio
import Foundation

final class AggregateDeviceManager {
    private(set) var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private let deviceUID = "com.meetingagent.CoreAudioTapProbe.aggregate.\(UUID().uuidString)"

    var isCreated: Bool {
        aggregateDeviceID != AudioObjectID(kAudioObjectUnknown)
    }

    func createAggregateDevice(named name: String) throws -> AudioObjectID {
        guard !isCreated else {
            return aggregateDeviceID
        }

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: name,
            kAudioAggregateDeviceUIDKey as String: deviceUID,
            kAudioAggregateDeviceIsPrivateKey as String: true
        ]

        var createdID = AudioObjectID(kAudioObjectUnknown)
        try CoreAudioHelpers.check(
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &createdID),
            "AudioHardwareCreateAggregateDevice"
        )

        aggregateDeviceID = createdID
        return createdID
    }

    func attachTapUID(_ tapUID: String) throws {
        guard isCreated else {
            throw ProbeError.captureNotStarted
        }

        var address = CoreAudioHelpers.propertyAddress(kAudioAggregateDevicePropertyTapList)
        var tapList = [tapUID as CFString] as CFArray
        var size = UInt32(MemoryLayout<CFArray>.size)

        try CoreAudioHelpers.check(
            AudioObjectSetPropertyData(aggregateDeviceID, &address, 0, nil, size, &tapList),
            "AudioObjectSetPropertyData(kAudioAggregateDevicePropertyTapList)"
        )
    }

    func destroyAggregateDevice() {
        guard isCreated else { return }
        AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit {
        destroyAggregateDevice()
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`

Expected: PASS. If the SDK requires a different tap-list payload shape, compare this implementation against Apple's "Capturing system audio with Core Audio taps" sample and keep the public API of `AggregateDeviceManager` unchanged.

- [ ] **Step 3: Commit**

```bash
git add Sources/CoreAudioTapProbe/AggregateDeviceManager.swift
git commit -m "Add aggregate device manager"
```

## Task 5: Audio Frame Buffer

**Files:**
- Create: `Sources/CoreAudioTapProbe/AudioFrameRingBuffer.swift`
- Create: `Tests/CoreAudioTapProbeTests/AudioFrameRingBufferTests.swift`

- [ ] **Step 1: Write failing buffer tests**

Add `Tests/CoreAudioTapProbeTests/AudioFrameRingBufferTests.swift`:

```swift
import XCTest
@testable import CoreAudioTapProbe

final class AudioFrameRingBufferTests: XCTestCase {
    func testPushAndDrainPreservesOrder() {
        let buffer = AudioFrameRingBuffer(capacity: 3)
        let first = AudioFrame(pcm: Data([1]), sampleRate: 16_000, channelCount: 1, timestampNanos: 1)
        let second = AudioFrame(pcm: Data([2]), sampleRate: 16_000, channelCount: 1, timestampNanos: 2)

        buffer.push(first)
        buffer.push(second)

        XCTAssertEqual(buffer.drain(), [first, second])
        XCTAssertEqual(buffer.drain(), [])
    }

    func testCapacityDropsOldestFrames() {
        let buffer = AudioFrameRingBuffer(capacity: 2)

        buffer.push(AudioFrame(pcm: Data([1]), sampleRate: 16_000, channelCount: 1, timestampNanos: 1))
        buffer.push(AudioFrame(pcm: Data([2]), sampleRate: 16_000, channelCount: 1, timestampNanos: 2))
        buffer.push(AudioFrame(pcm: Data([3]), sampleRate: 16_000, channelCount: 1, timestampNanos: 3))

        XCTAssertEqual(buffer.drain().map(\.pcm), [Data([2]), Data([3])])
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter AudioFrameRingBufferTests`

Expected: FAIL because `AudioFrameRingBuffer` does not exist.

- [ ] **Step 3: Implement ring buffer**

Add `Sources/CoreAudioTapProbe/AudioFrameRingBuffer.swift`:

```swift
import Foundation

final class AudioFrameRingBuffer {
    private let lock = NSLock()
    private let capacity: Int
    private var frames: [AudioFrame] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    func push(_ frame: AudioFrame) {
        lock.lock()
        defer { lock.unlock() }

        frames.append(frame)
        if frames.count > capacity {
            frames.removeFirst(frames.count - capacity)
        }
    }

    func drain() -> [AudioFrame] {
        lock.lock()
        defer { lock.unlock() }

        let drained = frames
        frames.removeAll(keepingCapacity: true)
        return drained
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter AudioFrameRingBufferTests`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/CoreAudioTapProbe/AudioFrameRingBuffer.swift Tests/CoreAudioTapProbeTests/AudioFrameRingBufferTests.swift
git commit -m "Add audio frame ring buffer"
```

## Task 6: Audio IO Reader

**Files:**
- Create: `Sources/CoreAudioTapProbe/AudioIOReader.swift`

- [ ] **Step 1: Add realtime IO reader**

Add `Sources/CoreAudioTapProbe/AudioIOReader.swift`:

```swift
import CoreAudio
import Foundation

final class AudioIOReader {
    private let frameBuffer: AudioFrameRingBuffer
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var sampleRate: Double = 48_000
    private var channelCount: Int = 1

    init(frameBuffer: AudioFrameRingBuffer) {
        self.frameBuffer = frameBuffer
    }

    func start(deviceID: AudioObjectID) throws {
        self.deviceID = deviceID
        sampleRate = try readNominalSampleRate(deviceID: deviceID)
        channelCount = max(1, try readInputChannelCount(deviceID: deviceID))

        let unmanagedSelf = Unmanaged.passUnretained(self).toOpaque()
        var createdIOProcID: AudioDeviceIOProcID?

        try CoreAudioHelpers.check(
            AudioDeviceCreateIOProcIDWithBlock(&createdIOProcID, deviceID, DispatchQueue(label: "CoreAudioTapProbe.IOProc")) { [weak self] _, inputData, _, _, _ in
                self?.handle(inputData: inputData.pointee)
            },
            "AudioDeviceCreateIOProcIDWithBlock"
        )

        guard let createdIOProcID else {
            throw ProbeError.coreAudio("AudioDeviceCreateIOProcIDWithBlock returned nil IOProcID")
        }

        ioProcID = createdIOProcID

        try CoreAudioHelpers.check(
            AudioDeviceStart(deviceID, createdIOProcID),
            "AudioDeviceStart"
        )

        _ = unmanagedSelf
    }

    func stop() {
        guard deviceID != AudioObjectID(kAudioObjectUnknown), let ioProcID else { return }
        AudioDeviceStop(deviceID, ioProcID)
        AudioDeviceDestroyIOProcID(deviceID, ioProcID)
        self.ioProcID = nil
        deviceID = AudioObjectID(kAudioObjectUnknown)
    }

    private func handle(inputData: AudioBufferList) {
        let buffers = UnsafeBufferPointer(start: inputData.mBuffersPointer, count: Int(inputData.mNumberBuffers))

        for buffer in buffers {
            guard let dataPointer = buffer.mData, buffer.mDataByteSize > 0 else { continue }
            let pcm = Data(bytes: dataPointer, count: Int(buffer.mDataByteSize))
            let frame = AudioFrame(
                pcm: pcm,
                sampleRate: sampleRate,
                channelCount: Int(buffer.mNumberChannels == 0 ? UInt32(channelCount) : buffer.mNumberChannels),
                timestampNanos: UInt64(DispatchTime.now().uptimeNanoseconds)
            )
            frameBuffer.push(frame)
        }
    }

    private func readNominalSampleRate(deviceID: AudioObjectID) throws -> Double {
        var address = CoreAudioHelpers.propertyAddress(kAudioDevicePropertyNominalSampleRate)
        var rate = Float64(48_000)
        var size = UInt32(MemoryLayout<Float64>.size)

        try CoreAudioHelpers.check(
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate),
            "AudioObjectGetPropertyData(kAudioDevicePropertyNominalSampleRate)"
        )

        return rate
    }

    private func readInputChannelCount(deviceID: AudioObjectID) throws -> Int {
        var address = CoreAudioHelpers.propertyAddress(
            kAudioDevicePropertyStreamConfiguration,
            scope: kAudioDevicePropertyScopeInput
        )
        var size: UInt32 = 0

        try CoreAudioHelpers.check(
            AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size),
            "AudioObjectGetPropertyDataSize(kAudioDevicePropertyStreamConfiguration)"
        )

        let bufferList = UnsafeMutableAudioBufferListPointer.allocate(maximumBuffers: Int(size) / MemoryLayout<AudioBuffer>.size)
        defer { free(bufferList.unsafeMutablePointer) }

        try CoreAudioHelpers.check(
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferList.unsafeMutablePointer),
            "AudioObjectGetPropertyData(kAudioDevicePropertyStreamConfiguration)"
        )

        return bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    deinit {
        stop()
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`

Expected: PASS. If Swift rejects `AudioBufferList.mBuffersPointer`, replace the buffer traversal with `UnsafeMutableAudioBufferListPointer(&inputData)` while preserving the `handle(inputData:)` behavior.

- [ ] **Step 3: Commit**

```bash
git add Sources/CoreAudioTapProbe/AudioIOReader.swift
git commit -m "Add aggregate device audio reader"
```

## Task 7: WAV Writer

**Files:**
- Create: `Sources/CoreAudioTapProbe/WavFileWriter.swift`
- Create: `Tests/CoreAudioTapProbeTests/WavFileWriterTests.swift`

- [ ] **Step 1: Write failing WAV writer test**

Add `Tests/CoreAudioTapProbeTests/WavFileWriterTests.swift`:

```swift
import XCTest
@testable import CoreAudioTapProbe

final class WavFileWriterTests: XCTestCase {
    func testWritesRiffHeaderAndPayload() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("probe-wav-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try WavFileWriter(url: url, sampleRate: 16_000, channelCount: 1)
        try writer.append(AudioFrame(pcm: Data([0x01, 0x00, 0x02, 0x00]), sampleRate: 16_000, channelCount: 1, timestampNanos: 1))
        try writer.close()

        let data = try Data(contentsOf: url)
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data.dropFirst(8).prefix(4), encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: data.dropFirst(36).prefix(4), encoding: .ascii), "data")
        XCTAssertEqual(data.suffix(4), Data([0x01, 0x00, 0x02, 0x00]))
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter WavFileWriterTests`

Expected: FAIL because `WavFileWriter` does not exist.

- [ ] **Step 3: Implement WAV writer**

Add `Sources/CoreAudioTapProbe/WavFileWriter.swift`:

```swift
import Foundation

final class WavFileWriter {
    private let url: URL
    private let handle: FileHandle
    private let sampleRate: UInt32
    private let channelCount: UInt16
    private let bitsPerSample: UInt16 = 16
    private var dataByteCount: UInt32 = 0
    private var isClosed = false

    init(url: URL, sampleRate: UInt32, channelCount: UInt16) throws {
        self.url = url
        self.sampleRate = sampleRate
        self.channelCount = channelCount

        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        try writePlaceholderHeader()
    }

    func append(_ frame: AudioFrame) throws {
        guard !isClosed else { return }
        try handle.seekToEnd()
        try handle.write(contentsOf: frame.pcm)
        dataByteCount += UInt32(frame.pcm.count)
    }

    func close() throws {
        guard !isClosed else { return }
        try handle.seek(toOffset: 0)
        try writeHeader(dataSize: dataByteCount)
        try handle.close()
        isClosed = true
    }

    private func writePlaceholderHeader() throws {
        try writeHeader(dataSize: 0)
    }

    private func writeHeader(dataSize: UInt32) throws {
        let byteRate = sampleRate * UInt32(channelCount) * UInt32(bitsPerSample / 8)
        let blockAlign = channelCount * (bitsPerSample / 8)

        var data = Data()
        data.appendASCII("RIFF")
        data.appendLittleEndian(UInt32(36) + dataSize)
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(channelCount)
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)
        data.appendASCII("data")
        data.appendLittleEndian(dataSize)
        try handle.write(contentsOf: data)
    }

    deinit {
        try? close()
    }
}

private extension Data {
    mutating func appendASCII(_ value: String) {
        append(value.data(using: .ascii)!)
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter WavFileWriterTests`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/CoreAudioTapProbe/WavFileWriter.swift Tests/CoreAudioTapProbeTests/WavFileWriterTests.swift
git commit -m "Add WAV verification writer"
```

## Task 8: Wire the Probe CLI

**Files:**
- Modify: `Sources/CoreAudioTapProbe/ProbeMain.swift`

- [ ] **Step 1: Replace CLI entry point with capture flow**

Modify `Sources/CoreAudioTapProbe/ProbeMain.swift`:

```swift
import Foundation

@main
struct ProbeMain {
    static func main() async {
        do {
            try await run()
        } catch {
            fputs("\(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func run() async throws {
        let options = try ProbeOptions(arguments: Array(CommandLine.arguments.dropFirst()))

        if options.listOnly {
            printTargets()
            return
        }

        guard let pid = options.pid else {
            printTargets()
            throw ProbeError.invalidArguments("Pass --pid <process-id> to start capture")
        }

        guard let target = RunningProcessDiscovery.currentTargets().first(where: { $0.processID == pid }) else {
            throw ProbeError.targetNotFound(pid)
        }

        print("Starting capture for \(target.displayName) pid=\(target.processID)")

        let tapManager = AudioTapManager()
        let aggregateManager = AggregateDeviceManager()
        let frameBuffer = AudioFrameRingBuffer(capacity: 512)
        let reader = AudioIOReader(frameBuffer: frameBuffer)

        let tapID = try tapManager.createTap(for: target)
        let tapUID = try tapManager.tapUID()
        let aggregateID = try aggregateManager.createAggregateDevice(named: "MeetingAgent Probe Aggregate")
        try aggregateManager.attachTapUID(tapUID)
        try reader.start(deviceID: aggregateID)

        print("Capture started tapID=\(tapID) aggregateID=\(aggregateID)")

        let writer = try options.wavPath.map {
            try WavFileWriter(url: URL(fileURLWithPath: $0), sampleRate: 16_000, channelCount: 1)
        }

        let end = Date().addingTimeInterval(TimeInterval(options.seconds))
        while Date() < end {
            try await Task.sleep(nanoseconds: 250_000_000)
            let frames = frameBuffer.drain()
            if frames.isEmpty {
                print("level=idle frames=0")
                continue
            }

            var totalBytes = 0
            var peak: UInt8 = 0
            for frame in frames {
                totalBytes += frame.pcm.count
                peak = max(peak, frame.pcm.max() ?? 0)
                try writer?.append(frame)
            }

            print("level_peak_byte=\(peak) frames=\(frames.count) bytes=\(totalBytes)")
        }

        reader.stop()
        try writer?.close()
        aggregateManager.destroyAggregateDevice()
        tapManager.destroyTap()
        print("Capture stopped")
    }

    private static func printTargets() {
        print("Running capture targets:")
        for target in RunningProcessDiscovery.currentTargets() {
            let bundle = target.bundleIdentifier ?? "unknown-bundle"
            print("\(target.processID)\t\(target.displayName)\t\(bundle)")
        }
        print("")
        print("Usage: CoreAudioTapProbe --pid <process-id> [--seconds 10] [--wav /tmp/capture.wav]")
    }
}

struct ProbeOptions {
    let listOnly: Bool
    let pid: pid_t?
    let seconds: Int
    let wavPath: String?

    init(arguments: [String]) throws {
        listOnly = arguments.isEmpty || arguments.contains("--list")

        var parsedPID: pid_t?
        var parsedSeconds = 10
        var parsedWavPath: String?

        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--list":
                index += 1
            case "--pid":
                guard index + 1 < arguments.count, let value = Int32(arguments[index + 1]) else {
                    throw ProbeError.invalidArguments("--pid requires an integer process id")
                }
                parsedPID = value
                index += 2
            case "--seconds":
                guard index + 1 < arguments.count, let value = Int(arguments[index + 1]), value > 0 else {
                    throw ProbeError.invalidArguments("--seconds requires a positive integer")
                }
                parsedSeconds = value
                index += 2
            case "--wav":
                guard index + 1 < arguments.count else {
                    throw ProbeError.invalidArguments("--wav requires a file path")
                }
                parsedWavPath = arguments[index + 1]
                index += 2
            default:
                throw ProbeError.invalidArguments("Unknown argument \(arg)")
            }
        }

        pid = parsedPID
        seconds = parsedSeconds
        wavPath = parsedWavPath
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`

Expected: PASS.

- [ ] **Step 3: Run unit tests**

Run: `swift test`

Expected: PASS.

- [ ] **Step 4: Run target listing**

Run: `swift run CoreAudioTapProbe --list`

Expected: output lists running apps and usage instructions.

- [ ] **Step 5: Commit**

```bash
git add Sources/CoreAudioTapProbe/ProbeMain.swift
git commit -m "Wire CoreAudioTapProbe capture CLI"
```

## Task 9: Manual Capture Verification

**Files:**
- Modify only if needed based on compiler/runtime findings from the local macOS SDK.

- [ ] **Step 1: Start a known audio source**

Open Zoom, Teams, Chrome, or Safari and play audible meeting-like audio. Keep system output audible.

- [ ] **Step 2: Find the target PID**

Run: `swift run CoreAudioTapProbe --list`

Expected: the audio source appears with a PID.

- [ ] **Step 3: Capture live levels**

Run: `swift run CoreAudioTapProbe --pid <PID> --seconds 10`

Expected:

```text
Starting capture for <AppName> pid=<PID>
Capture started tapID=<number> aggregateID=<number>
level_peak_byte=<number> frames=<number> bytes=<number>
Capture stopped
```

The first run should trigger macOS system audio recording permission if permission has not already been granted.

- [ ] **Step 4: Capture WAV output**

Run: `swift run CoreAudioTapProbe --pid <PID> --seconds 10 --wav /tmp/core-audio-tap-probe.wav`

Expected: `/tmp/core-audio-tap-probe.wav` exists and has non-zero audio payload.

- [ ] **Step 5: Inspect WAV file size**

Run: `ls -lh /tmp/core-audio-tap-probe.wav`

Expected: size is greater than 44 bytes.

- [ ] **Step 6: Commit runtime fixes if any**

If SDK-specific fixes were required:

```bash
git add Sources Tests
git commit -m "Fix CoreAudioTapProbe runtime capture"
```

If no fixes were required, skip this commit.

## Self-Review

- Spec coverage: process discovery is covered in Task 2; tap creation in Task 3; aggregate device in Task 4; live frame buffering and IO in Tasks 5 and 6; WAV/level verification in Tasks 7 through 9; deferred output/fallback features are intentionally out of scope.
- Placeholder scan: the plan contains no unresolved placeholder markers. SDK-specific Core Audio case-name and tap-list notes are explicit build-time correction instructions that preserve the documented public module boundaries.
- Type consistency: `AudioCaptureTarget`, `AudioFrame`, `ProbeError`, `AudioFrameRingBuffer`, `AudioTapManager`, `AggregateDeviceManager`, `AudioIOReader`, and `WavFileWriter` are introduced before later use.
