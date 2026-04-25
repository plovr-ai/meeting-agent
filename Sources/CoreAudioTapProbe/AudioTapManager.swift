import CoreAudio
import Foundation

@available(macOS 14.2, *)
final class AudioTapManager {
    private(set) var tapID = AudioObjectID(kAudioObjectUnknown)

    var isRunning: Bool {
        tapID != AudioObjectID(kAudioObjectUnknown)
    }

    func createTap(for target: AudioCaptureTarget) throws -> AudioObjectID {
        guard !isRunning else {
            return tapID
        }

        let processObjectID = try CoreAudioHelpers.processObjectID(for: target.processID)

        let description = CATapDescription()
        description.name = "MeetingAgent Tap: \(target.displayName)"
        description.processes = [processObjectID]
        description.isPrivate = true
        description.isExclusive = true
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

    func tapUID() throws -> String {
        guard isRunning else {
            throw ProbeError.captureNotStarted
        }
        return try CoreAudioHelpers.stringProperty(objectID: tapID, selector: kAudioTapPropertyUID)
    }

    func destroyTap() {
        guard isRunning else { return }
        AudioHardwareDestroyProcessTap(tapID)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit {
        destroyTap()
    }
}
