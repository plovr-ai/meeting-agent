import CoreAudio
import XCTest
@testable import MeetingAgentCore

@available(macOS 14.2, *)
final class AudioTapManagerTests: XCTestCase {
    func testSystemAudioTapClientReportsCoreAudioFailuresForInvalidObjects() {
        let client = SystemAudioTapClient()
        let target = AudioCaptureTarget(processID: -1, displayName: "Missing", bundleIdentifier: nil)

        XCTAssertThrowsError(try client.outputProcessObjectIDs(for: target))
        if let tapID = try? client.createProcessTap(description: CATapDescription()) {
            client.destroyProcessTap(tapID)
        }
        XCTAssertThrowsError(try client.tapUID(for: AudioObjectID(kAudioObjectUnknown)))

        client.destroyProcessTap(AudioObjectID(kAudioObjectUnknown))
    }

    func testCreateTapBuildsDescriptionFromTargetAndCachesTap() throws {
        let client = FakeAudioTapClient()
        client.processIDs = [101, 102]
        client.createdTapID = 900
        client.uid = "tap-uid"
        let manager = AudioTapManager(client: client)
        let target = AudioCaptureTarget(processID: 42, displayName: "Zoom", bundleIdentifier: "us.zoom")

        let tapID = try manager.createTap(for: target)
        let secondTapID = try manager.createTap(for: target)

        XCTAssertEqual(tapID, 900)
        XCTAssertEqual(secondTapID, 900)
        XCTAssertEqual(manager.tapID, 900)
        XCTAssertEqual(manager.tappedProcessCount, 2)
        XCTAssertEqual(client.processTargets, [target])
        XCTAssertEqual(client.createCalls.count, 1)
        XCTAssertEqual(client.createCalls.first?.name, "MeetingAgent Tap: Zoom")
        XCTAssertEqual(client.createCalls.first?.processes, [101, 102])
        XCTAssertTrue(client.createCalls.first?.isPrivate == true)
        XCTAssertFalse(client.createCalls.first?.isExclusive == true)
        XCTAssertTrue(client.createCalls.first?.isMixdown == true)
        XCTAssertTrue(client.createCalls.first?.isMono == true)
        XCTAssertEqual(try manager.tapUID(), "tap-uid")
    }

    func testCreateTapPropagatesProcessLookupAndCreateFailures() {
        let lookupClient = FakeAudioTapClient()
        lookupClient.processError = ProbeError.invalidArguments("no process")
        XCTAssertThrowsError(try AudioTapManager(client: lookupClient).createTap(for: testTarget)) { error in
            XCTAssertEqual(String(describing: error), "Invalid arguments: no process")
        }

        let createClient = FakeAudioTapClient()
        createClient.createError = ProbeError.invalidArguments("create failed")
        XCTAssertThrowsError(try AudioTapManager(client: createClient).createTap(for: testTarget)) { error in
            XCTAssertEqual(String(describing: error), "Invalid arguments: create failed")
        }
    }

    func testTapUIDRequiresRunningTapAndDestroyResetsState() throws {
        let client = FakeAudioTapClient()
        client.createdTapID = 77
        let manager = AudioTapManager(client: client)

        XCTAssertThrowsError(try manager.tapUID()) { error in
            XCTAssertEqual(String(describing: error), "Capture has not started")
        }

        _ = try manager.createTap(for: testTarget)
        manager.destroyTap()
        manager.destroyTap()

        XCTAssertFalse(manager.isRunning)
        XCTAssertEqual(manager.tapID, AudioObjectID(kAudioObjectUnknown))
        XCTAssertEqual(manager.tappedProcessCount, 0)
        XCTAssertEqual(client.destroyedTapIDs, [77])
    }
}

@available(macOS 14.2, *)
private let testTarget = AudioCaptureTarget(processID: 42, displayName: "Zoom", bundleIdentifier: "us.zoom")

@available(macOS 14.2, *)
private final class FakeAudioTapClient: AudioTapClient {
    struct CreateCall {
        let name: String?
        let processes: [AudioObjectID]
        let isPrivate: Bool
        let isExclusive: Bool
        let isMixdown: Bool
        let isMono: Bool
    }

    var processIDs: [AudioObjectID] = []
    var processError: Error?
    var createdTapID = AudioObjectID(1)
    var createError: Error?
    var uid = "uid"
    var processTargets: [AudioCaptureTarget] = []
    var createCalls: [CreateCall] = []
    var destroyedTapIDs: [AudioObjectID] = []

    func outputProcessObjectIDs(for target: AudioCaptureTarget) throws -> [AudioObjectID] {
        processTargets.append(target)
        if let processError {
            throw processError
        }
        return processIDs
    }

    func createProcessTap(description: CATapDescription) throws -> AudioObjectID {
        createCalls.append(CreateCall(
            name: description.name,
            processes: description.processes,
            isPrivate: description.isPrivate,
            isExclusive: description.isExclusive,
            isMixdown: description.isMixdown,
            isMono: description.isMono
        ))
        if let createError {
            throw createError
        }
        return createdTapID
    }

    func tapUID(for tapID: AudioObjectID) throws -> String {
        uid
    }

    func destroyProcessTap(_ tapID: AudioObjectID) {
        destroyedTapIDs.append(tapID)
    }
}
