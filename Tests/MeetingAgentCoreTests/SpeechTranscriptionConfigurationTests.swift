import XCTest
@testable import MeetingAgentCore

final class SpeechTranscriptionConfigurationTests: XCTestCase {
    func testDefaultBilingualSettings() {
        let configuration = SpeechTranscriptionConfiguration.default

        XCTAssertEqual(configuration.targetLocaleIdentifier, "zh-CN")
        XCTAssertEqual(configuration.bilingualPipelineProfileID, "deepgram-stt-hosted-translation")
        XCTAssertEqual(configuration.transcriptionExecutionMode, .hosted)
        XCTAssertEqual(configuration.translationExecutionMode, .hosted)
        XCTAssertEqual(configuration.localTranscriptionProviderID, "whisper-local")
        XCTAssertEqual(configuration.hostedTranscriptionProviderID, "deepgram-transcribe")
        XCTAssertEqual(configuration.hostedTranslationProviderID, "openrouter-translation")
        XCTAssertEqual(configuration.deepgramModelID, "nova-3")
    }

    func testReliableMVPDefaultsUseDeepgramHostedTranscription() {
        let configuration = SpeechTranscriptionConfiguration.default

        XCTAssertEqual(configuration.transcriptionExecutionMode, .hosted)
        XCTAssertEqual(
            configuration.hostedTranscriptionProviderID,
            SpeechTranscriptionConfiguration.defaultDeepgramTranscriptionProviderID
        )
        XCTAssertEqual(configuration.deepgramModelID, "nova-3")
        XCTAssertEqual(configuration.translationExecutionMode, .hosted)
    }

    func testWhisperValidationReportsMissingPaths() {
        let configuration = SpeechTranscriptionConfiguration(
            provider: .whisper,
            localeIdentifier: "zh-CN",
            whisperBinaryPath: "",
            whisperModelPath: nil
        )

        XCTAssertEqual(
            configuration.validationStatus(environment: ["MEETING_AGENT_OPENROUTER_API_KEY": "test-key"], fileManager: .default),
            .unavailable("Whisper binary path is not configured")
        )
    }

    func testWhisperValidationAcceptsConfiguredBinaryAndModel() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("speech-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let binaryURL = directory.appendingPathComponent("whisper-cli")
        let modelURL = directory.appendingPathComponent("ggml-small.bin")
        FileManager.default.createFile(atPath: binaryURL.path, contents: Data())
        FileManager.default.createFile(atPath: modelURL.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryURL.path)

        let configuration = SpeechTranscriptionConfiguration(
            provider: .whisper,
            localeIdentifier: "zh-CN",
            whisperBinaryPath: binaryURL.path,
            whisperModelPath: modelURL.path
        )

        XCTAssertEqual(
            configuration.validationStatus(
                environment: ["MEETING_AGENT_OPENROUTER_API_KEY": "test-key"],
                fileManager: .default
            ),
            .available
        )
        XCTAssertEqual(try WhisperConfiguration.fromAppConfiguration(configuration, fileManager: .default).binaryURL, binaryURL)
    }

    func testWhisperValidationFindsBinaryOnPathWhenNotExplicitlyConfigured() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("speech-config-path-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let binaryURL = directory.appendingPathComponent("whisper-cli")
        let modelURL = directory.appendingPathComponent("ggml-small.bin")
        FileManager.default.createFile(atPath: binaryURL.path, contents: Data())
        FileManager.default.createFile(atPath: modelURL.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryURL.path)

        let configuration = SpeechTranscriptionConfiguration(
            provider: .whisper,
            localeIdentifier: "zh-CN",
            whisperBinaryPath: nil,
            whisperModelPath: modelURL.path
        )
        let environment = [
            "PATH": directory.path,
            "MEETING_AGENT_OPENROUTER_API_KEY": "test-key"
        ]

        XCTAssertEqual(
            configuration.validationStatus(environment: environment, fileManager: .default),
            .available
        )
        XCTAssertEqual(
            try WhisperConfiguration.fromAppConfiguration(
                configuration,
                environment: environment,
                fileManager: .default
            ).binaryURL,
            binaryURL
        )
    }

    func testLocalProviderDoesNotRequireWhisperPaths() {
        let configuration = SpeechTranscriptionConfiguration(
            provider: .local,
            localeIdentifier: "en-US",
            whisperBinaryPath: nil,
            whisperModelPath: nil,
            translationExecutionMode: .local
        )

        XCTAssertEqual(configuration.validationStatus(fileManager: .default), .available)
    }

