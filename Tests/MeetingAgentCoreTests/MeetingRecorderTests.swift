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

    func testRecorderPersistsTargetProcessEndedReason() throws {
        let storeRoot = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-recorder-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storeRoot) }
        let store = MeetingStore(baseDirectory: storeRoot)
        let recorder = MeetingRecorder(store: store)
        let target = AudioCaptureTarget(processID: 1, displayName: "Google Chrome", bundleIdentifier: "com.google.Chrome")

        let record = try recorder.prepareRecord(for: target, startedAt: Date(timeIntervalSince1970: 100))
        _ = try recorder.markStopped(at: Date(timeIntervalSince1970: 200), endedReason: .targetProcessEnded)

        let data = try Data(contentsOf: XCTUnwrap(record.diagnosticsURL))
        let diagnostics = try JSONDecoder.meetingAgent.decode(CaptureDiagnostics.self, from: data)
        XCTAssertEqual(diagnostics.endedReason, .targetProcessEnded)
        XCTAssertEqual(diagnostics.status, .targetProcessEnded)
    }
}
