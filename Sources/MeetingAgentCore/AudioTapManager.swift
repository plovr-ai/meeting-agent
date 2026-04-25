import CoreAudio
import Foundation

@available(macOS 14.2, *)
public final class AudioTapManager {
    public private(set) var tapID = AudioObjectID(kAudioObjectUnknown)
    public private(set) var tappedProcessCount = 0

    public var isRunning: Bool {
        tapID != AudioObjectID(kAudioObjectUnknown)
    }

    public init() {}

    public func createTap(for target: AudioCaptureTarget) throws -> AudioObjectID {
        guard !isRunning else {
            return tapID
        }

        let processObjectIDs = try CoreAudioHelpers.outputProcessObjectIDs(for: target)
        tappedProcessCount = processObjectIDs.count

        let description = CATapDescription()
        description.name = "MeetingAgent Tap: \(target.displayName)"
        description.processes = processObjectIDs
        description.isPrivate = true
        description.isExclusive = false
        description.isMixdown = true
        description.isMono = true
        description.muteBehavior = .unmuted

        var createdTapID = AudioObjectID(kAudioObjectUnknown)
        try CoreAudioHelpers.check(
            AudioHardwareCreateProcessTap(description, &createdTapID),
            "AudioHardwareCreateProcessTap"
        )

        tapID = createdTapID
        return createdTapID
    }

    public func tapUID() throws -> String {
        guard isRunning else {
            throw ProbeError.captureNotStarted
        }
        return try CoreAudioHelpers.stringProperty(objectID: tapID, selector: kAudioTapPropertyUID)
    }

    public func destroyTap() {
        guard isRunning else { return }
        AudioHardwareDestroyProcessTap(tapID)
        tapID = AudioObjectID(kAudioObjectUnknown)
        tappedProcessCount = 0
    }

    deinit {
        destroyTap()
    }
}
