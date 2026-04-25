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
    private let configuration: WhisperConfiguration
    private let processRunner: WhisperProcessRunning
    private let languageCode: String?
    private let chunkDurationSeconds: Double
    private var chunkFrames: [AudioFrame] = []
    private var pendingChunkDurationSeconds = 0.0
    private var chunkIndex = 0
    private var transcriptParts: [String] = []
    private var isFinished = false

    private init(
        transcriptURL: URL,
        temporaryDirectory: URL,
        configuration: WhisperConfiguration,
        processRunner: WhisperProcessRunning,
        languageCode: String?,
        chunkDurationSeconds: Double
    ) {
        self.transcriptURL = transcriptURL
        self.temporaryDirectory = temporaryDirectory
        self.configuration = configuration
        self.processRunner = processRunner
        self.languageCode = languageCode
        self.chunkDurationSeconds = max(0.001, chunkDurationSeconds)
    }

    static func start(
        transcriptURL: URL,
        localeIdentifier: String,
        configuration: WhisperConfiguration,
        processRunner: WhisperProcessRunning,
        workingDirectory: URL = FileManager.default.temporaryDirectory,
        chunkDurationSeconds: Double = 3
    ) throws -> WhisperCLITranscriber {
        let temporaryDirectory = workingDirectory.appendingPathComponent("meeting-agent-whisper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        return WhisperCLITranscriber(
            transcriptURL: transcriptURL,
            temporaryDirectory: temporaryDirectory,
            configuration: configuration,
            processRunner: processRunner,
            languageCode: WhisperLanguageMapper.languageCode(for: localeIdentifier),
            chunkDurationSeconds: chunkDurationSeconds
        )
    }

    func append(_ frame: AudioFrame) throws {
        guard !isFinished else { return }

        chunkFrames.append(frame)
        pendingChunkDurationSeconds += Self.durationSeconds(for: frame)

        if pendingChunkDurationSeconds >= chunkDurationSeconds {
            try transcribePendingChunk()
        }
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true

        do {
            guard !chunkFrames.isEmpty || !transcriptParts.isEmpty else {
                throw ProbeError.speechRecognition("Whisper transcription unavailable: no audio frames were captured")
            }
            if !chunkFrames.isEmpty {
                try transcribePendingChunk()
            }
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

    private func transcribePendingChunk() throws {
        guard !chunkFrames.isEmpty else { return }

        let chunkID = chunkIndex
        chunkIndex += 1

        let inputWavURL = temporaryDirectory.appendingPathComponent("input-\(chunkID).wav")
        let outputBaseURL = temporaryDirectory.appendingPathComponent("transcript-\(chunkID)")
        let outputTextURL = outputBaseURL.appendingPathExtension("txt")

        let firstFrame = chunkFrames[0]
        let writer = try WavFileWriter(
            url: inputWavURL,
            sampleRate: UInt32(firstFrame.sampleRate.rounded()),
            channelCount: UInt16(firstFrame.channelCount)
        )
        for frame in chunkFrames {
            try writer.append(frame)
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

        let transcript = normalizedTranscript(
            try String(contentsOf: outputTextURL, encoding: .utf8)
        )
        if !transcript.isEmpty {
            transcriptParts.append(transcript)
            try TranscriptFileWriter(url: transcriptURL).replace(with: transcriptParts.joined(separator: "\n"))
        }

        chunkFrames.removeAll(keepingCapacity: true)
        pendingChunkDurationSeconds = 0
        try? FileManager.default.removeItem(at: inputWavURL)
        try? FileManager.default.removeItem(at: outputTextURL)
    }

    private static func durationSeconds(for frame: AudioFrame) -> Double {
        let bytesPerFrame = max(1, frame.channelCount) * MemoryLayout<Int16>.size
        let frameCount = frame.pcm.count / bytesPerFrame
        guard frame.sampleRate > 0 else { return 0 }
        return Double(frameCount) / frame.sampleRate
    }

    private func normalizedTranscript(_ text: String) -> String {
        text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { $0.caseInsensitiveCompare("[BLANK_AUDIO]") != .orderedSame }
            .joined(separator: "\n")
    }
}
