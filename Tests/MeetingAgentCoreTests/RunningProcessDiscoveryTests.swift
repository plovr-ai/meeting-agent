import XCTest
@testable import MeetingAgentCore

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

    func testEdgeIsPreferredAsGoogleMeetBrowser() {
        let apps = [
            RunningAppSnapshot(processID: 200, displayName: "Notes", bundleIdentifier: "com.apple.Notes"),
            RunningAppSnapshot(processID: 201, displayName: "Microsoft Edge", bundleIdentifier: "com.microsoft.edgemac")
        ]

        let targets = RunningProcessDiscovery.targets(from: apps, currentProcessID: 999)

        XCTAssertEqual(targets.map(\.displayName), ["Microsoft Edge", "Notes"])
    }

    func testAutomaticallySelectsFirstPreferredTarget() {
        let targets = [
            AudioCaptureTarget(processID: 200, displayName: "Notes", bundleIdentifier: "com.apple.Notes"),
            AudioCaptureTarget(processID: 201, displayName: "Google Chrome", bundleIdentifier: "com.google.Chrome")
        ]

        let selected = RunningProcessDiscovery.automaticTarget(from: targets)

        XCTAssertEqual(selected?.processID, 201)
    }

    func testAutomaticTargetRequiresActiveAudioOutput() {
        let targets = [
            AudioCaptureTarget(
                processID: 201,
                displayName: "Google Chrome",
                bundleIdentifier: "com.google.Chrome",
                isAudioOutputActive: false
            ),
            AudioCaptureTarget(
                processID: 202,
                displayName: "zoom.us",
                bundleIdentifier: "us.zoom.xos",
                isAudioOutputActive: true
            )
        ]

        let selected = RunningProcessDiscovery.automaticTarget(from: targets)

        XCTAssertEqual(selected?.processID, 202)
    }
}
