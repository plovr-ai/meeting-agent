import CoreAudio
import Foundation

public final class AggregateDeviceManager {
    public private(set) var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private let deviceUID = "com.meetingagent.CoreAudioTapProbe.aggregate.\(UUID().uuidString)"

    public var isCreated: Bool {
        aggregateDeviceID != AudioObjectID(kAudioObjectUnknown)
    }

    public init() {}

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

        var createdID = AudioObjectID(kAudioObjectUnknown)
        try CoreAudioHelpers.check(
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &createdID),
            "AudioHardwareCreateAggregateDevice"
        )

        aggregateDeviceID = createdID
        return createdID
    }

    public func destroyAggregateDevice() {
        guard isCreated else { return }
        AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit {
        destroyAggregateDevice()
    }
}
