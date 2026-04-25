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

    static func outputProcessObjectIDs(for target: AudioCaptureTarget) throws -> [AudioObjectID] {
        let processObjectIDs = try audioProcessObjectList()
        let matchingProcesses = try processObjectIDs.filter { processObjectID in
            let pid = try pid(forProcessObjectID: processObjectID)
            if pid == target.processID {
                return true
            }

            guard try isRunningOutput(processObjectID: processObjectID) else {
                return false
            }

            guard let targetBundleID = target.bundleIdentifier,
                  let processBundleID = try bundleID(forProcessObjectID: processObjectID) else {
                return false
            }

            return bundleID(processBundleID, matchesCaptureBundleID: targetBundleID)
        }

        if !matchingProcesses.isEmpty {
            return matchingProcesses
        }

        return [try processObjectID(for: target.processID)]
    }

    static func bundleID(_ bundleID: String, matchesCaptureBundleID captureBundleID: String) -> Bool {
        bundleID == captureBundleID || bundleID.hasPrefix("\(captureBundleID).")
    }

    private static func audioProcessObjectList() throws -> [AudioObjectID] {
        var address = propertyAddress(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0

        try check(
            AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size),
            "AudioObjectGetPropertyDataSize(kAudioHardwarePropertyProcessObjectList)"
        )

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else {
            return []
        }

        var processObjectIDs = Array(repeating: AudioObjectID(kAudioObjectUnknown), count: count)

        try processObjectIDs.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return
            }

            try check(
                AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, baseAddress),
                "AudioObjectGetPropertyData(kAudioHardwarePropertyProcessObjectList)"
            )
        }

        return processObjectIDs.filter { $0 != AudioObjectID(kAudioObjectUnknown) }
    }

    private static func pid(forProcessObjectID processObjectID: AudioObjectID) throws -> pid_t {
        var address = propertyAddress(kAudioProcessPropertyPID)
        var pid = pid_t(0)
        var size = UInt32(MemoryLayout<pid_t>.size)

        try check(
            AudioObjectGetPropertyData(processObjectID, &address, 0, nil, &size, &pid),
            "AudioObjectGetPropertyData(kAudioProcessPropertyPID)"
        )

        return pid
    }

    private static func bundleID(forProcessObjectID processObjectID: AudioObjectID) throws -> String? {
        var address = propertyAddress(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let status = AudioObjectGetPropertyData(processObjectID, &address, 0, nil, &size, &value)
        guard status == noErr else {
            return nil
        }

        return value?.takeRetainedValue() as String?
    }

    private static func isRunningOutput(processObjectID: AudioObjectID) throws -> Bool {
        var address = propertyAddress(kAudioProcessPropertyIsRunningOutput)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)

        try check(
            AudioObjectGetPropertyData(processObjectID, &address, 0, nil, &size, &value),
            "AudioObjectGetPropertyData(kAudioProcessPropertyIsRunningOutput)"
        )

        return value != 0
    }
}
