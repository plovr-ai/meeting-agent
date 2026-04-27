import CoreAudio
import XCTest
@testable import MeetingAgentCore

final class AggregateDeviceManagerTests: XCTestCase {
    func testSystemAggregateDeviceClientReportsCoreAudioFailureForInvalidDescription() {
        let client = SystemAggregateDeviceClient()

        XCTAssertThrowsError(try client.createAggregateDevice(description: [:]))
        client.destroyAggregateDevice(AudioObjectID(kAudioObjectUnknown))
    }

    func testCreateAggregateDeviceBuildsDescriptionAndCachesDevice() throws {
        let client = FakeAggregateDeviceClient()
        client.createdDeviceID = 1234
        let manager = AggregateDeviceManager(client: client)

        let deviceID = try manager.createAggregateDevice(named: "Meeting Device", tapUID: "tap-uid")
        let cachedDeviceID = try manager.createAggregateDevice(named: "Other", tapUID: "other-tap")

        XCTAssertEqual(deviceID, 1234)
        XCTAssertEqual(cachedDeviceID, 1234)
        XCTAssertTrue(manager.isCreated)
        XCTAssertEqual(client.createCalls.count, 1)
        XCTAssertEqual(client.createCalls.first?.name, "Meeting Device")
        XCTAssertEqual(client.createCalls.first?.tapUID, "tap-uid")
        XCTAssertEqual(client.createCalls.first?.isPrivate, true)
        XCTAssertTrue(client.createCalls.first?.uid.hasPrefix("com.meetingagent.MeetingAgentApp.aggregate.") == true)
    }

    func testCreateAggregateDevicePropagatesCreateFailure() {
        let client = FakeAggregateDeviceClient()
        client.createError = ProbeError.coreAudio("create failed")
        let manager = AggregateDeviceManager(client: client)

        XCTAssertThrowsError(try manager.createAggregateDevice(named: "Meeting Device", tapUID: "tap-uid")) { error in
            XCTAssertEqual(String(describing: error), "Core Audio error: create failed")
        }
        XCTAssertFalse(manager.isCreated)
    }

    func testDestroyAggregateDeviceIsIdempotentAndResetsState() throws {
        let client = FakeAggregateDeviceClient()
        client.createdDeviceID = 99
        let manager = AggregateDeviceManager(client: client)

        _ = try manager.createAggregateDevice(named: "Meeting Device", tapUID: "tap-uid")
        manager.destroyAggregateDevice()
        manager.destroyAggregateDevice()

        XCTAssertFalse(manager.isCreated)
        XCTAssertEqual(manager.aggregateDeviceID, AudioObjectID(kAudioObjectUnknown))
        XCTAssertEqual(client.destroyedDeviceIDs, [99])
    }
}

private final class FakeAggregateDeviceClient: AggregateDeviceClient {
    struct CreateCall {
        let name: String?
        let uid: String
        let tapUID: String?
        let isPrivate: Bool?
    }

    var createdDeviceID = AudioObjectID(1)
    var createError: Error?
    var createCalls: [CreateCall] = []
    var destroyedDeviceIDs: [AudioObjectID] = []

    func createAggregateDevice(description: [String: Any]) throws -> AudioObjectID {
        createCalls.append(CreateCall(
            name: description[kAudioAggregateDeviceNameKey as String] as? String,
            uid: description[kAudioAggregateDeviceUIDKey as String] as? String ?? "",
            tapUID: ((description[kAudioAggregateDeviceTapListKey as String] as? [[String: Any]])?.first)?[kAudioSubTapUIDKey as String] as? String,
            isPrivate: description[kAudioAggregateDeviceIsPrivateKey as String] as? Bool
        ))
        if let createError {
            throw createError
        }
        return createdDeviceID
    }

    func destroyAggregateDevice(_ deviceID: AudioObjectID) {
        destroyedDeviceIDs.append(deviceID)
    }
}
