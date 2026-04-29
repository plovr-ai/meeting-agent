import CoreAudio
import XCTest
@testable import MeetingAgentCore

@available(macOS 14.2, *)
final class AudioCaptureSessionTests: XCTestCase {
    func testSessionStartsInactive() {
        let session = AudioCaptureSession()

        XCTAssertFalse(session.isRunning)
    }

    func testStartCreatesTapAggregateAndReaderThenPublishesOutputFormat() throws {
        let tapManager = FakeSessionTapManager(tapID: 11, tapUID: "tap-uid")
        let aggregateManager = FakeSessionAggregateManager(deviceID: 22)
        let reader = FakeSessionAudioReader(sampleRate: 16_000, channelCount: 2)
        let expectedFrameBuffer = AudioFrameRingBuffer(capacity: 2)
        let session = AudioCaptureSession(
            tapManager: tapManager,
            aggregateManager: aggregateManager,
            readerFactory: { frameBuffer in
                XCTAssertTrue(frameBuffer === expectedFrameBuffer)
                return reader
            },
            frameBuffer: expectedFrameBuffer
        )
        let target = AudioCaptureTarget(processID: 42, displayName: "Zoom", bundleIdentifier: nil)

        try session.start(target: target)
        try session.start(target: target)

        XCTAssertTrue(session.isRunning)
        XCTAssertEqual(session.outputSampleRate, 16_000)
        XCTAssertEqual(session.outputChannelCount, 2)
        XCTAssertEqual(tapManager.targets, [target])
        XCTAssertEqual(aggregateManager.createCalls.count, 1)
        XCTAssertEqual(aggregateManager.createCalls.first?.0, "MeetingAgent Probe Aggregate")
        XCTAssertEqual(aggregateManager.createCalls.first?.1, "tap-uid")
        XCTAssertEqual(reader.startedDeviceIDs, [22])
    }

    func testStartCleansUpPartialResourcesWhenReaderFails() {
        let tapManager = FakeSessionTapManager(tapID: 11, tapUID: "tap-uid")
        let aggregateManager = FakeSessionAggregateManager(deviceID: 22)
        let reader = FakeSessionAudioReader(sampleRate: 48_000, channelCount: 1)
        reader.startError = ProbeError.coreAudio("reader failed")
        let session = AudioCaptureSession(
            tapManager: tapManager,
            aggregateManager: aggregateManager,
            readerFactory: { _ in reader }
        )

        XCTAssertThrowsError(
            try session.start(target: AudioCaptureTarget(processID: 42, displayName: "Zoom", bundleIdentifier: nil))
        ) { error in
            XCTAssertEqual(String(describing: error), "Core Audio error: reader failed")
        }
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(aggregateManager.destroyCallCount, 1)
        XCTAssertEqual(tapManager.destroyCallCount, 1)
    }

    func testStopStopsReaderAndDestroysResourcesInOrder() throws {
        let tapManager = FakeSessionTapManager(tapID: 11, tapUID: "tap-uid")
        let aggregateManager = FakeSessionAggregateManager(deviceID: 22)
        let reader = FakeSessionAudioReader(sampleRate: 48_000, channelCount: 1)
        let session = AudioCaptureSession(
            tapManager: tapManager,
            aggregateManager: aggregateManager,
            readerFactory: { _ in reader }
        )

        try session.start(target: AudioCaptureTarget(processID: 42, displayName: "Zoom", bundleIdentifier: nil))
        session.stop()
        session.stop()

        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(reader.stopCallCount, 1)
        XCTAssertEqual(aggregateManager.destroyCallCount, 1)
        XCTAssertEqual(tapManager.destroyCallCount, 1)
    }
}

@available(macOS 14.2, *)
private final class FakeSessionTapManager: AudioTapManaging {
    let tapID: AudioObjectID
    let uid: String
    var targets: [AudioCaptureTarget] = []
    var destroyCallCount = 0

    init(tapID: AudioObjectID, tapUID: String) {
        self.tapID = tapID
        self.uid = tapUID
    }

    func createTap(for target: AudioCaptureTarget) throws -> AudioObjectID {
        targets.append(target)
        return tapID
    }

    func tapUID() throws -> String {
        uid
    }

    func destroyTap() {
        destroyCallCount += 1
    }
}

@available(macOS 14.2, *)
private final class FakeSessionAggregateManager: AggregateDeviceManaging {
    let deviceID: AudioObjectID
    var createCalls: [(String, String)] = []
    var destroyCallCount = 0

    init(deviceID: AudioObjectID) {
        self.deviceID = deviceID
    }

    func createAggregateDevice(named name: String, tapUID: String) throws -> AudioObjectID {
        createCalls.append((name, tapUID))
        return deviceID
    }

    func destroyAggregateDevice() {
        destroyCallCount += 1
    }
}

@available(macOS 14.2, *)
private final class FakeSessionAudioReader: AudioDeviceReading {
    let outputSampleRate: Double
    let outputChannelCount: Int
    var startError: Error?
    var startedDeviceIDs: [AudioObjectID] = []
    var stopCallCount = 0

    init(sampleRate: Double, channelCount: Int) {
        self.outputSampleRate = sampleRate
        self.outputChannelCount = channelCount
    }

    func start(deviceID: AudioObjectID) throws {
        if let startError {
            throw startError
        }
        startedDeviceIDs.append(deviceID)
    }

    func stop() {
        stopCallCount += 1
    }
}
