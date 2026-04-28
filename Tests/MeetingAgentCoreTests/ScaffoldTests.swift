import XCTest

final class ScaffoldTests: XCTestCase {
    func testScaffoldLoads() {
        XCTAssertTrue(true)
    }

    func testPackageManifestDoesNotExposeCoreAudioTapProbe() throws {
        let manifest = try readRepositoryFile("Package.swift")

        XCTAssertFalse(manifest.contains("CoreAudioTapProbe"))
    }

    func testPackageAppScriptBuildsAndAssemblesBundle() throws {
        let script = try readRepositoryFile("scripts/package-app.sh")

        XCTAssertTrue(script.contains("swift build -c release --product MeetingAgentApp"))
        XCTAssertTrue(script.contains("dist/MeetingAgent.app"))
        XCTAssertTrue(script.contains("Contents/MacOS"))
        XCTAssertTrue(script.contains("Contents/Resources"))
        XCTAssertTrue(script.contains("Sources/MeetingAgentApp/Resources/Info.plist"))
        XCTAssertTrue(script.contains("DefaultSpeechTranscriptionCredentials.json"))
        XCTAssertTrue(script.contains("DEEPGRAM_API_KEY"))
        XCTAssertTrue(script.contains("openrouter_api_key"))
        XCTAssertTrue(script.contains("Embedded default credentials for:"))
        XCTAssertTrue(script.contains("PkgInfo"))
    }

    func testAppInfoPlistContainsBundleMetadataAndPermissions() throws {
        let plist = try readRepositoryFile("Sources/MeetingAgentApp/Resources/Info.plist")

        XCTAssertTrue(plist.contains("<key>CFBundleExecutable</key>"))
        XCTAssertTrue(plist.contains("<string>MeetingAgentApp</string>"))
        XCTAssertTrue(plist.contains("<key>CFBundleIdentifier</key>"))
        XCTAssertTrue(plist.contains("<string>ai.plovr.MeetingAgent</string>"))
        XCTAssertTrue(plist.contains("<key>CFBundlePackageType</key>"))
        XCTAssertTrue(plist.contains("<string>APPL</string>"))
        XCTAssertTrue(plist.contains("<key>LSMinimumSystemVersion</key>"))
        XCTAssertTrue(plist.contains("<string>14.2</string>"))
        XCTAssertTrue(plist.contains("<key>NSAudioCaptureUsageDescription</key>"))
        XCTAssertTrue(plist.contains("<key>NSMicrophoneUsageDescription</key>"))
        XCTAssertTrue(plist.contains("<key>NSSpeechRecognitionUsageDescription</key>"))
        XCTAssertTrue(plist.contains("<key>NSUserNotificationUsageDescription</key>"))
    }

    func testMakefileExposesPackageAppCommand() throws {
        let makefile = try readRepositoryFile("Makefile")

        XCTAssertTrue(makefile.contains(".PHONY: test package-app"))
        XCTAssertTrue(makefile.contains("package-app:"))
        XCTAssertTrue(makefile.contains("scripts/package-app.sh"))
    }

    private func readRepositoryFile(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url)
    }
}
