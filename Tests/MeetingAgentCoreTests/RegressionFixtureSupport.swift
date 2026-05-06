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
    var translationState: String?
}

enum RegressionFixtureError: Error, Equatable, CustomStringConvertible {
    case missingTranslation(String)

    var description: String {
        switch self {
        case .missingTranslation(let key):
            return "Missing fixture translation for \(key)"
        }
    }
}

struct RegressionFixtureTranslationLookup {
    private var translationsBySegmentSet: [String: String]
    private var translationsBySourceTextHash: [String: String]

    init(records: [TranslationResultPersistenceRecord]) {
        translationsBySegmentSet = Dictionary(uniqueKeysWithValues: records.map {
            (Self.canonical($0.sourceSegmentIDs), $0.translatedText)
        })
        translationsBySourceTextHash = Dictionary(uniqueKeysWithValues: records.map {
            ($0.sourceTextHash, $0.translatedText)
        })
    }

    func translation(forSourceSegmentIDs ids: [String]) throws -> String {
        let key = Self.canonical(ids)
        guard let text = translationsBySegmentSet[key] else {
            throw RegressionFixtureError.missingTranslation(key)
        }
        return text
    }

    func translation(forSourceTextHash hash: String) throws -> String {
        guard let text = translationsBySourceTextHash[hash] else {
            throw RegressionFixtureError.missingTranslation(hash)
        }
        return text
    }

    static func canonical(_ ids: [String]) -> String {
        ids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
            .joined(separator: ",")
    }
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
            "--assert-translation-e2e",
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
        try JSONDecoder.meetingAgent.decode(
            TranscriptDocument.self,
            from: Data(contentsOf: fixtureURL.appendingPathComponent("transcript.json"))
        )
    }

    static func loadTranslationRecords(in fixtureURL: URL) throws -> [TranslationResultPersistenceRecord] {
        let lines = try String(
            contentsOf: fixtureURL.appendingPathComponent("translation-results.jsonl"),
            encoding: .utf8
        )
        .split(separator: "\n")
        return try lines.map {
            try JSONDecoder.meetingAgent.decode(TranslationResultPersistenceRecord.self, from: Data($0.utf8))
        }
    }

    static func projectStableTranslationTurns(
        in fixtureURL: URL,
        manifest: RegressionFixtureManifest
    ) throws -> [LiveCaptionTurn] {
        let transcript = try loadTranscript(in: fixtureURL)
        let segmentsByID = Dictionary(uniqueKeysWithValues: transcript.segments.map { ($0.id, $0) })
        return try loadTranslationRecords(in: fixtureURL).map { record in
            let sourceText = record.sourceSegmentIDs.compactMap { segmentsByID[$0]?.text }.joined(separator: " ")
            return LiveCaptionTurn(
                id: RegressionFixtureTranslationLookup.canonical(record.sourceSegmentIDs),
                sourceSegmentID: record.sourceSegmentIDs.first ?? record.sourceID,
                sourceSegmentIDs: record.sourceSegmentIDs,
                speaker: TranscriptSpeaker(identifier: record.laneID.speakerID, label: nil),
                originalText: sourceText,
                translatedText: record.translatedText,
                translationFreshness: .final,
                sourceLocale: manifest.sourceLocale,
                targetLocale: manifest.targetLocale,
                isFinal: true,
                translationHealth: .live,
                translationState: .final
            )
        }
    }
}
