import Foundation
@testable import MeetingAgentCore

enum RegressionFixturePurpose: String, Codable, Equatable {
    case knownFailure
    case golden
}

enum RegressionAnalyzerStatus: String, Codable, Equatable {
    case pass
    case fail
}

struct RegressionFixtureManifest: Codable, Equatable {
    var id: String
    var sourceMeetingID: String
    var scenario: String
    var sourceLocale: String
    var targetLocale: String
    var purpose: RegressionFixturePurpose
    var expectedAnalyzerStatus: RegressionAnalyzerStatus
    var expectedFailures: [String]
    var notes: [String]?
}

struct RegressionExpectedUI: Codable, Equatable {
    var displayModes: [String: [RegressionExpectedUIRow]]
}

struct RegressionExpectedUIRow: Codable, Equatable {
    var sourceSegmentIDs: [String]
    var primaryText: String
    var sourceText: String?
    var isFinal: Bool?
}

struct RegressionCommandResult {
    var status: Int32
    var stdout: String
    var stderr: String
}

enum RegressionFixtureFiles {
    static var testDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    }

    static var repositoryRoot: URL {
        testDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static var fixtureRoot: URL {
        testDirectory
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("RegressionMeetings")
    }

    static func allFixtureDirectories() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: fixtureRoot.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: fixtureRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func loadManifest(in fixtureURL: URL) throws -> RegressionFixtureManifest {
        try JSONDecoder.meetingAgent.decode(
            RegressionFixtureManifest.self,
            from: Data(contentsOf: fixtureURL.appendingPathComponent("manifest.json"))
        )
    }

    static func runAnalyzer(_ fixtureURL: URL) throws -> RegressionCommandResult {
        let process = Process()
        process.currentDirectoryURL = repositoryRoot
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "swift",
            "scripts/analyze-meeting-performance.swift",
            fixtureURL.path
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return RegressionCommandResult(
            status: process.terminationStatus,
            stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }
}

extension RegressionFixtureFiles {
    static func loadExpectedUI(in fixtureURL: URL) throws -> RegressionExpectedUI {
        try JSONDecoder.meetingAgent.decode(
            RegressionExpectedUI.self,
            from: Data(contentsOf: fixtureURL.appendingPathComponent("expected-ui.json"))
        )
    }

    static func loadTranscript(in fixtureURL: URL) throws -> TranscriptDocument {
        try LegacyTranscriptBridge.readDocument(from: fixtureURL.appendingPathComponent("transcript.json"))
    }

}
