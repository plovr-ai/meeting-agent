import Foundation

struct AudioCaptureTarget: Equatable, Identifiable {
    var id: pid_t { processID }
    let processID: pid_t
    let displayName: String
    let bundleIdentifier: String?
}

struct RunningAppSnapshot: Equatable {
    let processID: pid_t
    let displayName: String?
    let bundleIdentifier: String?
}

struct AudioFrame: Equatable {
    let pcm: Data
    let sampleRate: Double
    let channelCount: Int
    let timestampNanos: UInt64
}

enum ProbeError: Error, CustomStringConvertible {
    case invalidArguments(String)
    case targetNotFound(pid_t)
    case coreAudio(String)
    case captureNotStarted
    case speechRecognition(String)

    var description: String {
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