    func testConfigurationRoundTripsStepLevelProviderAndModelSettings() throws {
        let suiteName = "meeting-agent-tests-\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let store = SpeechTranscriptionConfigurationStore(userDefaults: userDefaults)
        let configuration = SpeechTranscriptionConfiguration(
            provider: .whisper,
            localeIdentifier: "en-US",
            targetLocaleIdentifier: "zh-CN",
            bilingualPipelineProfileID: "hosted-transcribe-hosted-translation",
            whisperBinaryPath: "/opt/homebrew/bin/whisper-cli",
            whisperModelPath: "/Users/allan/models/ggml-small.bin",
            transcriptionExecutionMode: .hosted,
            translationExecutionMode: .hosted,
            localTranscriptionProviderID: "whisper-local",
            localTranslationProviderID: "qwen-local-translation",
            hostedTranscriptionProviderID: "openrouter-transcribe",
            hostedTranslationProviderID: "openrouter-translation",
            hostedTranscriptionModelID: "google/gemini-2.5-flash",
            hostedTranslationModelID: "openai/gpt-4.1-mini",
            openRouterAPIKey: "settings-key",
            openAIRealtimeAPIKey: " realtime-key ",
            deepgramAPIKey: " deepgram-key ",
            deepgramModelID: " nova-2 "
        )

        try store.save(configuration)

        var expected = configuration
        expected.openRouterAPIKey = nil
        expected.openAIRealtimeAPIKey = nil
        expected.deepgramAPIKey = nil
        expected.deepgramModelID = "nova-2"
        XCTAssertEqual(try store.load(), expected)
    }

    func testConfigurationStoreDoesNotPersistAPIKeys() throws {
        let suiteName = "meeting-agent-tests-\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let store = SpeechTranscriptionConfigurationStore(userDefaults: userDefaults)
        let configuration = SpeechTranscriptionConfiguration(
            provider: .whisper,
            localeIdentifier: "en-US",
            whisperBinaryPath: nil,
            whisperModelPath: nil,
            openRouterAPIKey: "openrouter-secret",
            openAIRealtimeAPIKey: "openai-secret",
            deepgramAPIKey: "deepgram-secret"
        )

        try store.save(configuration)
        let loaded = try store.load()

        XCTAssertNil(loaded.openRouterAPIKey)
        XCTAssertNil(loaded.openAIRealtimeAPIKey)
        XCTAssertNil(loaded.deepgramAPIKey)
    }

    func testConfigurationDecodesWhenRealtimeAPIKeyIsAbsent() throws {
        let json = """
        {
          "provider": "whisper",
          "localeIdentifier": "en-US",
          "whisperBinaryPath": null,
          "whisperModelPath": null
        }
        """

        let configuration = try JSONDecoder.meetingAgent.decode(
            SpeechTranscriptionConfiguration.self,
            from: Data(json.utf8)
        )

        XCTAssertNil(configuration.openAIRealtimeAPIKey)
        XCTAssertNil(configuration.deepgramAPIKey)
        XCTAssertEqual(configuration.deepgramModelID, "nova-3")
    }

    func testDeepgramHostedValidationRequiresAPIKey() {
        let configuration = SpeechTranscriptionConfiguration(
            provider: .whisper,
            localeIdentifier: "en-US",
            whisperBinaryPath: nil,
            whisperModelPath: nil,
            transcriptionExecutionMode: .hosted,
            translationExecutionMode: .local,
            hostedTranscriptionProviderID: "deepgram-transcribe"
        )

        XCTAssertEqual(
            configuration.validationStatus(environment: [:]),
            .unavailable("Deepgram API key is not configured")
        )
        XCTAssertEqual(
            configuration.validationStatus(environment: ["MEETING_AGENT_DEEPGRAM_API_KEY": "env-key"]),
            .available
        )
    }

    func testHostedValidationUsesSettingsOpenRouterAPIKey() {
        let configuration = SpeechTranscriptionConfiguration(
            provider: .whisper,
            localeIdentifier: "en-US",
            whisperBinaryPath: nil,
            whisperModelPath: nil,
            transcriptionExecutionMode: .hosted,
            translationExecutionMode: .hosted,
            hostedTranscriptionModelID: "google/gemini-2.5-flash",
            hostedTranslationModelID: "openai/gpt-4.1-mini",
            openRouterAPIKey: "settings-key"
        )

        XCTAssertEqual(configuration.validationStatus(environment: [:]), .available)
    }

