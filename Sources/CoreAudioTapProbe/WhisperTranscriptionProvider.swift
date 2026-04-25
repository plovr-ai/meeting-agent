import Foundation

struct WhisperConfiguration: Equatable {
    let binaryURL: URL
    let modelURL: URL

    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> WhisperConfiguration {
        guard let binaryPath = nonBlank(environment["MEETING_AGENT_WHISPER_BIN"]) else {
            throw unavailable("MEETING_AGENT_WHISPER_BIN is not set")
        }
        guard let modelPath = nonBlank(environment["MEETING_AGENT_WHISPER_MODEL"]) else {
            throw unavailable("MEETING_AGENT_WHISPER_MODEL is not set")
        }

        let binaryURL = URL(fileURLWithPath: binaryPath)
        let modelURL = URL(fileURLWithPath: modelPath)

        guard fileManager.fileExists(atPath: binaryURL.path) else {
            throw unavailable("Whisper binary does not exist at \(binaryURL.path)")
        }
        guard fileManager.isExecutableFile(atPath: binaryURL.path) else {
            throw unavailable("Whisper binary is not executable at \(binaryURL.path)")
        }
        guard fileManager.fileExists(atPath: modelURL.path) else {
            throw unavailable("Whisper model does not exist at \(modelURL.path)")
        }
        guard fileManager.isReadableFile(atPath: modelURL.path) else {
            throw unavailable("Whisper model is not readable at \(modelURL.path)")
        }

        return WhisperConfiguration(binaryURL: binaryURL, modelURL: modelURL)
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func unavailable(_ reason: String) -> ProbeError {
        .speechRecognition("Whisper transcription unavailable: \(reason)")
    }
}

enum WhisperLanguageMapper {
    private static let knownCodes: [String: String] = [
        "zh-CN": "zh",
        "zh-TW": "zh",
        "en-US": "en",
        "ja-JP": "ja",
        "ko-KR": "ko",
        "fr-FR": "fr",
        "de-DE": "de",
        "es-ES": "es"
    ]

    static func languageCode(for localeIdentifier: String) -> String? {
        let trimmed = localeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let knownCode = knownCodes[trimmed] {
            return knownCode
        }
        let separators = CharacterSet(charactersIn: "-_")
        return trimmed.components(separatedBy: separators).first.flatMap { $0.isEmpty ? nil : $0 }
    }
}

protocol WhisperProcessRunning {
    func run(
        binaryURL: URL,
        modelURL: URL,
        inputWavURL: URL,
        outputBaseURL: URL,
        languageCode: String?
    ) throws
}

struct WhisperProcessRunner: WhisperProcessRunning {
    func run(
        binaryURL: URL,
        modelURL: URL,
        inputWavURL: URL,
        outputBaseURL: URL,
        languageCode: String?
    ) throws {
        let process = Process()
        process.executableURL = binaryURL
        process.arguments = Self.arguments(
            modelURL: modelURL,
            inputWavURL: inputWavURL,
            outputBaseURL: outputBaseURL,
            languageCode: languageCode
        )

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw ProbeError.speechRecognition("Whisper transcription unavailable: failed to launch whisper-cli: \(error)")
        }

        guard process.terminationStatus == 0 else {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = stderr.map { $0.isEmpty ? "" : ": \($0)" } ?? ""
            throw ProbeError.speechRecognition("Whisper transcription unavailable: whisper-cli exited with status \(process.terminationStatus)\(suffix)")
        }
    }

    static func arguments(
        modelURL: URL,
        inputWavURL: URL,
        outputBaseURL: URL,
        languageCode: String?
    ) -> [String] {
        var arguments = [
            "-m", modelURL.path,
            "-f", inputWavURL.path
        ]
        if let languageCode, !languageCode.isEmpty {
            arguments += ["-l", languageCode]
        }
        arguments += [
            "-otxt",
            "-of", outputBaseURL.path
        ]
        return arguments
    }
}
