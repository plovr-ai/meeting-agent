import CoreAudio
import Foundation

@available(macOS 14.2, *)
public protocol AudioTapClient {
    func outputProcessObjectIDs(for target: AudioCaptureTarget) throws -> [AudioObjectID]
    func createProcessTap(description: CATapDescription) throws -> AudioObjectID
    func tapUID(for tapID: AudioObjectID) throws -> String
    func destroyProcessTap(_ tapID: AudioObjectID)
}

@available(macOS 14.2, *)
public struct SystemAudioTapClient: AudioTapClient {
    public init() {}

    public func outputProcessObjectIDs(for target: AudioCaptureTarget) throws -> [AudioObjectID] {
        try CoreAudioHelpers.outputProcessObjectIDs(for: target)
    }

    public func createProcessTap(description: CATapDescription) throws -> AudioObjectID {
        var createdTapID = AudioObjectID(kAudioObjectUnknown)
        try CoreAudioHelpers.check(
            AudioHardwareCreateProcessTap(description, &createdTapID),
            "AudioHardwareCreateProcessTap"
        )
        return createdTapID
    }

    public func tapUID(for tapID: AudioObjectID) throws -> String {
        try CoreAudioHelpers.stringProperty(objectID: tapID, selector: kAudioTapPropertyUID)
    }

    public func destroyProcessTap(_ tapID: AudioObjectID) {
        AudioHardwareDestroyProcessTap(tapID)
    }
}

@available(macOS 14.2, *)
public protocol AudioTapManaging: AnyObject {
    func createTap(for target: AudioCaptureTarget) throws -> AudioObjectID
    func tapUID() throws -> String
    func destroyTap()
}

@available(macOS 14.2, *)
public final class AudioTapManager {
    public private(set) var tapID = AudioObjectID(kAudioObjectUnknown)
    public private(set) var tappedProcessCount = 0
    private let client: AudioTapClient

    public var isRunning: Bool {
        tapID != AudioObjectID(kAudioObjectUnknown)
    }

    public init(client: AudioTapClient = SystemAudioTapClient()) {
        self.client = client
    }

    public func createTap(for target: AudioCaptureTarget) throws -> AudioObjectID {
        guard !isRunning else {
            return tapID
        }

        let processObjectIDs = try client.outputProcessObjectIDs(for: target)
        tappedProcessCount = processObjectIDs.count

        let description = CATapDescription()
        description.name = "MeetingAgent Tap: \(target.displayName)"
        description.processes = processObjectIDs
        description.isPrivate = true
        description.isExclusive = false
        description.isMixdown = true
        description.isMono = true
        description.muteBehavior = .unmuted

        let createdTapID = try client.createProcessTap(description: description)

        tapID = createdTapID
        return createdTapID
    }

    public func tapUID() throws -> String {
        guard isRunning else {
            throw ProbeError.captureNotStarted
        }
        return try client.tapUID(for: tapID)
    }

    public func destroyTap() {
        guard isRunning else { return }
        client.destroyProcessTap(tapID)
        tapID = AudioObjectID(kAudioObjectUnknown)
        tappedProcessCount = 0
    }

    deinit {
        destroyTap()
    }
}

@available(macOS 14.2, *)
extension AudioTapManager: AudioTapManaging {}
