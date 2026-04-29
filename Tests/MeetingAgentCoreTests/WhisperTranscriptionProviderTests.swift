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

    func testLanguageMapperForcesEnglishForEnglishOnlyModel() {
        let directory = FileManager.default.temporaryDirectory

        XCTAssertEqual(
            WhisperLanguageMapper.languageCode(
                for: "zh-CN",
                modelURL: directory.appendingPathComponent("ggml-small.en.bin")
            ),
            "en"
        )
        XCTAssertEqual(
            WhisperLanguageMapper.languageCode(
                for: "zh-CN",
                modelURL: directory.appendingPathComponent("ggml-small.bin")
            ),
            "zh"
        )
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

    func testConfigurationReportsMissingBinaryModelAndPermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-config-missing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let missingBinary = directory.appendingPathComponent("missing-whisper")
        let nonExecutableBinary = directory.appendingPathComponent("not-executable")
        let modelURL = directory.appendingPathComponent("ggml-small.bin")
        FileManager.default.createFile(atPath: nonExecutableBinary.path, contents: Data())
        FileManager.default.createFile(atPath: modelURL.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: nonExecutableBinary.path)

        XCTAssertThrowsError(try WhisperConfiguration.fromEnvironment([
            "MEETING_AGENT_WHISPER_BIN": missingBinary.path,
            "MEETING_AGENT_WHISPER_MODEL": modelURL.path
        ])) { error in
            XCTAssertTrue(String(describing: error).contains("Whisper binary does not exist"))
        }

        XCTAssertThrowsError(try WhisperConfiguration.fromEnvironment([
            "MEETING_AGENT_WHISPER_BIN": nonExecutableBinary.path,
            "MEETING_AGENT_WHISPER_MODEL": modelURL.path
        ])) { error in
            XCTAssertTrue(String(describing: error).contains("Whisper binary is not executable"))
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nonExecutableBinary.path)
        XCTAssertThrowsError(try WhisperConfiguration.fromEnvironment([
            "MEETING_AGENT_WHISPER_BIN": nonExecutableBinary.path,
            "MEETING_AGENT_WHISPER_MODEL": directory.appendingPathComponent("missing-model.bin").path
        ])) { error in
            XCTAssertTrue(String(describing: error).contains("Whisper model does not exist"))
        }
    }

    func testConfigurationFindsBinaryOnPathWhenEnvironmentVariableIsUnset() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-config-path-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let binURL = directory.appendingPathComponent("whisper-cli")
        let modelURL = directory.appendingPathComponent("ggml-small.bin")
        FileManager.default.createFile(atPath: binURL.path, contents: Data())
        FileManager.default.createFile(atPath: modelURL.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binURL.path)

        let configuration = try WhisperConfiguration.fromEnvironment([
            "PATH": directory.path,
            "MEETING_AGENT_WHISPER_MODEL": modelURL.path
        ], fileManager: .default)

        XCTAssertEqual(configuration.binaryURL, binURL)
        XCTAssertEqual(configuration.modelURL, modelURL)
    }

    func testAppConfigurationFindsPackagedBinaryBeforePath() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-config-packaged-bin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let resourcesURL = directory.appendingPathComponent("Resources", isDirectory: true)
        let packagedBinURL = resourcesURL
            .appendingPathComponent("WhisperBin", isDirectory: true)
            .appendingPathComponent("whisper-cli")
        let pathBinURL = directory.appendingPathComponent("whisper-cli")
        let modelURL = directory.appendingPathComponent("ggml-small.en.bin")
        try FileManager.default.createDirectory(at: packagedBinURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: packagedBinURL.path, contents: Data())
        FileManager.default.createFile(atPath: pathBinURL.path, contents: Data())
        FileManager.default.createFile(atPath: modelURL.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: packagedBinURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pathBinURL.path)

        let appConfiguration = SpeechTranscriptionConfiguration(
            provider: .whisper,
            localeIdentifier: "en-US",
            whisperBinaryPath: nil,
            whisperModelPath: modelURL.path
        )

        let configuration = try WhisperConfiguration.fromAppConfiguration(
            appConfiguration,
            environment: ["PATH": directory.path],
            fileManager: .default,
            bundledResourceURL: resourcesURL,
            developmentResourceSearchRoots: []
        )

        XCTAssertEqual(configuration.binaryURL, packagedBinURL)
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

    func testProcessRunnerUsesPackagedBackendDirectoryWhenAvailable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-backend-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let binaryURL = directory
            .appendingPathComponent("WhisperBin", isDirectory: true)
            .appendingPathComponent("whisper-cli")
        let backendURL = directory.appendingPathComponent("libexec", isDirectory: true)
        let backendFileURL = backendURL.appendingPathComponent("libggml-cpu-apple_m1.so")
        try FileManager.default.createDirectory(at: binaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backendURL, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: backendFileURL.path, contents: Data())

        let environment = WhisperProcessRunner.environment(
            for: binaryURL,
            base: ["PATH": "/usr/bin"],
            fileManager: .default
        )

        XCTAssertEqual(environment["PATH"], "/usr/bin")
        XCTAssertEqual(environment["GGML_BACKEND_PATH"], backendFileURL.path)
    }

    func testProcessRunnerUsesDevelopmentBackendDirectoryWhenAvailable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-backend-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let binaryURL = directory
            .appendingPathComponent("WhisperBin", isDirectory: true)
            .appendingPathComponent("whisper-cli")
        let backendURL = directory.appendingPathComponent("WhisperLibexec", isDirectory: true)
        let backendFileURL = backendURL.appendingPathComponent("libggml-cpu-apple_m2_m3.so")
        try FileManager.default.createDirectory(at: binaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backendURL, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: backendFileURL.path, contents: Data())

        let environment = WhisperProcessRunner.environment(
            for: binaryURL,
            base: [:],
            fileManager: .default
        )

        XCTAssertEqual(environment["GGML_BACKEND_PATH"], backendFileURL.path)
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

    func testRealProcessRunnerSurfacesLaunchAndExitFailures() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-real-runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = WhisperProcessRunner()

        XCTAssertThrowsError(try runner.run(
            binaryURL: directory.appendingPathComponent("missing-whisper"),
            modelURL: directory.appendingPathComponent("model.bin"),
            inputWavURL: directory.appendingPathComponent("input.wav"),
            outputBaseURL: directory.appendingPathComponent("transcript"),
            languageCode: "en"
        )) { error in
            XCTAssertTrue(String(describing: error).contains("failed to launch whisper-cli"))
        }

        XCTAssertThrowsError(try runner.run(
            binaryURL: URL(fileURLWithPath: "/bin/sh"),
            modelURL: directory.appendingPathComponent("model.bin"),
            inputWavURL: directory.appendingPathComponent("input.wav"),
            outputBaseURL: directory.appendingPathComponent("transcript"),
            languageCode: nil
        )) { error in
            XCTAssertTrue(String(describing: error).contains("whisper-cli exited with status"))
        }
    }

    func testFactoryReturnsWhisperProvider() {
        let provider = SpeechTranscriptionProviderFactory.provider(for: .whisper, configuration: .default)

        XCTAssertEqual(provider.provider, .whisper)
    }

    func testProviderStartUsesConfiguredWhisperTranscriberAndRetryRequiresAudioURL() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-provider-start-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = WhisperConfiguration(
            binaryURL: directory.appendingPathComponent("whisper-cli"),
            modelURL: directory.appendingPathComponent("ggml-small.bin")
        )
        let provider = WhisperSpeechTranscriptionProvider(
            configuration: configuration,
            processRunner: OutputWritingWhisperProcessRunner(outputText: "hello\n")
        )

        let transcriber = try await provider.start(
            transcriptURL: directory.appendingPathComponent("capture.txt"),
            localeIdentifier: "en-US"
        )
        transcriber.finish()

        await XCTAssertThrowsErrorAsync(try await provider.transcribeExistingAudio(context: SpeechTranscriptionContext(
            inputAudioURL: nil,
            transcriptURL: directory.appendingPathComponent("retry.txt"),
            localeIdentifier: "en-US",
            meetingID: UUID(),
            previousTranscript: nil
        ))) { error in
            XCTAssertEqual(String(describing: error), "Speech recognition error: Whisper transcription unavailable: no audio file is available for retry")
        }
    }

    func testTranscribesExistingAudioFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-retry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let audioURL = directory.appendingPathComponent("audio.wav")
        let transcriptURL = directory.appendingPathComponent("transcript.txt")
        FileManager.default.createFile(atPath: audioURL.path, contents: Data([0x52, 0x49, 0x46, 0x46]))
        let configuration = WhisperConfiguration(
            binaryURL: directory.appendingPathComponent("whisper-cli"),
            modelURL: directory.appendingPathComponent("ggml-small.bin")
        )
        let runner = OutputWritingWhisperProcessRunner(outputText: "retry transcript\n")

        try await WhisperSpeechTranscriptionProvider(
            configuration: configuration,
            processRunner: runner
        )
        .transcribeExistingAudio(
            context: SpeechTranscriptionContext(
                inputAudioURL: audioURL,
                transcriptURL: transcriptURL,
                localeIdentifier: "en-US",
                meetingID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
                previousTranscript: nil
            )
        )

        XCTAssertEqual(try String(contentsOf: transcriptURL, encoding: .utf8), "User A:\nretry transcript\n")
        let document = try TranscriptFileWriter.readDocument(from: transcriptURL.deletingPathExtension().appendingPathExtension("json"))
        XCTAssertEqual(document.segments.count, 1)
        XCTAssertEqual(document.segments.first?.id, "whisper-retry-0")
        XCTAssertEqual(document.segments.first?.speakerID, "speaker-1")
        XCTAssertEqual(document.segments.first?.speakerLabel, "User A")
        XCTAssertEqual(document.segments.first?.text, "retry transcript")
        XCTAssertEqual(document.segments.first?.language, "en-US")
        XCTAssertEqual(document.segments.first?.sourceProvider, "whisper")
        XCTAssertEqual(document.segments.first?.isFinal, true)
        XCTAssertEqual(document.segments.first?.timingSource, .unavailable)
        XCTAssertEqual(runner.inputWavURL, audioURL)
    }

    func testTranscribesExistingAudioFileWithEnglishLanguageWhenModelIsEnglishOnly() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-retry-en-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let audioURL = directory.appendingPathComponent("audio.wav")
        let transcriptURL = directory.appendingPathComponent("transcript.txt")
        FileManager.default.createFile(atPath: audioURL.path, contents: Data([0x52, 0x49, 0x46, 0x46]))
        let configuration = WhisperConfiguration(
            binaryURL: directory.appendingPathComponent("whisper-cli"),
            modelURL: directory.appendingPathComponent("ggml-small.en.bin")
        )
        let runner = OutputWritingWhisperProcessRunner(outputText: "english transcript\n")

        try await WhisperSpeechTranscriptionProvider(
            configuration: configuration,
            processRunner: runner
        )
        .transcribeExistingAudio(
            context: SpeechTranscriptionContext(
                inputAudioURL: audioURL,
                transcriptURL: transcriptURL,
                localeIdentifier: "zh-CN",
                meetingID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
                previousTranscript: nil
            )
        )

        XCTAssertEqual(runner.languageCode, "en")
        let document = try TranscriptFileWriter.readDocument(from: transcriptURL.deletingPathExtension().appendingPathExtension("json"))
        XCTAssertEqual(document.segments.first?.language, "zh-CN")
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

        XCTAssertEqual(try String(contentsOf: transcriptURL, encoding: .utf8), "User A:\nhello from whisper\n")
        let document = try TranscriptFileWriter.readDocument(from: transcriptURL.deletingPathExtension().appendingPathExtension("json"))
        XCTAssertEqual(document.segments.count, 1)
        XCTAssertEqual(document.segments.first?.id, "whisper-0-0")
        XCTAssertEqual(document.segments.first?.speakerID, "speaker-1")
        XCTAssertEqual(document.segments.first?.speakerLabel, "User A")
        XCTAssertEqual(document.segments.first?.startTimeSeconds, 0)
        XCTAssertEqual(document.segments.first?.endTimeSeconds, 0.000125)
        XCTAssertEqual(document.segments.first?.language, "en-US")
        XCTAssertEqual(document.segments.first?.sourceProvider, "whisper")
        XCTAssertEqual(document.segments.first?.timingSource, .approximate)
        XCTAssertEqual(runner.languageCode, "en")
        XCTAssertNotNil(runner.inputWavURL)
    }

    func testTranscriberUsesEnglishLanguageWhenModelIsEnglishOnly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-transcriber-en-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let transcriptURL = directory.appendingPathComponent("capture.txt")
        let configuration = WhisperConfiguration(
            binaryURL: directory.appendingPathComponent("whisper-cli"),
            modelURL: directory.appendingPathComponent("ggml-small.en.bin")
        )
        let runner = OutputWritingWhisperProcessRunner(outputText: "hello from whisper\n")
        let transcriber = try WhisperCLITranscriber.start(
            transcriptURL: transcriptURL,
            localeIdentifier: "zh-CN",
            configuration: configuration,
            processRunner: runner,
            workingDirectory: directory
        )

        try transcriber.append(AudioFrame(pcm: Data([0x01, 0x00, 0x02, 0x00]), sampleRate: 16_000, channelCount: 1, timestampNanos: 1))
        transcriber.finish()

        XCTAssertEqual(runner.languageCode, "en")
        let document = try TranscriptFileWriter.readDocument(from: transcriptURL.deletingPathExtension().appendingPathExtension("json"))
        XCTAssertEqual(document.segments.first?.language, "zh-CN")
    }

    func testTranscriberRunsWhisperBeforeFinishWhenChunkThresholdIsReached() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-streaming-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let transcriptURL = directory.appendingPathComponent("capture.txt")
        let configuration = WhisperConfiguration(
            binaryURL: directory.appendingPathComponent("whisper-cli"),
            modelURL: directory.appendingPathComponent("ggml-small.bin")
        )
        let runner = SequencedWhisperProcessRunner(outputs: ["first chunk\n"])
        let transcriber = try WhisperCLITranscriber.start(
            transcriptURL: transcriptURL,
            localeIdentifier: "en-US",
            configuration: configuration,
            processRunner: runner,
            workingDirectory: directory,
            chunkDurationSeconds: 0.001
        )

        try transcriber.append(AudioFrame(pcm: Data([0x01, 0x00, 0x02, 0x00]), sampleRate: 1_000, channelCount: 1, timestampNanos: 1))

        XCTAssertEqual(runner.runCount, 1)
        XCTAssertEqual(try String(contentsOf: transcriptURL, encoding: .utf8), "User A:\nfirst chunk\n")
    }

    func testTranscriberFiltersBlankAudioMarker() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-blank-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let transcriptURL = directory.appendingPathComponent("capture.txt")
        let configuration = WhisperConfiguration(
            binaryURL: directory.appendingPathComponent("whisper-cli"),
            modelURL: directory.appendingPathComponent("ggml-small.bin")
        )
        let runner = SequencedWhisperProcessRunner(outputs: ["hello\n", "[BLANK_AUDIO]\n"])
        let transcriber = try WhisperCLITranscriber.start(
            transcriptURL: transcriptURL,
            localeIdentifier: "en-US",
            configuration: configuration,
            processRunner: runner,
            workingDirectory: directory,
            chunkDurationSeconds: 0.001
        )

        try transcriber.append(AudioFrame(pcm: Data([0x01, 0x00]), sampleRate: 1_000, channelCount: 1, timestampNanos: 1))
        try transcriber.append(AudioFrame(pcm: Data([0x00, 0x00]), sampleRate: 1_000, channelCount: 1, timestampNanos: 2))

        XCTAssertEqual(try String(contentsOf: transcriptURL, encoding: .utf8), "User A:\nhello\n")
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
        XCTAssertEqual(transcriber.failureReason, "Whisper transcription unavailable: process failed")
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
        XCTAssertEqual(transcriber.failureReason, "Whisper transcription unavailable: no audio frames were captured")
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

private final class SequencedWhisperProcessRunner: WhisperProcessRunning {
    private var outputs: [String]
    private(set) var runCount = 0

    init(outputs: [String]) {
        self.outputs = outputs
    }

    func run(
        binaryURL: URL,
        modelURL: URL,
        inputWavURL: URL,
        outputBaseURL: URL,
        languageCode: String?
    ) throws {
        runCount += 1
        let output = outputs.isEmpty ? "" : outputs.removeFirst()
        try output.write(to: outputBaseURL.appendingPathExtension("txt"), atomically: true, encoding: .utf8)
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

private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> some Any,
    _ verify: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error to be thrown", file: file, line: line)
    } catch {
        verify(error)
    }
}
