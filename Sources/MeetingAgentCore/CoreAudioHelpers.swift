import CoreAudio
import Foundation

protocol CoreAudioClient {
    func getPropertyDataSize(
        objectID: AudioObjectID,
        address: inout AudioObjectPropertyAddress,
        qualifierDataSize: UInt32,
        qualifierData: UnsafeRawPointer?,
        dataSize: inout UInt32
    ) -> OSStatus

    func getPropertyData(
        objectID: AudioObjectID,
        address: inout AudioObjectPropertyAddress,
        qualifierDataSize: UInt32,
        qualifierData: UnsafeRawPointer?,
        dataSize: inout UInt32,
        data: UnsafeMutableRawPointer?
    ) -> OSStatus
}

struct SystemCoreAudioClient: CoreAudioClient {
    func getPropertyDataSize(
        objectID: AudioObjectID,
        address: inout AudioObjectPropertyAddress,
        qualifierDataSize: UInt32,
        qualifierData: UnsafeRawPointer?,
        dataSize: inout UInt32
    ) -> OSStatus {
        AudioObjectGetPropertyDataSize(objectID, &address, qualifierDataSize, qualifierData, &dataSize)
    }

    func getPropertyData(
        objectID: AudioObjectID,
        address: inout AudioObjectPropertyAddress,
        qualifierDataSize: UInt32,
        qualifierData: UnsafeRawPointer?,
        dataSize: inout UInt32,
        data: UnsafeMutableRawPointer?
    ) -> OSStatus {
        guard let data else { return kAudioHardwareBadObjectError }
        return AudioObjectGetPropertyData(objectID, &address, qualifierDataSize, qualifierData, &dataSize, data)
    }
}

enum CoreAudioHelpers {
    private static let defaultClient = SystemCoreAudioClient()

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

    static func stringProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        client: CoreAudioClient = defaultClient
    ) throws -> String {
        var address = propertyAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        try check(
            client.getPropertyData(objectID: objectID, address: &address, qualifierDataSize: 0, qualifierData: nil, dataSize: &size, data: &value),
            "AudioObjectGetPropertyData(\(selector))"
        )

        guard let value else {
            throw ProbeError.coreAudio("AudioObjectGetPropertyData(\(selector)) returned nil string")
        }

        return value.takeUnretainedValue() as String
    }

    static func processObjectID(
        for pid: pid_t,
        client: CoreAudioClient = defaultClient
    ) throws -> AudioObjectID {
        var address = propertyAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var qualifierPID = pid
        var processObjectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let qualifierSize = UInt32(MemoryLayout<pid_t>.size)

        try check(
            client.getPropertyData(
                objectID: AudioObjectID(kAudioObjectSystemObject),
                address: &address,
                qualifierDataSize: qualifierSize,
                qualifierData: &qualifierPID,
                dataSize: &size,
                data: &processObjectID
            ),
            "AudioObjectGetPropertyData(kAudioHardwarePropertyTranslatePIDToProcessObject)"
        )

        guard processObjectID != AudioObjectID(kAudioObjectUnknown) else {
            throw ProbeError.coreAudio("No Core Audio process object exists for pid \(pid)")
        }

        return processObjectID
    }

    static func outputProcessObjectIDs(
        for target: AudioCaptureTarget,
        client: CoreAudioClient = defaultClient
    ) throws -> [AudioObjectID] {
        let processObjectIDs = try audioProcessObjectList(client: client)
        let matchingProcesses = try processObjectIDs.filter { processObjectID in
            let pid = try pid(forProcessObjectID: processObjectID, client: client)
            if pid == target.processID {
                return true
            }

            guard try isRunningOutput(processObjectID: processObjectID, client: client) else {
                return false
            }

            guard let targetBundleID = target.bundleIdentifier,
                  let processBundleID = try bundleID(forProcessObjectID: processObjectID, client: client) else {
                return false
            }

            return bundleID(processBundleID, matchesCaptureBundleID: targetBundleID)
        }

        if !matchingProcesses.isEmpty {
            return matchingProcesses
        }

        return [try processObjectID(for: target.processID, client: client)]
    }

    static func isAudioOutputActive(
        for target: AudioCaptureTarget,
        client: CoreAudioClient = defaultClient
    ) -> Bool {
        do {
            let processObjectIDs = try audioProcessObjectList(client: client)
            return try processObjectIDs.contains { processObjectID in
                let pid = try pid(forProcessObjectID: processObjectID, client: client)
                if pid == target.processID {
                    return try isRunningOutput(processObjectID: processObjectID, client: client)
                }

                guard try isRunningOutput(processObjectID: processObjectID, client: client) else {
                    return false
                }

                guard let targetBundleID = target.bundleIdentifier,
                      let processBundleID = try bundleID(forProcessObjectID: processObjectID, client: client) else {
                    return false
                }

                return bundleID(processBundleID, matchesCaptureBundleID: targetBundleID)
            }
        } catch {
            return false
        }
    }

    static func bundleID(_ bundleID: String, matchesCaptureBundleID captureBundleID: String) -> Bool {
        bundleID == captureBundleID || bundleID.hasPrefix("\(captureBundleID).")
    }

    private static func audioProcessObjectList(client: CoreAudioClient) throws -> [AudioObjectID] {
        var address = propertyAddress(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0

        try check(
            client.getPropertyDataSize(
                objectID: AudioObjectID(kAudioObjectSystemObject),
                address: &address,
                qualifierDataSize: 0,
                qualifierData: nil,
                dataSize: &size
            ),
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
                client.getPropertyData(
                    objectID: AudioObjectID(kAudioObjectSystemObject),
                    address: &address,
                    qualifierDataSize: 0,
                    qualifierData: nil,
                    dataSize: &size,
                    data: baseAddress
                ),
                "AudioObjectGetPropertyData(kAudioHardwarePropertyProcessObjectList)"
            )
        }

        return processObjectIDs.filter { $0 != AudioObjectID(kAudioObjectUnknown) }
    }

    private static func pid(
        forProcessObjectID processObjectID: AudioObjectID,
        client: CoreAudioClient
    ) throws -> pid_t {
        var address = propertyAddress(kAudioProcessPropertyPID)
        var pid = pid_t(0)
        var size = UInt32(MemoryLayout<pid_t>.size)

        try check(
            client.getPropertyData(
                objectID: processObjectID,
                address: &address,
                qualifierDataSize: 0,
                qualifierData: nil,
                dataSize: &size,
                data: &pid
            ),
            "AudioObjectGetPropertyData(kAudioProcessPropertyPID)"
        )

        return pid
    }

    private static func bundleID(
        forProcessObjectID processObjectID: AudioObjectID,
        client: CoreAudioClient
    ) throws -> String? {
        var address = propertyAddress(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let status = client.getPropertyData(
            objectID: processObjectID,
            address: &address,
            qualifierDataSize: 0,
            qualifierData: nil,
            dataSize: &size,
            data: &value
        )
        guard status == noErr else {
            return nil
        }

        return value?.takeRetainedValue() as String?
    }

    private static func isRunningOutput(
        processObjectID: AudioObjectID,
        client: CoreAudioClient
    ) throws -> Bool {
        var address = propertyAddress(kAudioProcessPropertyIsRunningOutput)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)

        try check(
            client.getPropertyData(
                objectID: processObjectID,
                address: &address,
                qualifierDataSize: 0,
                qualifierData: nil,
                dataSize: &size,
                data: &value
            ),
            "AudioObjectGetPropertyData(kAudioProcessPropertyIsRunningOutput)"
        )

        return value != 0
    }
}
