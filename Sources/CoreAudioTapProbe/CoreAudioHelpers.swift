import CoreAudio
import Foundation

enum CoreAudioHelpers {
    static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw ProbeError.coreAudio("\(operation) failed with OSStatus \(status)")
        }
    }

    static func propertyAddress(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
    }

    static func stringProperty(objectID: AudioObjectID, selector: AudioObjectPropertySelector) throws -> String {
        var address = propertyAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        try check(
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value),
            "AudioObjectGetPropertyData(\(selector))"
        )

        guard let value else {
            throw ProbeError.coreAudio("AudioObjectGetPropertyData(\(selector)) returned nil string")
        }

        return value.takeUnretainedValue() as String
    }

    static func processObjectID(for pid: pid_t) throws -> AudioObjectID {
        var address = propertyAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var qualifierPID = pid
        var processObjectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let qualifierSize = UInt32(MemoryLayout<pid_t>.size)

        try check(
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                qualifierSize,
                &qualifierPID,
                &size,
                &processObjectID
            ),
            "AudioObjectGetPropertyData(kAudioHardwarePropertyTranslatePIDToProcessObject)"
        )

        guard processObjectID != AudioObjectID(kAudioObjectUnknown) else {
            throw ProbeError.coreAudio("No Core Audio process object exists for pid \(pid)")
        }

        return processObjectID
    }
}
