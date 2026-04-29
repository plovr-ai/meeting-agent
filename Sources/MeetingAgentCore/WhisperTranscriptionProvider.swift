import Foundation

struct WhisperConfiguration: Equatable {
    let binaryURL: URL
    let modelURL: URL

    static func fromAppConfiguration(
        _ configuration: SpeechTranscriptionConfiguration,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        bundledResourceURL: URL? = Bundle.main.resourceURL,
        developmentResourceSearchRoots: [URL] = [URL(fileURLWithPath: FileManager.default.currentDirectoryPath)]
    ) throws -> WhisperConfiguration {
        guard let binaryPath = WhisperConfigurationResolver.binaryPath(
            explicitPath: configuration.whisperBinaryPath,
            environment: environment,
            fileManager: fileManager
        ) else {
            throw unavailable("Whisper binary path is not configured")
        }
        guard let modelPath = WhisperConfigurationResolver.modelPath(
            explicitPath: configuration.whisperModelPath,
            environment: environment,
            fileManager: fileManager,
            bundledResourceURL: bundledResourceURL,
            developmentResourceSearchRoots: developmentResourceSearchRoots
        ) else {
            throw unavailable("Whisper model path is not configured")
        }
        return try validated(binaryPath: binaryPath, modelPath: modelPath, fileManager: fileManager)
    }

    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> WhisperConfiguration {
        guard let binaryPath = WhisperConfigurationResolver.binaryPath(
            explicitPath: nil,
            environment: environment,
            fileManager: fileManager
        ) else {
            throw unavailable("MEETING_AGENT_WHISPER_BIN is not set")
        }
        guard let modelPath = WhisperConfigurationResolver.modelPath(
            explicitPath: nil,
            environment: environment,
            fileManager: fileManager,
            bundledResourceURL: nil,
            developmentResourceSearchRoots: []
        ) else {
            throw unavailable("MEETING_AGENT_WHISPER_MODEL is not set")
        }

        return try validated(binaryPath: binaryPath, modelPath: modelPath, fileManager: fileManager)
    }

