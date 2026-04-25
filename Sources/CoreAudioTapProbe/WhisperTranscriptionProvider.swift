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

struct WhisperSpeechTranscriptionProvider: SpeechTranscriptionProvider {
    let provider: SpeechProvider = .whisper

    func start(transcriptURL: URL, localeIdentifier: String) async throws -> AudioFrameTranscriber {
        let configuration = try WhisperConfiguration.fromEnvironment()
        return try WhisperCLITranscriber.start(
            transcriptURL: transcriptURL,
            localeIdentifier: localeIdentifier,
            configuration: configuration,
            processRunner: WhisperProcessRunner()
        )
    }
}

final class WhisperCLITranscriber: AudioFrameTranscriber {
    private let transcriptURL: URL
    private let temporaryDirectory: URL
    private let inputWavURL: URL
    private let outputBaseURL: URL
    private let outputTextURL: URL
    private let configuration: WhisperConfiguration
    private let processRunner: WhisperProcessRunning
    private let languageCode: String?
    private var writer: WavFileWriter?
    private var isFinished = false

    private init(
        transcriptURL: URL,
        temporaryDirectory: URL,
        inputWavURL: URL,
        outputBaseURL: URL,
        configuration: WhisperConfiguration,
        processRunner: WhisperProcessRunning,
        languageCode: String?
    ) {
        self.transcriptURL = transcriptURL
        self.temporaryDirectory = temporaryDirectory
        self.inputWavURL = inputWavURL
        self.outputBaseURL = outputBaseURL
        outputTextURL = outputBaseURL.appendingPathExtension("txt")
        self.configuration = configuration
        self.processRunner = processRunner
        self.languageCode = languageCode
    }

    static func start(
        transcriptURL: URL,
        localeIdentifier: String,
        configuration: WhisperConfiguration,
        processRunner: WhisperProcessRunning,
        workingDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> WhisperCLITranscriber {
        let temporaryDirectory = workingDirectory.appendingPathComponent("meeting-agent-whisper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let inputWavURL = temporaryDirectory.appendingPathComponent("input.wav")
        let outputBaseURL = temporaryDirectory.appendingPathComponent("transcript")

        return WhisperCLITranscriber(
            transcriptURL: transcriptURL,
            temporaryDirectory: temporaryDirectory,
            inputWavURL: inputWavURL,
            outputBaseURL: outputBaseURL,
            configuration: configuration,
            processRunner: processRunner,
            languageCode: WhisperLanguageMapper.languageCode(for: localeIdentifier)
        )
    }

    func append(_ frame: AudioFrame) throws {
        if writer == nil {
            writer = try WavFileWriter(
                url: inputWavURL,
                sampleRate: UInt32(frame.sampleRate.rounded()),
                channelCount: UInt16(frame.channelCount)
            )
        }
        try writer?.append(frame)
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true

        do {
            guard let writer else {
                throw ProbeError.speechRecognition("Whisper transcription unavailable: no audio frames were captured")
            }
            try writer.close()
            try processRunner.run(
                binaryURL: configuration.binaryURL,
                modelURL: configuration.modelURL,
                inputWavURL: inputWavURL,
                outputBaseURL: outputBaseURL,
                languageCode: languageCode
            )
            guard FileManager.default.fileExists(atPath: outputTextURL.path) else {
                throw ProbeError.speechRecognition("Whisper transcription unavailable: expected output file was not created")
            }
            let transcript = try String(contentsOf: outputTextURL, encoding: .utf8)
            try TranscriptFileWriter(url: transcriptURL).replace(with: transcript.trimmingCharacters(in: .newlines))
        } catch {
            try? TranscriptFileWriter(url: transcriptURL).replace(with: failureMessage(for: error))
        }

        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    deinit {
        finish()
    }

    private func failureMessage(for error: Error) -> String {
        let description = String(describing: error)
        let prefix = "Speech recognition error: "
        if description.hasPrefix(prefix) {
            return String(description.dropFirst(prefix.count))
        }
        return "Whisper transcription unavailable: \(description)"
    }
}