    func testHostedValidationRequiresOpenRouterAPIKeyAndModels() {
        let missingKey = SpeechTranscriptionConfiguration(
            provider: .whisper,
            localeIdentifier: "en-US",
            whisperBinaryPath: nil,
            whisperModelPath: nil,
            transcriptionExecutionMode: .hosted,
            translationExecutionMode: .hosted,
            hostedTranscriptionModelID: "google/gemini-2.5-flash",
            hostedTranslationModelID: "openai/gpt-4.1-mini"
        )

        XCTAssertEqual(
            missingKey.validationStatus(environment: [:]),
            .unavailable("OpenRouter API key is not configured")
        )
    }

    func testConfigurationStorePersistsUserSettings() throws {
        let suiteName = "meeting-agent-tests-\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let store = SpeechTranscriptionConfigurationStore(userDefaults: userDefaults)

        try store.save(SpeechTranscriptionConfiguration(
            provider: .local,
            localeIdentifier: "ja-JP",
            whisperBinaryPath: "/opt/homebrew/bin/whisper-cli",
            whisperModelPath: "/Users/allan/models/ggml-small.bin"
        ))

        XCTAssertEqual(try store.load(), SpeechTranscriptionConfiguration(
            provider: .local,
            localeIdentifier: "ja-JP",
            whisperBinaryPath: "/opt/homebrew/bin/whisper-cli",
            whisperModelPath: "/Users/allan/models/ggml-small.bin"
        ))
    }

    func testValidationReportsWhisperFileSystemProblemsAndHostedModelGaps() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("speech-config-validation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binaryURL = directory.appendingPathComponent("whisper-cli")
        let modelURL = directory.appendingPathComponent("model.bin")
        FileManager.default.createFile(atPath: binaryURL.path, contents: Data())
        FileManager.default.createFile(atPath: modelURL.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: binaryURL.path)

        var config = SpeechTranscriptionConfiguration(
            provider: .whisper,
            localeIdentifier: "en-US",
            whisperBinaryPath: directory.appendingPathComponent("missing").path,
            whisperModelPath: modelURL.path,
            translationExecutionMode: .local
        )
        XCTAssertEqual(config.validationStatus(), .unavailable("Whisper binary does not exist at \(directory.appendingPathComponent("missing").path)"))

        config.whisperBinaryPath = binaryURL.path
        XCTAssertEqual(config.validationStatus(), .unavailable("Whisper binary is not executable at \(binaryURL.path)"))

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryURL.path)
        config.whisperModelPath = directory.appendingPathComponent("missing-model.bin").path
        XCTAssertEqual(config.validationStatus(), .unavailable("Whisper model does not exist at \(directory.appendingPathComponent("missing-model.bin").path)"))

        config = SpeechTranscriptionConfiguration(
            provider: .local,
            localeIdentifier: "en-US",
            whisperBinaryPath: nil,
            whisperModelPath: nil,
            transcriptionExecutionMode: .hosted,
            translationExecutionMode: .local
        )
        config.hostedTranscriptionModelID = " "
        XCTAssertEqual(config.validationStatus(environment: ["MEETING_AGENT_OPENROUTER_API_KEY": "key"]), .unavailable("Hosted transcription model is not configured"))

        config = SpeechTranscriptionConfiguration(
            provider: .local,
            localeIdentifier: "en-US",
            whisperBinaryPath: nil,
            whisperModelPath: nil,
            transcriptionExecutionMode: .local,
            translationExecutionMode: .hosted
        )
        config.hostedTranslationModelID = " "
        XCTAssertEqual(config.validationStatus(environment: ["MEETING_AGENT_OPENROUTER_API_KEY": "key"]), .unavailable("Hosted translation model is not configured"))
    }

    func testNormalizationAndStoreDefaults() throws {
        XCTAssertEqual(SpeechTranscriptionConfiguration.normalized(" value "), "value")
        XCTAssertEqual(SpeechTranscriptionConfiguration.normalized(" ", fallback: "fallback"), "fallback")
        XCTAssertNil(SpeechTranscriptionConfiguration.normalized(nil))

        let suiteName = "speech-config-default-\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let store = SpeechTranscriptionConfigurationStore(userDefaults: userDefaults)

        XCTAssertEqual(try store.load(), .default)
    }
}
