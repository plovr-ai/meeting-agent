import XCTest
@testable import MeetingAgentCore

final class SpeechTranscriptionConfigurationTests: XCTestCase {
    func testDefaultSettingsAreTranscriptionAndSummaryOnly() {
        let configuration = SpeechTranscriptionConfiguration.default

        XCTAssertEqual(configuration.transcriptionExecutionMode, .hosted)
        XCTAssertEqual(configuration.localTranscriptionProviderID, "whisper-local")
        XCTAssertEqual(configuration.hostedTranscriptionProviderID, "deepgram-transcribe")
        XCTAssertEqual(configuration.hostedSummaryModelID, "openai/gpt-4.1-mini")
        XCTAssertEqual(SpeechProviderCatalog.hostedSummaryModelOptions.first?.id, "openai/gpt-4.1-mini")
        XCTAssertEqual(configuration.deepgramModelID, "nova-3")
        XCTAssertEqual(Set(SpeechProviderCatalog.builtInProviderDescriptors.map(\.capability)), [.audioTranscription])
    }

    func testReliableMVPDefaultsUseDeepgramHostedTranscription() {
        let configuration = SpeechTranscriptionConfiguration.default

        XCTAssertEqual(configuration.transcriptionExecutionMode, .hosted)
        XCTAssertEqual(
            configuration.hostedTranscriptionProviderID,
            SpeechTranscriptionConfiguration.defaultDeepgramTranscriptionProviderID
        )
        XCTAssertEqual(configuration.deepgramModelID, "nova-3")
    }

    func testValidationUsesTranscriptionAndSummarySettingsOnly() {
        var configuration = SpeechTranscriptionConfiguration.default
        configuration.hostedSummaryModelID = "openai/gpt-4.1-mini"

        XCTAssertEqual(
            configuration.validationStatus(
                environment: ["MEETING_AGENT_DEEPGRAM_API_KEY": "test-key"],
                fileManager: .default,
                bundledResourceURL: nil,
                developmentResourceSearchRoots: []
            ),
            .available
        )
    }

    func testWhisperValidationReportsMissingPaths() {
        let configuration = SpeechTranscriptionConfiguration(
            provider: .whisper,
            localeIdentifier: "zh-CN",
            whisperBinaryPath: "",
            whisperModelPath: nil
        )

        XCTAssertEqual(
            configuration.validationStatus(
                environment: ["MEETING_AGENT_OPENROUTER_API_KEY": "test-key"],
                fileManager: .default,
                bundledResourceURL: nil,
                developmentResourceSearchRoots: []
            ),
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
            configuration.validationStatus(
                environment: environment,
                fileManager: .default,
                bundledResourceURL: nil,
                developmentResourceSearchRoots: []
            ),
            .available
        )
        XCTAssertEqual(
            try WhisperConfiguration.fromAppConfiguration(
                configuration,
                environment: environment,
                fileManager: .default,
                bundledResourceURL: nil,
                developmentResourceSearchRoots: []
            ).binaryURL,
            binaryURL
        )
    }

    func testWhisperValidationFindsPackagedBinaryWhenNotExplicitlyConfigured() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("speech-config-packaged-bin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let resourcesURL = directory.appendingPathComponent("Resources", isDirectory: true)
        let binURL = resourcesURL
            .appendingPathComponent("WhisperBin", isDirectory: true)
            .appendingPathComponent("whisper-cli")
        let modelsURL = resourcesURL.appendingPathComponent("WhisperModels", isDirectory: true)
        try FileManager.default.createDirectory(at: binURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: modelsURL, withIntermediateDirectories: true)
        let modelURL = modelsURL.appendingPathComponent("ggml-small.en.bin")
        FileManager.default.createFile(atPath: binURL.path, contents: Data())
        FileManager.default.createFile(atPath: modelURL.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binURL.path)

        let configuration = SpeechTranscriptionConfiguration(
            provider: .whisper,
            localeIdentifier: "en-US",
            whisperBinaryPath: nil,
            whisperModelPath: nil
        )

        XCTAssertEqual(
            configuration.validationStatus(
                environment: [:],
                fileManager: .default,
                bundledResourceURL: resourcesURL,
                developmentResourceSearchRoots: []
            ),
            .available
        )
        XCTAssertEqual(
            try WhisperConfiguration.fromAppConfiguration(
                configuration,
                environment: [:],
                fileManager: .default,
                bundledResourceURL: resourcesURL,
                developmentResourceSearchRoots: []
            ).binaryURL,
            binURL
        )
    }

