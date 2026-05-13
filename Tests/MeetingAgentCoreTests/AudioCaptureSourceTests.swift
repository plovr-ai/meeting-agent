import XCTest
@testable import MeetingAgentCore

final class AudioCaptureSourceTests: XCTestCase {
    func testProcessSourceExposesTargetMetadata() {
        let target = AudioCaptureTarget(
            processID: 42,
            displayName: "Zoom",
            bundleIdentifier: "us.zoom.xos",
            isAudioOutputActive: true
        )
        let source = AudioCaptureSource.process(target)

        XCTAssertEqual(source.kind, .process)
        XCTAssertEqual(source.displayName, "Zoom")
        XCTAssertEqual(source.processID, 42)
        XCTAssertEqual(source.processTarget, target)
    }

    func testMicrophoneSourceExposesReadableMetadataWithoutProcessTarget() {
        let source = AudioCaptureSource.microphone(displayName: "Computer Microphone")

        XCTAssertEqual(source.kind, .microphone)
        XCTAssertEqual(source.displayName, "Computer Microphone")
        XCTAssertEqual(source.processID, AudioCaptureSource.microphoneProcessID)
        XCTAssertNil(source.processTarget)
    }
}
