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

    func testStopRecordingUpdatesSelectedMeetingAndReturnsToIdle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-vm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(baseDirectory: root)
        let viewModel = MeetingAgentViewModel(store: store)
        let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")

        viewModel.setPendingCandidate(target)
        try viewModel.acceptPendingCandidate(startedAt: Date(timeIntervalSince1970: 100))

        viewModel.stopRecording(at: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(viewModel.meetings.first?.endedAt, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(viewModel.statusText, "Idle")
        XCTAssertFalse(viewModel.isRecording)
    }
}

final class AppRuntimeCapabilitiesTests: XCTestCase {
    func testUserNotificationsRequireAppBundleRuntime() {
        XCTAssertTrue(AppRuntimeCapabilities.supportsUserNotifications(bundleURL: URL(fileURLWithPath: "/Applications/MeetingAgent.app")))
        XCTAssertFalse(AppRuntimeCapabilities.supportsUserNotifications(bundleURL: URL(fileURLWithPath: "/tmp/meeting-agent/.build/debug")))
    }
}