    func testWhisperValidationFindsPackagedModelWhenNotExplicitlyConfigured() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("speech-config-packaged-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let binaryURL = directory.appendingPathComponent("whisper-cli")
        FileManager.default.createFile(atPath: binaryURL.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryURL.path)

        let resourcesURL = directory.appendingPathComponent("Resources", isDirectory: true)
        let modelsURL = resourcesURL.appendingPathComponent("WhisperModels", isDirectory: true)
        try FileManager.default.createDirectory(at: modelsURL, withIntermediateDirectories: true)
        let modelURL = modelsURL.appendingPathComponent("ggml-small.bin")
        FileManager.default.createFile(atPath: modelURL.path, contents: Data())

        let configuration = SpeechTranscriptionConfiguration(
            provider: .whisper,
            localeIdentifier: "zh-CN",
            whisperBinaryPath: nil,
            whisperModelPath: nil
        )
        let environment = ["PATH": directory.path]

        XCTAssertEqual(
            configuration.validationStatus(
                environment: environment,
                fileManager: .default,
                bundledResourceURL: resourcesURL,
                developmentResourceSearchRoots: []
            ),
            .available
        )
        XCTAssertEqual(
            try WhisperConfiguration.fromAppConfiguration(
                configuration,
                environment: environment,
                fileManager: .default,
                bundledResourceURL: resourcesURL,
                developmentResourceSearchRoots: []
            ).modelURL,
            modelURL
        )
    }

    func testLocalProviderDoesNotRequireWhisperPaths() {
        let configuration = SpeechTranscriptionConfiguration(
            provider: .local,
            localeIdentifier: "en-US",
            whisperBinaryPath: nil,
            whisperModelPath: nil
        )

        XCTAssertEqual(configuration.validationStatus(fileManager: .default), .available)
    }

