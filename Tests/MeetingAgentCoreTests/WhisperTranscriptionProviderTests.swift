import XCTest
@testable import MeetingAgentCore

final class WhisperTranscriptionProviderTests: XCTestCase {
    func testLanguageMapperUsesKnownWhisperCodes() {
        XCTAssertEqual(WhisperLanguageMapper.languageCode(for: "zh-CN"), "zh")
        XCTAssertEqual(WhisperLanguageMapper.languageCode(for: "zh-TW"), "zh")
        XCTAssertEqual(WhisperLanguageMapper.languageCode(for: "en-US"), "en")
        XCTAssertEqual(WhisperLanguageMapper.languageCode(for: "ja-JP"), "ja")
        XCTAssertEqual(WhisperLanguageMapper.languageCode(for: "ko-KR"), "ko")
    }

    func testLanguageMapperFallsBackToPrimaryLanguageComponent() {
        XCTAssertEqual(WhisperLanguageMapper.languageCode(for: "pt-BR"), "pt")
        XCTAssertEqual(WhisperLanguageMapper.languageCode(for: "de_DE"), "de")
    }

    func testLanguageMapperReturnsNilForBlankLocale() {
        XCTAssertNil(WhisperLanguageMapper.languageCode(for: ""))
        XCTAssertNil(WhisperLanguageMapper.languageCode(for: "   "))
    }

    func testConfigurationRequiresWhisperBinaryEnvironmentVariable() {
        let environment = ["MEETING_AGENT_WHISPER_MODEL": "/tmp/model.bin"]

        XCTAssertThrowsError(try WhisperConfiguration.fromEnvironment(environment, fileManager: .default)) { error in
            XCTAssertEqual(String(describing: error), "Speech recognition error: Whisper transcription unavailable: MEETING_AGENT_WHISPER_BIN is not set")
        }
    }

    func testConfigurationRequiresWhisperModelEnvironmentVariable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let binURL = directory.appendingPathComponent("whisper-cli")
        FileManager.default.createFile(atPath: binURL.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binURL.path)

        let environment = ["MEETING_AGENT_WHISPER_BIN": binURL.path]

