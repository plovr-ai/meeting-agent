import CoreAudio
import Foundation

public protocol AggregateDeviceClient {
    func createAggregateDevice(description: [String: Any]) throws -> AudioObjectID
    func destroyAggregateDevice(_ deviceID: AudioObjectID)
}

public struct SystemAggregateDeviceClient: AggregateDeviceClient {
    public init() {}

    public func createAggregateDevice(description: [String: Any]) throws -> AudioObjectID {
        var createdID = AudioObjectID(kAudioObjectUnknown)
        try CoreAudioHelpers.check(
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &createdID),
            "AudioHardwareCreateAggregateDevice"
        )
        return createdID
    }

    public func destroyAggregateDevice(_ deviceID: AudioObjectID) {
        AudioHardwareDestroyAggregateDevice(deviceID)
    }
}

public protocol AggregateDeviceManaging: AnyObject {
    func createAggregateDevice(named name: String, tapUID: String) throws -> AudioObjectID
    func destroyAggregateDevice()
}

public final class AggregateDeviceManager {
    public private(set) var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private let deviceUID = "com.meetingagent.MeetingAgentApp.aggregate.\(UUID().uuidString)"
    private let client: AggregateDeviceClient

    public var isCreated: Bool {
        aggregateDeviceID != AudioObjectID(kAudioObjectUnknown)
    }

    public init(client: AggregateDeviceClient = SystemAggregateDeviceClient()) {
        self.client = client
    }

    public func createAggregateDevice(named name: String, tapUID: String) throws -> AudioObjectID {
        guard !isCreated else {
            return aggregateDeviceID
        }

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: name,
            kAudioAggregateDeviceUIDKey as String: deviceUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: tapUID
                ]
            ]
        ]

        let createdID = try client.createAggregateDevice(description: description)

        aggregateDeviceID = createdID
        return createdID
    }

    public func destroyAggregateDevice() {
        guard isCreated else { return }
        client.destroyAggregateDevice(aggregateDeviceID)
        aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit {
        destroyAggregateDevice()
    }
}

extension AggregateDeviceManager: AggregateDeviceManaging {}