    func testConfigurationPersistsActiveProviderAndModelSettingsOnly() throws {
        let suiteName = "meeting-agent-tests-\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let store = SpeechTranscriptionConfigurationStore(userDefaults: userDefaults)
        let configuration = SpeechTranscriptionConfiguration(
            provider: .whisper,
            localeIdentifier: "en-US",
            whisperBinaryPath: "/opt/homebrew/bin/whisper-cli",
            whisperModelPath: "/Users/allan/models/ggml-small.bin",
            transcriptionExecutionMode: .hosted,
            localTranscriptionProviderID: "whisper-local",
            hostedTranscriptionProviderID: "openrouter-transcribe",
            hostedTranscriptionModelID: "google/gemini-2.5-flash",
            hostedSummaryModelID: "google/gemini-2.5-flash",
            openRouterAPIKey: "settings-key",
            openAIRealtimeAPIKey: " realtime-key ",
            deepgramAPIKey: " deepgram-key ",
            deepgramModelID: " nova-2 "
        )

        try store.save(configuration)

        let persistedData = try XCTUnwrap(userDefaults.data(forKey: "SpeechTranscriptionConfiguration"))
        let persistedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: persistedData) as? [String: Any]
        )
        XCTAssertNil(persistedObject["targetLocaleIdentifier"])
        let legacyPipelineProfileKey = "bilingual" + "PipelineProfileID"
        let legacyExecutionModeKey = "translation" + "ExecutionMode"
        let legacyLocalProviderKey = "local" + "TranslationProviderID"
        let legacyHostedProviderKey = "hosted" + "TranslationProviderID"
        let legacyHostedModelKey = "hosted" + "TranslationModelID"
        XCTAssertNil(persistedObject[legacyPipelineProfileKey])
        XCTAssertNil(persistedObject[legacyExecutionModeKey])
        XCTAssertNil(persistedObject[legacyLocalProviderKey])
        XCTAssertNil(persistedObject[legacyHostedProviderKey])
        XCTAssertNil(persistedObject[legacyHostedModelKey])

        var expected = configuration
        expected.openAIRealtimeAPIKey = "realtime-key"
        expected.deepgramAPIKey = "deepgram-key"
        expected.deepgramModelID = "nova-2"
        XCTAssertEqual(try store.load(), expected)
    }

    func testConfigurationStoreMergesLegacyTargetLocaleIntoLocaleIdentifier() throws {
        let suiteName = "meeting-agent-tests-\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let store = SpeechTranscriptionConfigurationStore(userDefaults: userDefaults)
        let legacyPipelineProfileKey = "bilingual" + "PipelineProfileID"
        let legacyExecutionModeKey = "translation" + "ExecutionMode"
        let legacyLocalProviderKey = "local" + "TranslationProviderID"
        let legacyHostedProviderKey = "hosted" + "TranslationProviderID"
        let legacyHostedModelKey = "hosted" + "TranslationModelID"
        let legacyConfiguration = """
        {
          "provider": "whisper",
          "localeIdentifier": "en-US",
          "targetLocaleIdentifier": "zh-CN",
          "\(legacyPipelineProfileKey)": "local-whisper-hosted-translation",
          "whisperBinaryPath": "/opt/homebrew/bin/whisper-cli",
          "whisperModelPath": "/Users/allan/models/ggml-medium.bin",
          "transcriptionExecutionMode": "local",
          "\(legacyExecutionModeKey)": "local",
          "\(legacyLocalProviderKey)": "legacy-local-translation",
          "hostedTranscriptionProviderID": "openrouter-transcribe",
          "\(legacyHostedProviderKey)": "legacy-hosted-translation",
          "hostedTranscriptionModelID": "google/gemini-2.5-flash",
          "\(legacyHostedModelKey)": "legacy-translation-model"
        }
        """
        userDefaults.set(Data(legacyConfiguration.utf8), forKey: "SpeechTranscriptionConfiguration")

        let loaded = try store.load()

        XCTAssertEqual(loaded.localeIdentifier, "zh-CN")
        XCTAssertEqual(loaded.hostedTranscriptionProviderID, "openrouter-transcribe")
        XCTAssertEqual(loaded.hostedTranscriptionModelID, "google/gemini-2.5-flash")
        try store.save(loaded)
        let persistedData = try XCTUnwrap(userDefaults.data(forKey: "SpeechTranscriptionConfiguration"))
        let persistedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: persistedData) as? [String: Any]
        )
        XCTAssertEqual(persistedObject["localeIdentifier"] as? String, "zh-CN")
        XCTAssertNil(persistedObject["targetLocaleIdentifier"])
        XCTAssertNil(persistedObject[legacyPipelineProfileKey])
        XCTAssertNil(persistedObject[legacyExecutionModeKey])
        XCTAssertNil(persistedObject[legacyLocalProviderKey])
        XCTAssertNil(persistedObject[legacyHostedProviderKey])
        XCTAssertNil(persistedObject[legacyHostedModelKey])
    }

    func testConfigurationStorePersistsAPIKeys() throws {
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

        XCTAssertEqual(loaded.openRouterAPIKey, "openrouter-secret")
        XCTAssertEqual(loaded.openAIRealtimeAPIKey, "openai-secret")
        XCTAssertEqual(loaded.deepgramAPIKey, "deepgram-secret")
    }

    func testConfigurationStoreAppliesPackagedDefaultAPIKeysWhenNoUserSettingsExist() throws {
        let suiteName = "meeting-agent-tests-\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let defaultsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("packaged-defaults-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: defaultsURL) }
        try """
        {
          "openRouterAPIKey": " packaged-openrouter-key ",
          "deepgramAPIKey": " packaged-deepgram-key "
        }
        """.write(to: defaultsURL, atomically: true, encoding: .utf8)
        let store = SpeechTranscriptionConfigurationStore(
            userDefaults: userDefaults,
            packagedDefaultsURL: defaultsURL
        )

        let loaded = try store.load()

        XCTAssertEqual(loaded.openRouterAPIKey, "packaged-openrouter-key")
        XCTAssertEqual(loaded.deepgramAPIKey, "packaged-deepgram-key")
    }

    func testConfigurationStoreDoesNotOverridePersistedUserAPIKeysWithPackagedDefaults() throws {
        let suiteName = "meeting-agent-tests-\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let defaultsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("packaged-defaults-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: defaultsURL) }
        try """
        {
          "openRouterAPIKey": "packaged-openrouter-key",
          "deepgramAPIKey": "packaged-deepgram-key"
        }
        """.write(to: defaultsURL, atomically: true, encoding: .utf8)
        let store = SpeechTranscriptionConfigurationStore(
            userDefaults: userDefaults,
            packagedDefaultsURL: defaultsURL
        )
        try store.save(SpeechTranscriptionConfiguration(
            provider: .whisper,
            localeIdentifier: "en-US",
            whisperBinaryPath: nil,
            whisperModelPath: nil,
            openRouterAPIKey: "user-openrouter-key",
            deepgramAPIKey: "user-deepgram-key"
        ))

        let loaded = try store.load()

        XCTAssertEqual(loaded.openRouterAPIKey, "user-openrouter-key")
        XCTAssertEqual(loaded.deepgramAPIKey, "user-deepgram-key")
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
        XCTAssertEqual(configuration.hostedSummaryModelID, "openai/gpt-4.1-mini")
    }

    func testDeepgramHostedValidationRequiresAPIKey() {
        let configuration = SpeechTranscriptionConfiguration(
            provider: .whisper,
            localeIdentifier: "en-US",
            whisperBinaryPath: nil,
            whisperModelPath: nil,
            transcriptionExecutionMode: .hosted,
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
            hostedTranscriptionModelID: "google/gemini-2.5-flash",
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
            hostedTranscriptionModelID: "google/gemini-2.5-flash"
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

    func testValidationReportsWhisperFileSystemProblemsAndHostedTranscriptionModelGaps() throws {
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
            whisperModelPath: modelURL.path
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
            transcriptionExecutionMode: .hosted
        )
        config.hostedTranscriptionModelID = " "
        XCTAssertEqual(config.validationStatus(environment: ["MEETING_AGENT_OPENROUTER_API_KEY": "key"]), .unavailable("Hosted transcription model is not configured"))
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
