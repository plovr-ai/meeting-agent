import Foundation

public enum AudioCaptureSourceKind: String, Codable, Equatable {
    case process
    case microphone
}

public enum AudioCaptureSource: Equatable {
    public static let microphoneProcessID: pid_t = -1

    case process(AudioCaptureTarget)
    case microphone(displayName: String = "Computer Microphone")

    public var kind: AudioCaptureSourceKind {
        switch self {
        case .process:
            return .process
        case .microphone:
            return .microphone
        }
    }

    public var displayName: String {
        switch self {
        case .process(let target):
            return target.displayName
        case .microphone(let displayName):
            return displayName
        }
    }

    public var processID: pid_t {
        switch self {
        case .process(let target):
            return target.processID
        case .microphone:
            return Self.microphoneProcessID
        }
    }

    public var processTarget: AudioCaptureTarget? {
        switch self {
        case .process(let target):
            return target
        case .microphone:
            return nil
        }
    }
}