        XCTAssertThrowsError(try WhisperConfiguration.fromEnvironment(environment, fileManager: .default)) { error in
            XCTAssertEqual(String(describing: error), "Speech recognition error: Whisper transcription unavailable: MEETING_AGENT_WHISPER_MODEL is not set")
        }
    }

    func testConfigurationLoadsExistingBinaryAndModel() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let binURL = directory.appendingPathComponent("whisper-cli")
        let modelURL = directory.appendingPathComponent("ggml-small.bin")
        FileManager.default.createFile(atPath: binURL.path, contents: Data())
        FileManager.default.createFile(atPath: modelURL.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binURL.path)

        let configuration = try WhisperConfiguration.fromEnvironment([
            "MEETING_AGENT_WHISPER_BIN": binURL.path,
            "MEETING_AGENT_WHISPER_MODEL": modelURL.path
        ], fileManager: .default)

        XCTAssertEqual(configuration.binaryURL, binURL)
        XCTAssertEqual(configuration.modelURL, modelURL)
    }

    func testProcessRunnerBuildsExpectedArgumentsWithLanguage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let binaryURL = directory.appendingPathComponent("whisper-cli")
        let modelURL = directory.appendingPathComponent("ggml-small.bin")
        let inputURL = directory.appendingPathComponent("input.wav")
        let outputBaseURL = directory.appendingPathComponent("transcript")
        let outputTextURL = outputBaseURL.appendingPathExtension("txt")
        FileManager.default.createFile(atPath: outputTextURL.path, contents: Data("hello\n".utf8))

        let runner = RecordingWhisperProcessRunner(exitCode: 0)

        try runner.run(
            binaryURL: binaryURL,
            modelURL: modelURL,
            inputWavURL: inputURL,
            outputBaseURL: outputBaseURL,
            languageCode: "zh"
        )

        XCTAssertEqual(runner.recordedBinaryURL, binaryURL)
        XCTAssertEqual(runner.recordedArguments, [
            "-m", modelURL.path,
            "-f", inputURL.path,
            "-l", "zh",
            "-otxt",
            "-of", outputBaseURL.path
        ])
    }

    func testProcessRunnerOmitsBlankLanguage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let runner = RecordingWhisperProcessRunner(exitCode: 0)

        try runner.run(
            binaryURL: directory.appendingPathComponent("whisper-cli"),
            modelURL: directory.appendingPathComponent("ggml-small.bin"),
            inputWavURL: directory.appendingPathComponent("input.wav"),
            outputBaseURL: directory.appendingPathComponent("transcript"),
            languageCode: nil
        )

        XCTAssertFalse(runner.recordedArguments.contains("-l"))
    }

    func testProcessRunnerThrowsWhenExitCodeIsNonZero() {
        let runner = RecordingWhisperProcessRunner(exitCode: 2, stderr: "model failed")
        let directory = FileManager.default.temporaryDirectory

        XCTAssertThrowsError(try runner.run(
            binaryURL: directory.appendingPathComponent("whisper-cli"),
            modelURL: directory.appendingPathComponent("ggml-small.bin"),
            inputWavURL: directory.appendingPathComponent("input.wav"),
            outputBaseURL: directory.appendingPathComponent("transcript"),
            languageCode: "en"
        )) { error in
            XCTAssertEqual(String(describing: error), "Speech recognition error: Whisper transcription unavailable: whisper-cli exited with status 2: model failed")
        }
    }

    func testFactoryReturnsWhisperProvider() {
        let provider = SpeechTranscriptionProviderFactory.provider(for: .whisper)

        XCTAssertEqual(provider.provider, .whisper)
    }

    func testTranscriberRunsWhisperAndWritesTranscript() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-transcriber-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let transcriptURL = directory.appendingPathComponent("capture.txt")
        let configuration = WhisperConfiguration(
            binaryURL: directory.appendingPathComponent("whisper-cli"),
            modelURL: directory.appendingPathComponent("ggml-small.bin")
        )
        let runner = OutputWritingWhisperProcessRunner(outputText: "hello from whisper\n")
        let transcriber = try WhisperCLITranscriber.start(
            transcriptURL: transcriptURL,
            localeIdentifier: "en-US",
            configuration: configuration,
            processRunner: runner,
            workingDirectory: directory
        )

        try transcriber.append(AudioFrame(pcm: Data([0x01, 0x00, 0x02, 0x00]), sampleRate: 16_000, channelCount: 1, timestampNanos: 1))
        transcriber.finish()

        XCTAssertEqual(try String(contentsOf: transcriptURL, encoding: .utf8), "hello from whisper\n")
        XCTAssertEqual(runner.languageCode, "en")
        XCTAssertNotNil(runner.inputWavURL)
    }

    func testTranscriberWritesFailureReasonWhenRunnerFails() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-transcriber-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let transcriptURL = directory.appendingPathComponent("capture.txt")
        let configuration = WhisperConfiguration(
            binaryURL: directory.appendingPathComponent("whisper-cli"),
            modelURL: directory.appendingPathComponent("ggml-small.bin")
        )
        let runner = FailingWhisperProcessRunner()
        let transcriber = try WhisperCLITranscriber.start(
            transcriptURL: transcriptURL,
            localeIdentifier: "zh-CN",
            configuration: configuration,
            processRunner: runner,
            workingDirectory: directory
        )

        try transcriber.append(AudioFrame(pcm: Data([0x01, 0x00, 0x02, 0x00]), sampleRate: 16_000, channelCount: 1, timestampNanos: 1))
        transcriber.finish()

        XCTAssertEqual(try String(contentsOf: transcriptURL, encoding: .utf8), "Whisper transcription unavailable: process failed\n")
    }

    func testTranscriberWritesFailureReasonWhenNoFramesWereCaptured() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-transcriber-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let transcriptURL = directory.appendingPathComponent("capture.txt")
        let configuration = WhisperConfiguration(
            binaryURL: directory.appendingPathComponent("whisper-cli"),
            modelURL: directory.appendingPathComponent("ggml-small.bin")
        )
        let runner = OutputWritingWhisperProcessRunner(outputText: "hello from whisper\n")
        let transcriber = try WhisperCLITranscriber.start(
            transcriptURL: transcriptURL,
            localeIdentifier: "en-US",
            configuration: configuration,
            processRunner: runner,
            workingDirectory: directory
        )

        transcriber.finish()

        XCTAssertEqual(try String(contentsOf: transcriptURL, encoding: .utf8), "Whisper transcription unavailable: no audio frames were captured\n")
        XCTAssertNil(runner.inputWavURL)
    }
}

private final class RecordingWhisperProcessRunner: WhisperProcessRunning {
    let exitCode: Int32
    let stderr: String
    private(set) var recordedBinaryURL: URL?
    private(set) var recordedArguments: [String] = []

    init(exitCode: Int32, stderr: String = "") {
        self.exitCode = exitCode
        self.stderr = stderr
    }

    func run(
        binaryURL: URL,
        modelURL: URL,
        inputWavURL: URL,
        outputBaseURL: URL,
        languageCode: String?
    ) throws {
        recordedBinaryURL = binaryURL
        recordedArguments = WhisperProcessRunner.arguments(
            modelURL: modelURL,
            inputWavURL: inputWavURL,
            outputBaseURL: outputBaseURL,
            languageCode: languageCode
        )
        if exitCode != 0 {
            throw ProbeError.speechRecognition("Whisper transcription unavailable: whisper-cli exited with status \(exitCode): \(stderr)")
        }
    }
}

private final class OutputWritingWhisperProcessRunner: WhisperProcessRunning {
    let outputText: String
    private(set) var inputWavURL: URL?
    private(set) var languageCode: String?

    init(outputText: String) {
        self.outputText = outputText
    }

    func run(
        binaryURL: URL,
        modelURL: URL,
        inputWavURL: URL,
        outputBaseURL: URL,
        languageCode: String?
    ) throws {
        self.inputWavURL = inputWavURL
        self.languageCode = languageCode
        try outputText.write(to: outputBaseURL.appendingPathExtension("txt"), atomically: true, encoding: .utf8)
    }
}

private struct FailingWhisperProcessRunner: WhisperProcessRunning {
    func run(
        binaryURL: URL,
        modelURL: URL,
        inputWavURL: URL,
        outputBaseURL: URL,
        languageCode: String?
    ) throws {
        throw ProbeError.speechRecognition("Whisper transcription unavailable: process failed")
    }
}
