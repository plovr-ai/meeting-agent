import CoreAudio
import XCTest
@testable import MeetingAgentCore

final class CoreAudioHelpersTests: XCTestCase {
    func testBundleMatcherIncludesMainBundleAndHelpers() {
        XCTAssertTrue(CoreAudioHelpers.bundleID("com.google.Chrome", matchesCaptureBundleID: "com.google.Chrome"))
        XCTAssertTrue(CoreAudioHelpers.bundleID("com.google.Chrome.helper", matchesCaptureBundleID: "com.google.Chrome"))
        XCTAssertTrue(CoreAudioHelpers.bundleID("com.electron.lark.helper", matchesCaptureBundleID: "com.electron.lark"))
    }

    func testBundleMatcherRejectsUnrelatedBundles() {
        XCTAssertFalse(CoreAudioHelpers.bundleID("com.apple.Safari", matchesCaptureBundleID: "com.google.Chrome"))
        XCTAssertFalse(CoreAudioHelpers.bundleID("com.google.ChromeCanary", matchesCaptureBundleID: "com.google.Chrome"))
    }

    func testReadsStringPropertyThroughInjectedCoreAudioClient() throws {
        let client = FakeCoreAudioClient()
        client.strings[42] = "tap-uid"

        let output = try CoreAudioHelpers.stringProperty(
            objectID: 42,
            selector: kAudioTapPropertyUID,
            client: client
        )

        XCTAssertEqual(output, "tap-uid")
    }

    func testStringPropertyReportsNilString() {
        let client = FakeCoreAudioClient()

        XCTAssertThrowsError(try CoreAudioHelpers.stringProperty(
            objectID: 42,
            selector: kAudioTapPropertyUID,
            client: client
        )) { error in
            XCTAssertTrue(String(describing: error).contains("returned nil string"))
        }
    }

    func testProcessObjectIDTranslatesPIDAndRejectsUnknownObject() throws {
        let client = FakeCoreAudioClient()
        client.translatedProcessObjectID = 99

        XCTAssertEqual(try CoreAudioHelpers.processObjectID(for: 123, client: client), 99)

        client.translatedProcessObjectID = AudioObjectID(kAudioObjectUnknown)
        XCTAssertThrowsError(try CoreAudioHelpers.processObjectID(for: 123, client: client)) { error in
            XCTAssertTrue(String(describing: error).contains("No Core Audio process object exists"))
        }
    }

    func testOutputProcessObjectIDsIncludeTargetAndMatchingBundleHelpers() throws {
        let client = FakeCoreAudioClient()
        client.processObjectIDs = [10, 20, AudioObjectID(kAudioObjectUnknown), 30]
        client.pids = [10: 111, 20: 222, 30: 333]
        client.runningOutput = [10: true, 20: true, 30: false]
        client.bundleIDs = [10: "com.video.Meet.helper", 20: "com.other.App", 30: "com.video.Meet"]
        let target = AudioCaptureTarget(
            processID: 222,
            displayName: "Meet",
            bundleIdentifier: "com.video.Meet"
        )

        let output = try CoreAudioHelpers.outputProcessObjectIDs(for: target, client: client)

        XCTAssertEqual(output, [10, 20])
    }

    func testOutputProcessObjectIDsFallsBackToTranslatedTargetPID() throws {
        let client = FakeCoreAudioClient()
        client.processObjectIDs = [10]
        client.pids = [10: 111]
        client.runningOutput = [10: false]
        client.translatedProcessObjectID = 88
        let target = AudioCaptureTarget(
            processID: 222,
            displayName: "Meet",
            bundleIdentifier: "com.video.Meet"
        )

        let output = try CoreAudioHelpers.outputProcessObjectIDs(for: target, client: client)

        XCTAssertEqual(output, [88])
    }

    func testAudioOutputActiveHandlesDirectAndBundleMatchesAndErrors() {
        let target = AudioCaptureTarget(
            processID: 222,
            displayName: "Meet",
            bundleIdentifier: "com.video.Meet"
        )
        let direct = FakeCoreAudioClient()
        direct.processObjectIDs = [10]
        direct.pids = [10: 222]
        direct.runningOutput = [10: true]
        XCTAssertTrue(CoreAudioHelpers.isAudioOutputActive(for: target, client: direct))

        let helper = FakeCoreAudioClient()
        helper.processObjectIDs = [20]
        helper.pids = [20: 333]
        helper.runningOutput = [20: true]
        helper.bundleIDs = [20: "com.video.Meet.helper"]
        XCTAssertTrue(CoreAudioHelpers.isAudioOutputActive(for: target, client: helper))

        let failing = FakeCoreAudioClient()
        failing.statusBySelector[kAudioHardwarePropertyProcessObjectList] = -1
        XCTAssertFalse(CoreAudioHelpers.isAudioOutputActive(for: target, client: failing))
    }
}

private final class FakeCoreAudioClient: CoreAudioClient {
    var statusBySelector: [AudioObjectPropertySelector: OSStatus] = [:]
    var strings: [AudioObjectID: String] = [:]
    var translatedProcessObjectID = AudioObjectID(kAudioObjectUnknown)
    var processObjectIDs: [AudioObjectID] = []
    var pids: [AudioObjectID: pid_t] = [:]
    var bundleIDs: [AudioObjectID: String] = [:]
    var runningOutput: [AudioObjectID: Bool] = [:]

    func getPropertyDataSize(
        objectID: AudioObjectID,
        address: inout AudioObjectPropertyAddress,
        qualifierDataSize: UInt32,
        qualifierData: UnsafeRawPointer?,
        dataSize: inout UInt32
    ) -> OSStatus {
        if let status = statusBySelector[address.mSelector] {
            return status
        }
        if address.mSelector == kAudioHardwarePropertyProcessObjectList {
            dataSize = UInt32(processObjectIDs.count * MemoryLayout<AudioObjectID>.size)
        }
        return noErr
    }

    func getPropertyData(
        objectID: AudioObjectID,
        address: inout AudioObjectPropertyAddress,
        qualifierDataSize: UInt32,
        qualifierData: UnsafeRawPointer?,
        dataSize: inout UInt32,
        data: UnsafeMutableRawPointer?
    ) -> OSStatus {
        if let status = statusBySelector[address.mSelector] {
            return status
        }

        switch address.mSelector {
        case kAudioTapPropertyUID:
            guard let data, let value = strings[objectID] else { return noErr }
            data.assumingMemoryBound(to: Optional<Unmanaged<CFString>>.self).pointee = Unmanaged.passRetained(value as CFString)
        case kAudioHardwarePropertyTranslatePIDToProcessObject:
            data?.assumingMemoryBound(to: AudioObjectID.self).pointee = translatedProcessObjectID
        case kAudioHardwarePropertyProcessObjectList:
            guard let data else { return noErr }
            let typed = data.assumingMemoryBound(to: AudioObjectID.self)
            for (index, id) in processObjectIDs.enumerated() {
                typed[index] = id
            }
        case kAudioProcessPropertyPID:
            data?.assumingMemoryBound(to: pid_t.self).pointee = pids[objectID] ?? 0
        case kAudioProcessPropertyBundleID:
            guard let data, let value = bundleIDs[objectID] else { return -1 }
            data.assumingMemoryBound(to: Optional<Unmanaged<CFString>>.self).pointee = Unmanaged.passRetained(value as CFString)
        case kAudioProcessPropertyIsRunningOutput:
            data?.assumingMemoryBound(to: UInt32.self).pointee = runningOutput[objectID] == true ? 1 : 0
        default:
            return -1
        }
        return noErr
    }
}
