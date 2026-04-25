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
