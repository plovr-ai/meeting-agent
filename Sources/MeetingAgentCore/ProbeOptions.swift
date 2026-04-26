import Foundation

public struct ProbeOptions {
    public let listOnly: Bool
    public let pid: pid_t?
    public let seconds: Int
    public let wavPath: String?
    public let speechProvider: SpeechProvider
    public let speechLocaleIdentifier: String
    public let targetLocaleIdentifier: String
    public let bilingualPipelineProfileID: String

    public init(arguments: [String]) throws {
        listOnly = arguments.isEmpty || arguments.contains("--list")

        var parsedPID: pid_t?
        var parsedSeconds = 10
        var parsedWavPath: String?
        var parsedSpeechProvider = SpeechProvider.whisper
        var parsedSpeechLocaleIdentifier = "en-US"
        var parsedTargetLocaleIdentifier = "zh-CN"
        var parsedBilingualPipelineProfileID = "local-whisper-hosted-translation"

        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--list":
                index += 1
            case "--pid":
                guard index + 1 < arguments.count, let value = Int32(arguments[index + 1]) else {
                    throw ProbeError.invalidArguments("--pid requires an integer process id")
                }
                parsedPID = value
                index += 2
            case "--seconds":
                guard index + 1 < arguments.count, let value = Int(arguments[index + 1]), value > 0 else {
                    throw ProbeError.invalidArguments("--seconds requires a positive integer")
                }
                parsedSeconds = value
                index += 2
            case "--wav":
                if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                    parsedWavPath = arguments[index + 1]
                    index += 2
                } else {
                    parsedWavPath = ""
                    index += 1
                }
            case "--stt-locale":
                guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                    throw ProbeError.invalidArguments("--stt-locale requires a locale identifier such as en-US or zh-CN")
                }
                parsedSpeechLocaleIdentifier = arguments[index + 1]
                index += 2
            case "--stt-provider":
                guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                    throw ProbeError.invalidArguments("--stt-provider requires one of: \(SpeechProvider.supportedValuesDescription)")
                }
                guard let provider = SpeechProvider(rawValue: arguments[index + 1]) else {
                    throw ProbeError.invalidArguments("Unsupported --stt-provider \(arguments[index + 1]). Supported providers: \(SpeechProvider.supportedValuesDescription)")
                }
                parsedSpeechProvider = provider
                index += 2
            case "--target-locale":
                guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                    throw ProbeError.invalidArguments("--target-locale requires a locale identifier such as zh-CN or ja-JP")
                }
                parsedTargetLocaleIdentifier = arguments[index + 1]
                index += 2
            case "--bilingual-profile":
                guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                    throw ProbeError.invalidArguments("--bilingual-profile requires a pipeline profile id")
                }
                parsedBilingualPipelineProfileID = arguments[index + 1]
                index += 2
            default:
                throw ProbeError.invalidArguments("Unknown argument \(arg)")
            }
        }

        pid = parsedPID
        seconds = parsedSeconds
        wavPath = parsedWavPath
        speechProvider = parsedSpeechProvider
        speechLocaleIdentifier = parsedSpeechLocaleIdentifier
        targetLocaleIdentifier = parsedTargetLocaleIdentifier
        bilingualPipelineProfileID = parsedBilingualPipelineProfileID
    }
}
