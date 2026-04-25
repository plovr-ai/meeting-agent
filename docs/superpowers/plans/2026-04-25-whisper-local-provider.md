# Local Whisper STT Provider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `whisper` STT provider that transcribes captured audio with a local `whisper.cpp` CLI model while preserving the current WAV recording flow.

**Architecture:** Extend the existing `SpeechTranscriptionProvider` boundary with a new `WhisperSpeechTranscriptionProvider`. The first version writes captured frames to a temporary WAV, runs `whisper-cli` on `finish()`, and copies the generated text to the existing transcript file path. Configuration comes from `MEETING_AGENT_WHISPER_BIN` and `MEETING_AGENT_WHISPER_MODEL`.

**Tech Stack:** Swift 5.9, Foundation `Process`, XCTest, existing `AudioFrame`, `WavFileWriter`, and `TranscriptFileWriter` types.

---

## File Structure

- Modify `Sources/CoreAudioTapProbe/SpeechTranscriptionProvider.swift`: add `.whisper`, supported provider description, and factory routing.
- Modify `Sources/CoreAudioTapProbe/ProbeMain.swift`: update CLI usage text to show `local|whisper`.
- Create `Sources/CoreAudioTapProbe/WhisperTranscriptionProvider.swift`: implement configuration, locale mapping, process runner, provider, and transcriber.
- Modify `Tests/CoreAudioTapProbeTests/RecordingOutputTests.swift`: add and update CLI provider parsing tests.
- Create `Tests/CoreAudioTapProbeTests/WhisperTranscriptionProviderTests.swift`: test configuration, language mapping, command construction, provider factory, and transcriber success/failure behavior.
- Modify `AGENTS.md`: add the new provider command and environment variables to common commands and STT notes.

## Task 1: CLI Provider Enum And Parsing

**Files:**
- Modify: `Sources/CoreAudioTapProbe/SpeechTranscriptionProvider.swift`
- Modify: `Sources/CoreAudioTapProbe/ProbeMain.swift`
- Modify: `Tests/CoreAudioTapProbeTests/RecordingOutputTests.swift`

- [ ] **Step 1: Add failing tests for the `whisper` provider option**

Append this test after `testSpeechProviderCanBeConfiguredToLocal()` in `Tests/CoreAudioTapProbeTests/RecordingOutputTests.swift`:

```swift
func testSpeechProviderCanBeConfiguredToWhisper() throws {
    let options = try ProbeOptions(arguments: ["--seconds", "5", "--stt-provider", "whisper"])

    XCTAssertEqual(options.speechProvider, .whisper)
}
```

Update `testUnknownSpeechProviderIsRejected()` in the same file to expect both providers:

```swift
func testUnknownSpeechProviderIsRejected() {
    XCTAssertThrowsError(try ProbeOptions(arguments: ["--seconds", "5", "--stt-provider", "openai"])) { error in
        XCTAssertEqual(String(describing: error), "Invalid arguments: Unsupported --stt-provider openai. Supported providers: local, whisper")
    }
}
```

- [ ] **Step 2: Run the focused tests and verify they fail**

Run:

```sh
swift test --filter RecordingOutputTests
```

Expected: failure because `SpeechProvider` has no member `.whisper`, or unsupported provider output still lists only `local`.

- [ ] **Step 3: Implement provider enum support**

In `Sources/CoreAudioTapProbe/SpeechTranscriptionProvider.swift`, change the top of the file to:

```swift
import Foundation

enum SpeechProvider: String, Equatable {
    case local
    case whisper

    static var supportedValuesDescription: String {
        "local, whisper"
    }
}
```

Update the factory switch in the same file so it compiles before the concrete Whisper provider exists:

```swift
enum SpeechTranscriptionProviderFactory {
    static func provider(for provider: SpeechProvider) -> SpeechTranscriptionProvider {
        switch provider {
        case .local:
            return LocalSpeechTranscriptionProvider()
        case .whisper:
            return LocalSpeechTranscriptionProvider()
        }
    }
}
```

This temporary factory routing is replaced in Task 4.

- [ ] **Step 4: Update usage text**

In `Sources/CoreAudioTapProbe/ProbeMain.swift`, replace:

```swift
log("Usage: CoreAudioTapProbe [--pid <process-id>] [--seconds 10] [--wav [capture.wav]] [--stt-provider local] [--stt-locale en-US]")
```

with:

```swift
log("Usage: CoreAudioTapProbe [--pid <process-id>] [--seconds 10] [--wav [capture.wav]] [--stt-provider local|whisper] [--stt-locale en-US]")
```

- [ ] **Step 5: Run tests and verify the task passes**

Run:

```sh
swift test --filter RecordingOutputTests
```

Expected: all `RecordingOutputTests` pass.

- [ ] **Step 6: Commit**

Run:

```sh
git add Sources/CoreAudioTapProbe/SpeechTranscriptionProvider.swift Sources/CoreAudioTapProbe/ProbeMain.swift Tests/CoreAudioTapProbeTests/RecordingOutputTests.swift
git commit -m "Add whisper STT provider option"
```

## Task 2: Whisper Configuration And Language Mapping

**Files:**
- Create: `Sources/CoreAudioTapProbe/WhisperTranscriptionProvider.swift`
- Create: `Tests/CoreAudioTapProbeTests/WhisperTranscriptionProviderTests.swift`

- [ ] **Step 1: Write failing tests for configuration and language mapping**

Create `Tests/CoreAudioTapProbeTests/WhisperTranscriptionProviderTests.swift` with:

```swift
import XCTest
@testable import CoreAudioTapProbe

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
}
```

- [ ] **Step 2: Run the focused tests and verify they fail**

Run:

```sh
swift test --filter WhisperTranscriptionProviderTests
```

Expected: failure because `WhisperLanguageMapper` and `WhisperConfiguration` are not defined.

- [ ] **Step 3: Implement configuration and mapping**

Create `Sources/CoreAudioTapProbe/WhisperTranscriptionProvider.swift` with:

```swift
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
```

- [ ] **Step 4: Run tests and verify the task passes**

Run:

```sh
swift test --filter WhisperTranscriptionProviderTests
```

Expected: all `WhisperTranscriptionProviderTests` pass.

- [ ] **Step 5: Commit**

Run:

```sh
git add Sources/CoreAudioTapProbe/WhisperTranscriptionProvider.swift Tests/CoreAudioTapProbeTests/WhisperTranscriptionProviderTests.swift
git commit -m "Add whisper configuration and locale mapping"
```

## Task 3: Whisper Process Runner

**Files:**
- Modify: `Sources/CoreAudioTapProbe/WhisperTranscriptionProvider.swift`
- Modify: `Tests/CoreAudioTapProbeTests/WhisperTranscriptionProviderTests.swift`

- [ ] **Step 1: Add failing tests for command construction and process failures**

Append these tests inside `WhisperTranscriptionProviderTests`:

```swift
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
```

Add this helper after the test class:

```swift
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
```

- [ ] **Step 2: Run the focused tests and verify they fail**

Run:

```sh
swift test --filter WhisperTranscriptionProviderTests
```

Expected: failure because `WhisperProcessRunning` and `WhisperProcessRunner` are not defined.

- [ ] **Step 3: Implement the process runner**

Append this to `Sources/CoreAudioTapProbe/WhisperTranscriptionProvider.swift`:

```swift
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
```

- [ ] **Step 4: Run tests and verify the task passes**

Run:

```sh
swift test --filter WhisperTranscriptionProviderTests
```

Expected: all `WhisperTranscriptionProviderTests` pass.

- [ ] **Step 5: Commit**

Run:

```sh
git add Sources/CoreAudioTapProbe/WhisperTranscriptionProvider.swift Tests/CoreAudioTapProbeTests/WhisperTranscriptionProviderTests.swift
git commit -m "Add whisper process runner"
```

## Task 4: Whisper Provider And Transcriber

**Files:**
- Modify: `Sources/CoreAudioTapProbe/SpeechTranscriptionProvider.swift`
- Modify: `Sources/CoreAudioTapProbe/WhisperTranscriptionProvider.swift`
- Modify: `Tests/CoreAudioTapProbeTests/WhisperTranscriptionProviderTests.swift`

- [ ] **Step 1: Add failing tests for factory routing, successful transcription, and failure transcript**

Append these tests inside `WhisperTranscriptionProviderTests`:

```swift
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
```

Add these helpers after `RecordingWhisperProcessRunner`:

