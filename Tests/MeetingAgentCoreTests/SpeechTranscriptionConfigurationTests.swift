import XCTest
@testable import MeetingAgentCore

final class SpeechTranscriptionConfigurationTests: XCTestCase {
    func testWhisperValidationReportsMissingPaths() {
        let configuration = SpeechTranscriptionConfiguration(
            provider: .whisper,
            localeIdentifier: "zh-CN",
            whisperBinaryPath: "",
            whisperModelPath: nil
        )

        XCTAssertEqual(
            configuration.validationStatus(fileManager: .default),
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

        XCTAssertEqual(configuration.validationStatus(fileManager: .default), .available)
        XCTAssertEqual(try WhisperConfiguration.fromAppConfiguration(configuration, fileManager: .default).binaryURL, binaryURL)
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
}
