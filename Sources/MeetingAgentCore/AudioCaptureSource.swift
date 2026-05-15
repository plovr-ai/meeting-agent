import Foundation

public enum AudioCaptureSourceKind: String, Codable, Equatable {
    case process
    case microphone
    case processWithMicrophone
}

public enum AudioCaptureSource: Equatable {
    public static let microphoneProcessID: pid_t = -1

    case process(AudioCaptureTarget)
    case microphone(displayName: String = "Computer Microphone")
    case processWithMicrophone(AudioCaptureTarget, microphoneDisplayName: String = "Computer Microphone")

    public var kind: AudioCaptureSourceKind {
        switch self {
        case .process:
            return .process
        case .microphone:
            return .microphone
        case .processWithMicrophone:
            return .processWithMicrophone
        }
    }

    public var displayName: String {
        switch self {
        case .process(let target):
            return target.displayName
        case .microphone(let displayName):
            return displayName
        case .processWithMicrophone(let target, _):
            return target.displayName
        }
    }

    public var processID: pid_t {
        switch self {
        case .process(let target):
            return target.processID
        case .microphone:
            return Self.microphoneProcessID
        case .processWithMicrophone(let target, _):
            return target.processID
        }
    }

    public var processTarget: AudioCaptureTarget? {
        switch self {
        case .process(let target):
            return target
        case .microphone:
            return nil
        case .processWithMicrophone(let target, _):
            return target
        }
    }

    public var microphoneDisplayName: String {
        switch self {
        case .process:
            return "Computer Microphone"
        case .microphone(let displayName):
            return displayName
        case .processWithMicrophone(_, let microphoneDisplayName):
            return microphoneDisplayName
        }
    }
}