```swift
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
```

- [ ] **Step 2: Run the focused tests and verify they fail**

Run:

```sh
swift test --filter WhisperTranscriptionProviderTests
```

Expected: failure because factory still returns the local provider, and `WhisperCLITranscriber` is not defined.

- [ ] **Step 3: Implement the provider and transcriber**

Append this to `Sources/CoreAudioTapProbe/WhisperTranscriptionProvider.swift`:

```swift
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
        self.outputTextURL = outputBaseURL.appendingPathExtension("txt")
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
```

- [ ] **Step 4: Route factory to the real provider**

In `Sources/CoreAudioTapProbe/SpeechTranscriptionProvider.swift`, replace the `.whisper` factory case:

```swift
case .whisper:
    return LocalSpeechTranscriptionProvider()
```

with:

```swift
case .whisper:
    return WhisperSpeechTranscriptionProvider()
```

- [ ] **Step 5: Run tests and verify the task passes**

Run:

```sh
swift test --filter WhisperTranscriptionProviderTests
```

Expected: all `WhisperTranscriptionProviderTests` pass.

- [ ] **Step 6: Commit**

Run:

```sh
git add Sources/CoreAudioTapProbe/SpeechTranscriptionProvider.swift Sources/CoreAudioTapProbe/WhisperTranscriptionProvider.swift Tests/CoreAudioTapProbeTests/WhisperTranscriptionProviderTests.swift
git commit -m "Add whisper CLI transcriber"
```

## Task 5: Documentation And Full Verification

**Files:**
- Modify: `AGENTS.md`

- [ ] **Step 1: Update project instructions**

In `AGENTS.md`, add this command to the Common Commands list after the existing local STT command:

```sh
swift run CoreAudioTapProbe --seconds 10 --wav --stt-provider whisper --stt-locale zh-CN
```

Add this paragraph after the implemented-provider sentence:

````markdown
The `whisper` STT provider uses a local `whisper.cpp` CLI and model. Configure it with `MEETING_AGENT_WHISPER_BIN` and `MEETING_AGENT_WHISPER_MODEL`, for example:

```sh
export MEETING_AGENT_WHISPER_BIN=/opt/homebrew/bin/whisper-cli
export MEETING_AGENT_WHISPER_MODEL=/Users/allan/models/ggml-small.bin
```
````

Replace:

```markdown
The only implemented STT provider is currently `local`, backed by macOS Speech.
```

with:

```markdown
Implemented STT providers are `local`, backed by macOS Speech, and `whisper`, backed by a local `whisper.cpp` CLI and model.
```

- [ ] **Step 2: Run the full test suite**

Run:

```sh
swift test
```

Expected: all tests pass.

- [ ] **Step 3: Run a no-capture provider parsing smoke test**

Run:

```sh
swift run CoreAudioTapProbe --list
```

Expected: command prints running capture targets and usage that contains `--stt-provider local|whisper`.

- [ ] **Step 4: Check final git state**

Run:

```sh
git status --short
```

Expected: only `AGENTS.md` is modified before the final commit.

- [ ] **Step 5: Commit**

Run:

```sh
git add AGENTS.md
git commit -m "Document whisper STT provider"
```

## Task 6: Optional Manual Whisper Verification

**Files:**
- Runtime output only: `.record/*.wav`, `.record/*.txt`

- [ ] **Step 1: Configure local Whisper**

Run:

```sh
export MEETING_AGENT_WHISPER_BIN=/opt/homebrew/bin/whisper-cli
export MEETING_AGENT_WHISPER_MODEL=/Users/allan/models/ggml-small.bin
```

Expected: both environment variables point to existing local files on the developer machine.

- [ ] **Step 2: Run a short local capture**

Run:

```sh
swift run CoreAudioTapProbe --seconds 10 --wav --stt-provider whisper --stt-locale zh-CN
```

Expected: `.record/*.wav` and `.record/*.txt` are created. If the selected process produces audio, the transcript file contains Whisper output. If local Whisper is misconfigured, the transcript file contains a clear `Whisper transcription unavailable:` reason and the WAV remains present.

- [ ] **Step 3: Leave runtime recordings uncommitted**

Run:

```sh
git status --short
```

Expected: no tracked changes from `.record/` because runtime recordings are ignored.
