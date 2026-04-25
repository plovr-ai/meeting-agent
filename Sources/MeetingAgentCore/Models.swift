import Foundation

public struct AudioCaptureTarget: Equatable, Identifiable {
    public var id: pid_t { processID }
    public let processID: pid_t
    public let displayName: String
    public let bundleIdentifier: String?
    public let isAudioOutputActive: Bool

    public init(
        processID: pid_t,
        displayName: String,
        bundleIdentifier: String?,
        isAudioOutputActive: Bool = true
    ) {
        self.processID = processID
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.isAudioOutputActive = isAudioOutputActive
    }
}

public struct RunningAppSnapshot: Equatable {
    public let processID: pid_t
    public let displayName: String?
    public let bundleIdentifier: String?

    public init(processID: pid_t, displayName: String?, bundleIdentifier: String?) {
        self.processID = processID
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
    }
}

public struct AudioFrame: Equatable {
    public let pcm: Data
    public let sampleRate: Double
    public let channelCount: Int
    public let timestampNanos: UInt64

    public init(pcm: Data, sampleRate: Double, channelCount: Int, timestampNanos: UInt64) {
        self.pcm = pcm
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.timestampNanos = timestampNanos
    }
}

public enum ProbeError: Error, CustomStringConvertible {
    case invalidArguments(String)
    case targetNotFound(pid_t)
    case coreAudio(String)
    case captureNotStarted
    case speechRecognition(String)

    public var description: String {
        switch self {
        case .invalidArguments(let message):
            return "Invalid arguments: \(message)"
        case .targetNotFound(let pid):
            return "No running process found for pid \(pid)"
        case .coreAudio(let message):
            return "Core Audio error: \(message)"
        case .captureNotStarted:
            return "Capture has not started"
        case .speechRecognition(let message):
            return "Speech recognition error: \(message)"
        }
    }
}
