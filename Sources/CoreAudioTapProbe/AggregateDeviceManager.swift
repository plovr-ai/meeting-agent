import CoreAudio
import Foundation

final class AggregateDeviceManager {
    private(set) var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private let deviceUID = "com.meetingagent.CoreAudioTapProbe.aggregate.\(UUID().uuidString)"

    var isCreated: Bool {
        aggregateDeviceID != AudioObjectID(kAudioObjectUnknown)
    }

    func createAggregateDevice(named name: String) throws -> AudioObjectID {
        guard !isCreated else {
            return aggregateDeviceID
        }

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: name,
            kAudioAggregateDeviceUIDKey as String: deviceUID,
            kAudioAggregateDeviceIsPrivateKey as String: true
        ]

        var createdID = AudioObjectID(kAudioObjectUnknown)
        try CoreAudioHelpers.check(
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &createdID),
            "AudioHardwareCreateAggregateDevice"
        )

        aggregateDeviceID = createdID
        return createdID
    }

    func attachTapUID(_ tapUID: String) throws {
        guard isCreated else {
            throw ProbeError.captureNotStarted
        }

        var address = CoreAudioHelpers.propertyAddress(kAudioAggregateDevicePropertyTapList)
        var tapList = [tapUID as CFString] as CFArray
        let size = UInt32(MemoryLayout<CFArray>.size)

        try CoreAudioHelpers.check(
            AudioObjectSetPropertyData(aggregateDeviceID, &address, 0, nil, size, &tapList),
            "AudioObjectSetPropertyData(kAudioAggregateDevicePropertyTapList)"
        )
    }

    func destroyAggregateDevice() {
        guard isCreated else { return }
        AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit {
        destroyAggregateDevice()
    }
}
