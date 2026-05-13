import CoreAudio
import XCTest
@testable import MeetingAgentCore

@available(macOS 14.2, *)
final class MicrophoneCaptureSessionTests: XCTestCase {
    func testStartsDefaultInputDeviceAndPublishesOutputFormat() throws {
        let resolver = FakeDefaultInputDeviceResolver(deviceID: 99)
        let reader = FakeMicrophoneAudioReader(sampleRate: 44_100, channelCount: 1)
        let frameBuffer = AudioFrameRingBuffer(capacity: 2)
        let session = MicrophoneCaptureSession(
            defaultInputDeviceResolver: resolver,
            readerFactory: { suppliedBuffer in
                XCTAssertTrue(suppliedBuffer === frameBuffer)
                return reader
            },
            frameBuffer: frameBuffer
        )

        try session.start(source: .microphone(displayName: "Computer Microphone"))
        try session.start(source: .microphone(displayName: "Computer Microphone"))

        XCTAssertTrue(session.isRunning)
        XCTAssertEqual(session.outputSampleRate, 44_100)
        XCTAssertEqual(session.outputChannelCount, 1)
        XCTAssertEqual(reader.startedDeviceIDs, [99])
    }

    func testRejectsProcessSource() {
        let session = MicrophoneCaptureSession(
            defaultInputDeviceResolver: FakeDefaultInputDeviceResolver(deviceID: 99),
            readerFactory: { _ in FakeMicrophoneAudioReader(sampleRate: 16_000, channelCount: 1) }
        )
        let target = AudioCaptureTarget(processID: 42, displayName: "Zoom", bundleIdentifier: nil)

        XCTAssertThrowsError(try session.start(source: .process(target))) { error in
            XCTAssertEqual(
                String(describing: error),
                "Invalid arguments: MicrophoneCaptureSession only supports microphone capture sources"
            )
        }
    }

    func testStopStopsReader() throws {
        let reader = FakeMicrophoneAudioReader(sampleRate: 16_000, channelCount: 1)
        let session = MicrophoneCaptureSession(
            defaultInputDeviceResolver: FakeDefaultInputDeviceResolver(deviceID: 99),
            readerFactory: { _ in reader }
        )

        try session.start(source: .microphone(displayName: "Computer Microphone"))
        session.stop()
        session.stop()

        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(reader.stopCallCount, 1)
    }
}

@available(macOS 14.2, *)
private struct FakeDefaultInputDeviceResolver: DefaultInputDeviceResolving {
    let deviceID: AudioObjectID

    func defaultInputDeviceID() throws -> AudioObjectID {
        deviceID
    }
}

@available(macOS 14.2, *)
private final class FakeMicrophoneAudioReader: AudioDeviceReading {
    let outputSampleRate: Double
    let outputChannelCount: Int
    var startedDeviceIDs: [AudioObjectID] = []
    var stopCallCount = 0

    init(sampleRate: Double, channelCount: Int) {
        outputSampleRate = sampleRate
        outputChannelCount = channelCount
    }

    func start(deviceID: AudioObjectID) throws {
        startedDeviceIDs.append(deviceID)
    }

    func stop() {
        stopCallCount += 1
    }
}