    private static func validated(
        binaryPath: String,
        modelPath: String,
        fileManager: FileManager
    ) throws -> WhisperConfiguration {
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

public enum WhisperConfigurationResolver {
    public static let modelsDirectoryName = "WhisperModels"
    private static let preferredModelFileNames = [
        "ggml-small.bin",
        "ggml-small.en.bin",
        "ggml-medium.bin"
    ]

    static func binaryPath(
        explicitPath: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String? {
        if let explicitPath = nonBlank(explicitPath) {
            return explicitPath
        }
        if let environmentPath = nonBlank(environment["MEETING_AGENT_WHISPER_BIN"]) {
            return environmentPath
        }
        return executablePath(named: "whisper-cli", pathValue: environment["PATH"], fileManager: fileManager)
    }

    static func modelPath(
        explicitPath: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        bundledResourceURL: URL? = Bundle.main.resourceURL,
        developmentResourceSearchRoots: [URL] = [URL(fileURLWithPath: FileManager.default.currentDirectoryPath)]
    ) -> String? {
        nonBlank(explicitPath)
            ?? nonBlank(environment["MEETING_AGENT_WHISPER_MODEL"])
            ?? modelPathOptions(
                environment: environment,
                fileManager: fileManager,
                bundledResourceURL: bundledResourceURL,
                developmentResourceSearchRoots: developmentResourceSearchRoots
            ).first
    }

    public static func modelPathOptions(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        bundledResourceURL: URL? = Bundle.main.resourceURL,
        developmentResourceSearchRoots: [URL] = [URL(fileURLWithPath: FileManager.default.currentDirectoryPath)]
    ) -> [String] {
        var paths = [String?]()
        paths.append(nonBlank(environment["MEETING_AGENT_WHISPER_MODEL"]))
        if let bundledResourceURL {
            paths.append(contentsOf: modelPaths(
                in: bundledResourceURL.appendingPathComponent(modelsDirectoryName, isDirectory: true),
                fileManager: fileManager
            ))
        }
        for rootURL in developmentResourceSearchRoots {
            paths.append(contentsOf: modelPaths(
                in: rootURL.appendingPathComponent("Resources", isDirectory: true)
                    .appendingPathComponent(modelsDirectoryName, isDirectory: true),
                fileManager: fileManager
            ))
        }
        return uniqueExistingModelPaths(paths, fileManager: fileManager)
    }

    private static func executablePath(
        named executableName: String,
        pathValue: String?,
        fileManager: FileManager
    ) -> String? {
        guard let pathValue = nonBlank(pathValue) else { return nil }
        for directory in pathValue.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(executableName).path
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func modelPaths(in directoryURL: URL, fileManager: FileManager) -> [String] {
        guard let fileNames = try? fileManager.contentsOfDirectory(atPath: directoryURL.path) else {
            return []
        }
        let candidates = fileNames
            .filter { fileName in
                fileName.hasPrefix("ggml-") && (fileName.hasSuffix(".bin") || fileName.hasSuffix(".gguf"))
            }
        return candidates
            .sorted { lhs, rhs in
                let leftRank = preferredModelFileNames.firstIndex(of: lhs) ?? preferredModelFileNames.count
                let rightRank = preferredModelFileNames.firstIndex(of: rhs) ?? preferredModelFileNames.count
                if leftRank != rightRank {
                    return leftRank < rightRank
                }
                return lhs < rhs
            }
            .map { directoryURL.appendingPathComponent($0).path }
    }

    private static func uniqueExistingModelPaths(_ paths: [String?], fileManager: FileManager) -> [String] {
        var seen = Set<String>()
        return paths.compactMap { path in
            guard let path = nonBlank(path),
                  !seen.contains(path),
                  fileManager.isReadableFile(atPath: URL(fileURLWithPath: path).path)
            else {
                return nil
            }
            seen.insert(path)
            return path
        }
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
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

    static func languageCode(for localeIdentifier: String, modelURL: URL) -> String? {
        if isEnglishOnlyModel(modelURL) {
            return "en"
        }
        return languageCode(for: localeIdentifier)
    }

    static func languageCode(for localeIdentifier: String) -> String? {
        let trimmed = localeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let knownCode = knownCodes[trimmed] {
            return knownCode
        }
        let separators = CharacterSet(charactersIn: "-_")
        return trimmed.components(separatedBy: separators).first.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func isEnglishOnlyModel(_ modelURL: URL) -> Bool {
        let fileName = modelURL.lastPathComponent.lowercased()
        return fileName.hasSuffix(".en.bin") || fileName.hasSuffix(".en.gguf")
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
    private let configuration: WhisperConfiguration?
    private let processRunner: WhisperProcessRunning

    init(
        appConfiguration: SpeechTranscriptionConfiguration = .default,
        processRunner: WhisperProcessRunning = WhisperProcessRunner()
    ) {
        self.configuration = try? WhisperConfiguration.fromAppConfiguration(appConfiguration)
        self.processRunner = processRunner
    }

    init(
        configuration: WhisperConfiguration,
        processRunner: WhisperProcessRunning = WhisperProcessRunner()
    ) {
        self.configuration = configuration
        self.processRunner = processRunner
    }

    func start(transcriptURL: URL, localeIdentifier: String) async throws -> AudioFrameTranscriber {
        let configuration = try configuration ?? WhisperConfiguration.fromEnvironment()
        return try WhisperCLITranscriber.start(
            transcriptURL: transcriptURL,
            localeIdentifier: localeIdentifier,
            configuration: configuration,
            processRunner: processRunner
        )
    }

    func transcribeExistingAudio(context: SpeechTranscriptionContext) async throws {
        guard let inputAudioURL = context.inputAudioURL else {
            throw ProbeError.speechRecognition("Whisper transcription unavailable: no audio file is available for retry")
        }
        let configuration = try configuration ?? WhisperConfiguration.fromEnvironment()
        try WhisperFileTranscriber.transcribe(
            inputAudioURL: inputAudioURL,
            transcriptURL: context.transcriptURL,
            localeIdentifier: context.localeIdentifier,
            configuration: configuration,
            processRunner: processRunner
        )
    }
}

enum WhisperFileTranscriber {
    static func transcribe(
        inputAudioURL: URL,
        transcriptURL: URL,
        localeIdentifier: String,
        configuration: WhisperConfiguration,
        processRunner: WhisperProcessRunning,
        workingDirectory: URL = FileManager.default.temporaryDirectory
    ) throws {
        let temporaryDirectory = workingDirectory.appendingPathComponent("meeting-agent-whisper-retry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let outputBaseURL = temporaryDirectory.appendingPathComponent("transcript")
        let outputTextURL = outputBaseURL.appendingPathExtension("txt")
        try processRunner.run(
            binaryURL: configuration.binaryURL,
            modelURL: configuration.modelURL,
            inputWavURL: inputAudioURL,
            outputBaseURL: outputBaseURL,
            languageCode: WhisperLanguageMapper.languageCode(for: localeIdentifier, modelURL: configuration.modelURL)
        )
        guard FileManager.default.fileExists(atPath: outputTextURL.path) else {
            throw ProbeError.speechRecognition("Whisper transcription unavailable: expected output file was not created")
        }

        let transcriptLines = normalizedTranscriptLines(try String(contentsOf: outputTextURL, encoding: .utf8))
        let segments = transcriptLines.enumerated().map { lineIndex, text in
            TranscriptSegment(
                id: "whisper-retry-\(lineIndex)",
                text: text,
                language: localeIdentifier,
                sourceProvider: "whisper",
                isFinal: true,
                timingSource: .unavailable
            )
        }
        try TranscriptFileWriter(url: transcriptURL).replace(with: segments)
    }

    private static func normalizedTranscriptLines(_ text: String) -> [String] {
        text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { $0.caseInsensitiveCompare("[BLANK_AUDIO]") != .orderedSame }
    }
}

final class WhisperCLITranscriber: AudioFrameTranscriber {
    private let transcriptURL: URL
    private let temporaryDirectory: URL
    private let configuration: WhisperConfiguration
    private let processRunner: WhisperProcessRunning
    private let localeIdentifier: String
    private let languageCode: String?
    private let chunkDurationSeconds: Double
    private var chunkFrames: [AudioFrame] = []
    private var pendingChunkDurationSeconds = 0.0
    private var transcribedDurationSeconds = 0.0
    private var chunkIndex = 0
    private var transcriptSegments: [TranscriptSegment] = []
    private var isFinished = false
    private(set) var failureReason: String?

    private init(
        transcriptURL: URL,
        temporaryDirectory: URL,
        configuration: WhisperConfiguration,
        processRunner: WhisperProcessRunning,
        localeIdentifier: String,
        languageCode: String?,
        chunkDurationSeconds: Double
    ) {
        self.transcriptURL = transcriptURL
        self.temporaryDirectory = temporaryDirectory
        self.configuration = configuration
        self.processRunner = processRunner
        self.localeIdentifier = localeIdentifier
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
            localeIdentifier: localeIdentifier,
            languageCode: WhisperLanguageMapper.languageCode(for: localeIdentifier, modelURL: configuration.modelURL),
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
            guard !chunkFrames.isEmpty || !transcriptSegments.isEmpty else {
                throw ProbeError.speechRecognition("Whisper transcription unavailable: no audio frames were captured")
            }
            if !chunkFrames.isEmpty {
                try transcribePendingChunk()
            }
        } catch {
            let message = failureMessage(for: error)
            failureReason = message
            try? TranscriptFileWriter(url: transcriptURL).replace(with: message)
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

        let transcriptLines = normalizedTranscriptLines(
            try String(contentsOf: outputTextURL, encoding: .utf8)
        )
        let chunkStartTime = transcribedDurationSeconds
        let chunkEndTime = chunkStartTime + pendingChunkDurationSeconds
        if !transcriptLines.isEmpty {
            transcriptSegments += transcriptLines.enumerated().map { lineIndex, text in
                TranscriptSegment(
                    id: "whisper-\(chunkID)-\(lineIndex)",
                    startTimeSeconds: chunkStartTime,
                    endTimeSeconds: chunkEndTime,
                    text: text,
                    language: localeIdentifier,
                    sourceProvider: "whisper",
                    isFinal: true,
                    timingSource: .approximate
                )
            }
            try TranscriptFileWriter(url: transcriptURL).replace(with: transcriptSegments)
        }

        chunkFrames.removeAll(keepingCapacity: true)
        transcribedDurationSeconds = chunkEndTime
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

    private func normalizedTranscriptLines(_ text: String) -> [String] {
        text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { $0.caseInsensitiveCompare("[BLANK_AUDIO]") != .orderedSame }
    }
}
