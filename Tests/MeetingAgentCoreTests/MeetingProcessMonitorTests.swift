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

    func testDetectsPreferredTargetOnlyWhenAudioOutputIsActive() {
        let inactiveChrome = AudioCaptureTarget(
            processID: 456,
            displayName: "Google Chrome",
            bundleIdentifier: "com.google.Chrome",
            isAudioOutputActive: false
        )
        let activeChrome = AudioCaptureTarget(
            processID: 456,
            displayName: "Google Chrome",
            bundleIdentifier: "com.google.Chrome",
            isAudioOutputActive: true
        )
        let monitor = MeetingProcessMonitor()

        let inactive = monitor.detectNewCandidates(in: [inactiveChrome], isRecording: false)
        let active = monitor.detectNewCandidates(in: [activeChrome], isRecording: false)

        XCTAssertEqual(inactive, [])
        XCTAssertEqual(active, [activeChrome])
    }
}
