# Meeting Regression Fixture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an offline regression fixture harness that captures real meeting artifacts, runs analyzer expectations, and verifies visible caption/translation UI projection from fixture data.

**Architecture:** Keep production code unchanged. Add a fixture capture script and test-only replay helpers under `Tests/MeetingAgentCoreTests`. The first fixture is the real `D5C47AEC-4E86-4C66-9B61-FEE3D151006C` meeting, classified as `single-speaker-long-no-speech-final` and initially marked as a known failure.

**Tech Stack:** Swift 5.9, XCTest, Swift scripts, JSON/JSONL via `JSONDecoder.meetingAgent`, existing `scripts/analyze-meeting-performance.swift`.

---

## Execution Constraint

Execute this plan serially in the global worktree:

```text
/Users/allan/.config/superpowers/worktrees/meeting-agent/meeting-regression-fixtures
```

Do not dispatch parallel agents for this implementation.

## File Structure

- Create `scripts/capture-regression-fixture.swift`: command-line script that copies a local meeting into `Tests/MeetingAgentCoreTests/Fixtures/RegressionMeetings/<name>/`, generates `manifest.json` and `expected-ui.json`, and records analyzer status.
- Create `Tests/MeetingAgentCoreTests/RegressionFixtureSupport.swift`: test-only Codable models and helper functions for fixture manifests, expected UI rows, JSONL decoding, analyzer execution, and fixture translation lookup.
- Create `Tests/MeetingAgentCoreTests/MeetingRegressionFixtureAnalyzerTests.swift`: runs the existing analyzer against fixture directories and checks pass/fail expectations from each manifest.
- Create `Tests/MeetingAgentCoreTests/MeetingRegressionUIProjectionTests.swift`: loads fixture data, hydrates caption turns with stable translations by exact `sourceSegmentIDs`, and asserts `LiveCaptionDisplayState` against `expected-ui.json`.
- Create fixture directory `Tests/MeetingAgentCoreTests/Fixtures/RegressionMeetings/microsoft-teams-public-preview-en-zh/`: copied latest meeting artifacts plus generated manifest/UI expectation.

## Task 1: Add Fixture Support Types And Failing Parser Tests

**Files:**
- Create: `Tests/MeetingAgentCoreTests/RegressionFixtureSupport.swift`
- Create: `Tests/MeetingAgentCoreTests/MeetingRegressionFixtureSupportTests.swift`

- [ ] **Step 1: Write failing tests for manifest, expected UI, and translation lookup**

Create `Tests/MeetingAgentCoreTests/MeetingRegressionFixtureSupportTests.swift`:

```swift
import XCTest
@testable import MeetingAgentCore

final class MeetingRegressionFixtureSupportTests: XCTestCase {
    func testManifestDecodesKnownFailureScenario() throws {
        let data = Data(#"""
        {
          "id": "microsoft-teams-public-preview-en-zh",
          "sourceMeetingID": "D5C47AEC-4E86-4C66-9B61-FEE3D151006C",
          "scenario": "single-speaker-long-no-speech-final",
          "sourceLocale": "en-US",
          "targetLocale": "zh-CN",
          "purpose": "knownFailure",
          "expectedAnalyzerStatus": "fail",
          "expectedFailures": ["stable translations did not cover realtime final caption turns"]
        }
        """#.utf8)

        let manifest = try JSONDecoder.meetingAgent.decode(RegressionFixtureManifest.self, from: data)

        XCTAssertEqual(manifest.id, "microsoft-teams-public-preview-en-zh")
        XCTAssertEqual(manifest.scenario, "single-speaker-long-no-speech-final")
        XCTAssertEqual(manifest.purpose, .knownFailure)
        XCTAssertEqual(manifest.expectedAnalyzerStatus, .fail)
        XCTAssertEqual(manifest.expectedFailures, ["stable translations did not cover realtime final caption turns"])
    }

    func testExpectedUIDecodesDisplayModeRows() throws {
        let data = Data(#"""
        {
          "displayModes": {
            "both": [
              {
                "sourceSegmentIDs": ["segment-1", "segment-2"],
                "primaryText": "译文",
                "sourceText": "source",
                "isFinal": true,
                "translationState": "final"
              }
            ],
            "translationOnly": [
              {
                "sourceSegmentIDs": ["segment-1", "segment-2"],
                "primaryText": "译文"
              }
            ]
          }
        }
        """#.utf8)

        let expected = try JSONDecoder.meetingAgent.decode(RegressionExpectedUI.self, from: data)

        XCTAssertEqual(expected.displayModes["both"]?.first?.sourceSegmentIDs, ["segment-1", "segment-2"])
        XCTAssertEqual(expected.displayModes["both"]?.first?.primaryText, "译文")
        XCTAssertEqual(expected.displayModes["both"]?.first?.sourceText, "source")
        XCTAssertEqual(expected.displayModes["translationOnly"]?.first?.primaryText, "译文")
    }

    func testTranslationLookupRequiresExactSourceSegmentSet() throws {
        let record = TranslationResultPersistenceRecord(
            meetingID: UUID(uuidString: "D5C47AEC-4E86-4C66-9B61-FEE3D151006C")!,
            resultID: "stable-1",
            sourceID: "block-1",
            laneID: TranslationLaneID(speaker: TranscriptSpeaker(identifier: "speaker-1", label: "User A"), sourceLocale: "en-US", targetLocale: "zh-CN"),
            sourceSegmentIDs: ["segment-1", "segment-2"],
            sourceTextHash: "hash-1",
            sourceText: "source text",
            translatedText: "译文",
            displayState: .stableFinal,
            boundaryReason: .maxLength,
            providerID: "fixture",
            createdAt: Date(timeIntervalSince1970: 1),
            finalizedAt: Date(timeIntervalSince1970: 2)
        )
        let lookup = RegressionFixtureTranslationLookup(records: [record])

        XCTAssertEqual(try lookup.translation(forSourceSegmentIDs: ["segment-2", "segment-1"]), "译文")
        XCTAssertThrowsError(try lookup.translation(forSourceSegmentIDs: ["segment-1"]))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```sh
swift test --filter MeetingRegressionFixtureSupportTests
```

Expected: compile failure because `RegressionFixtureManifest`, `RegressionExpectedUI`, and `RegressionFixtureTranslationLookup` do not exist.

- [ ] **Step 3: Implement fixture support types**

Create `Tests/MeetingAgentCoreTests/RegressionFixtureSupport.swift`:

```swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run:

```sh
swift test --filter MeetingRegressionFixtureSupportTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```sh
git add Tests/MeetingAgentCoreTests/RegressionFixtureSupport.swift Tests/MeetingAgentCoreTests/MeetingRegressionFixtureSupportTests.swift
git commit -m "Add regression fixture support models"
```

## Task 2: Add Capture Script

**Files:**
- Create: `scripts/capture-regression-fixture.swift`

- [ ] **Step 1: Write script with validation, copy, manifest, expected UI generation**

Create `scripts/capture-regression-fixture.swift` with:

```swift
import Foundation

struct Arguments {
    var meeting: URL
    var name: String
    var scenario: String
    var output: URL
}

struct Manifest: Codable {
    var id: String
    var sourceMeetingID: String
    var scenario: String
    var sourceLocale: String
    var targetLocale: String
    var purpose: String
    var expectedAnalyzerStatus: String
    var expectedFailures: [String]
    var notes: [String]
}

struct TranscriptDocument: Codable {
    var segments: [TranscriptSegment]
}

struct TranscriptSegment: Codable {
    var id: String
    var text: String
    var isFinal: Bool
    var speechFinal: Bool?
}

struct TranslationRecord: Codable {
    var sourceSegmentIDs: [String]
    var sourceText: String
    var translatedText: String
    var displayState: String
}

struct ExpectedUI: Codable {
    var displayModes: [String: [ExpectedUIRow]]
}

struct ExpectedUIRow: Codable {
    var sourceSegmentIDs: [String]
    var primaryText: String
    var sourceText: String?
    var isFinal: Bool?
    var translationState: String?
}

let requiredFiles = [
    "audio.wav",
    "metadata.json",
    "diagnostics.json",
    "transcript-events.jsonl",
    "transcript.json",
    "translation-results.jsonl",
    "performance-events.jsonl"
]

func parseArguments(_ values: [String]) throws -> Arguments {
    var meeting: String?
    var name: String?
    var scenario: String?
    var output: String?
    var index = 0
    while index < values.count {
        let key = values[index]
        guard index + 1 < values.count else { throw fatal("Missing value for \(key)") }
        let value = values[index + 1]
        switch key {
        case "--meeting": meeting = value
        case "--name": name = value
        case "--scenario": scenario = value
        case "--output": output = value
        default: throw fatal("Unknown argument \(key)")
        }
        index += 2
    }
    guard let meeting, let name, let scenario, let output else {
        throw fatal("Usage: swift scripts/capture-regression-fixture.swift --meeting <dir> --name <fixture-name> --scenario <scenario> --output <fixture-root>")
    }
    return Arguments(
        meeting: URL(fileURLWithPath: meeting, isDirectory: true),
        name: name,
        scenario: scenario,
        output: URL(fileURLWithPath: output, isDirectory: true)
    )
}

func fatal(_ message: String) -> NSError {
    NSError(domain: "capture-regression-fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

func decodeJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: Data(contentsOf: url))
}

func decodeJSONLLines<T: Decodable>(_ type: T.Type, from url: URL) throws -> [T] {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try String(contentsOf: url, encoding: .utf8)
        .split(separator: "\n")
        .map { try decoder.decode(type, from: Data($0.utf8)) }
}

func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(value).write(to: url)
}

func runAnalyzer(fixtureURL: URL) -> (status: String, failures: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["swift", "scripts/analyze-meeting-performance.swift", "--assert-translation-e2e", fixtureURL.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return ("fail", ["Failed to run analyzer: \(error.localizedDescription)"])
    }
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let failures = output.split(separator: "\n")
        .map(String.init)
        .filter { $0.hasPrefix("Failure: ") }
        .map { String($0.dropFirst("Failure: ".count)) }
    return process.terminationStatus == 0 ? ("pass", []) : ("fail", failures)
}

func expectedUI(transcript: TranscriptDocument, translations: [TranslationRecord]) -> ExpectedUI {
    let segmentText = Dictionary(uniqueKeysWithValues: transcript.segments.map { ($0.id, $0.text) })
    let rows = translations.map { record in
        ExpectedUIRow(
            sourceSegmentIDs: record.sourceSegmentIDs,
            primaryText: record.translatedText,
            sourceText: record.sourceSegmentIDs.compactMap { segmentText[$0] }.joined(separator: " "),
            isFinal: true,
            translationState: record.displayState == "stableFinal" ? "final" : record.displayState
        )
    }
    return ExpectedUI(displayModes: [
        "both": rows,
        "translationOnly": rows.map {
            ExpectedUIRow(
                sourceSegmentIDs: $0.sourceSegmentIDs,
                primaryText: $0.primaryText,
                sourceText: nil,
                isFinal: $0.isFinal,
                translationState: $0.translationState
            )
        }
    ])
}

do {
    let arguments = try parseArguments(Array(CommandLine.arguments.dropFirst()))
    let destination = arguments.output.appendingPathComponent(arguments.name, isDirectory: true)
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

    for filename in requiredFiles {
        let source = arguments.meeting.appendingPathComponent(filename)
        guard fileManager.fileExists(atPath: source.path) else {
            throw fatal("Missing required artifact \(source.path)")
        }
        let target = destination.appendingPathComponent(filename)
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
        try fileManager.copyItem(at: source, to: target)
    }

    let transcript = try decodeJSON(TranscriptDocument.self, from: destination.appendingPathComponent("transcript.json"))
    let translations = try decodeJSONLLines(TranslationRecord.self, from: destination.appendingPathComponent("translation-results.jsonl"))
    try writeJSON(expectedUI(transcript: transcript, translations: translations), to: destination.appendingPathComponent("expected-ui.json"))

    let analyzer = runAnalyzer(fixtureURL: destination)
    let manifest = Manifest(
        id: arguments.name,
        sourceMeetingID: arguments.meeting.lastPathComponent,
        scenario: arguments.scenario,
        sourceLocale: "en-US",
        targetLocale: "zh-CN",
        purpose: analyzer.status == "pass" ? "golden" : "knownFailure",
        expectedAnalyzerStatus: analyzer.status,
        expectedFailures: analyzer.failures,
        notes: [
            "Single speaker.",
            "Long content.",
            "Final transcript segments have speechFinal=false."
        ]
    )
    try writeJSON(manifest, to: destination.appendingPathComponent("manifest.json"))

    print("fixture=\(arguments.name)")
    print("scenario=\(arguments.scenario)")
    print("segments=\(transcript.segments.count)")
    print("translation_records=\(translations.count)")
    print("analyzer_status=\(analyzer.status)")
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
```

- [ ] **Step 2: Run script help failure**

Run:

```sh
swift scripts/capture-regression-fixture.swift
```

Expected: exit 1 with usage text.

- [ ] **Step 3: Commit**

```sh
git add scripts/capture-regression-fixture.swift
git commit -m "Add regression fixture capture script"
```

## Task 3: Capture Latest Meeting Fixture

**Files:**
- Create directory: `Tests/MeetingAgentCoreTests/Fixtures/RegressionMeetings/microsoft-teams-public-preview-en-zh/`

- [ ] **Step 1: Run capture script against latest meeting**

Run:

```sh
swift scripts/capture-regression-fixture.swift \
  --meeting "/Users/allan/Library/Application Support/MeetingAgent/Meetings/D5C47AEC-4E86-4C66-9B61-FEE3D151006C" \
  --name microsoft-teams-public-preview-en-zh \
  --scenario single-speaker-long-no-speech-final \
  --output Tests/MeetingAgentCoreTests/Fixtures/RegressionMeetings
```

Expected output includes:

```text
fixture=microsoft-teams-public-preview-en-zh
scenario=single-speaker-long-no-speech-final
segments=7
translation_records=3
analyzer_status=fail
```

- [ ] **Step 2: Inspect generated manifest**

Run:

```sh
cat Tests/MeetingAgentCoreTests/Fixtures/RegressionMeetings/microsoft-teams-public-preview-en-zh/manifest.json
```

Expected: `purpose` is `knownFailure`, `expectedAnalyzerStatus` is `fail`, and `expectedFailures` includes projection/coverage failure text.

- [ ] **Step 3: Commit**

```sh
git add Tests/MeetingAgentCoreTests/Fixtures/RegressionMeetings/microsoft-teams-public-preview-en-zh
git commit -m "Add single-speaker long meeting regression fixture"
```

## Task 4: Add Analyzer Fixture Tests

**Files:**
- Create: `Tests/MeetingAgentCoreTests/MeetingRegressionFixtureAnalyzerTests.swift`

- [ ] **Step 1: Write failing analyzer fixture test**

Create `Tests/MeetingAgentCoreTests/MeetingRegressionFixtureAnalyzerTests.swift`:

```swift
import XCTest

final class MeetingRegressionFixtureAnalyzerTests: XCTestCase {
    func testRegressionFixturesMatchAnalyzerExpectations() throws {
        for fixtureURL in try RegressionFixtureFiles.allFixtureDirectories() {
            let manifest = try RegressionFixtureFiles.loadManifest(in: fixtureURL)
            let result = try RegressionFixtureFiles.runAnalyzer(fixtureURL)

            switch manifest.expectedAnalyzerStatus {
            case .pass:
                XCTAssertEqual(result.status, 0, "\(manifest.id) analyzer output:\n\(result.stdout)\n\(result.stderr)")
            case .fail:
                XCTAssertNotEqual(result.status, 0, "\(manifest.id) should remain known-failure until promoted")
                for failure in manifest.expectedFailures {
                    XCTAssertTrue(
                        result.stdout.contains(failure) || result.stderr.contains(failure),
                        "\(manifest.id) missing expected failure \(failure)\nstdout:\n\(result.stdout)\nstderr:\n\(result.stderr)"
                    )
                }
            }
        }
    }
}
```

- [ ] **Step 2: Extend support file with fixture directory and analyzer helpers**

Append to `Tests/MeetingAgentCoreTests/RegressionFixtureSupport.swift`:

```swift
struct RegressionCommandResult {
    var status: Int32
    var stdout: String
    var stderr: String
}

enum RegressionFixtureFiles {
    static var fixtureRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
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
        process.currentDirectoryURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
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
```

- [ ] **Step 3: Run analyzer fixture test**

Run:

```sh
swift test --filter MeetingRegressionFixtureAnalyzerTests
```

Expected: PASS with the first fixture recognized as known-failure.

- [ ] **Step 4: Commit**

```sh
git add Tests/MeetingAgentCoreTests/RegressionFixtureSupport.swift Tests/MeetingAgentCoreTests/MeetingRegressionFixtureAnalyzerTests.swift
git commit -m "Add regression fixture analyzer test"
```

## Task 5: Add UI Projection Replay Test

**Files:**
- Create: `Tests/MeetingAgentCoreTests/MeetingRegressionUIProjectionTests.swift`
- Modify: `Tests/MeetingAgentCoreTests/RegressionFixtureSupport.swift`

- [ ] **Step 1: Write UI projection test**

Create `Tests/MeetingAgentCoreTests/MeetingRegressionUIProjectionTests.swift`:

```swift
import XCTest
@testable import MeetingAgentCore

final class MeetingRegressionUIProjectionTests: XCTestCase {
    func testGoldenFixturesMatchExpectedDisplayState() throws {
        for fixtureURL in try RegressionFixtureFiles.allFixtureDirectories() {
            let manifest = try RegressionFixtureFiles.loadManifest(in: fixtureURL)
            guard manifest.purpose == .golden else { continue }
            let expected = try RegressionFixtureFiles.loadExpectedUI(in: fixtureURL)
            let turns = try RegressionFixtureFiles.projectStableTranslationTurns(in: fixtureURL, manifest: manifest)

            try assertDisplayMode("both", expected: expected, turns: turns, displayMode: .both, fixtureID: manifest.id)
            try assertDisplayMode("translationOnly", expected: expected, turns: turns, displayMode: .translationOnly, fixtureID: manifest.id)
        }
    }

    func testKnownFailureFixturesCarryExpectedUIForPromotion() throws {
        for fixtureURL in try RegressionFixtureFiles.allFixtureDirectories() {
            let manifest = try RegressionFixtureFiles.loadManifest(in: fixtureURL)
            guard manifest.purpose == .knownFailure else { continue }
            let expected = try RegressionFixtureFiles.loadExpectedUI(in: fixtureURL)

            XCTAssertFalse(expected.displayModes["both", default: []].isEmpty, "\(manifest.id) should carry provisional both-mode expected UI")
            XCTAssertFalse(expected.displayModes["translationOnly", default: []].isEmpty, "\(manifest.id) should carry provisional translation-only expected UI")
        }
    }

    private func assertDisplayMode(
        _ key: String,
        expected: RegressionExpectedUI,
        turns: [LiveCaptionTurn],
        displayMode: LiveCaptionDisplayMode,
        fixtureID: String
    ) throws {
        let expectedRows = expected.displayModes[key, default: []]
        XCTAssertEqual(turns.count, expectedRows.count, "\(fixtureID) \(key) turn count")
        for (turn, row) in zip(turns, expectedRows) {
            XCTAssertEqual(turn.sourceSegmentIDs, row.sourceSegmentIDs, "\(fixtureID) \(key) sourceSegmentIDs")
            let state = LiveCaptionDisplayState(turn: turn, secondLanguageEnabled: true, displayMode: displayMode)
            switch state {
            case .translated(let primaryText, let sourceText):
                XCTAssertEqual(primaryText, row.primaryText, "\(fixtureID) \(key) primary")
                XCTAssertEqual(sourceText, row.sourceText, "\(fixtureID) \(key) source")
            case .originalOnly(let text):
                XCTAssertEqual(text, row.primaryText, "\(fixtureID) \(key) originalOnly")
            case .pending(let sourceText):
                XCTFail("\(fixtureID) \(key) unexpectedly pending for \(sourceText)")
            case .failed(let sourceText, let message):
                XCTFail("\(fixtureID) \(key) unexpectedly failed for \(sourceText): \(message)")
            }
        }
    }
}
```

- [ ] **Step 2: Add expected UI loaders and projection helper**

Append to `RegressionFixtureFiles` in `Tests/MeetingAgentCoreTests/RegressionFixtureSupport.swift`:

```swift
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
        let lines = try String(contentsOf: fixtureURL.appendingPathComponent("translation-results.jsonl"), encoding: .utf8)
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
```

- [ ] **Step 3: Run UI projection tests**

Run:

```sh
swift test --filter MeetingRegressionUIProjectionTests
```

Expected: PASS. The first known-failure fixture only checks that provisional expected UI exists.

- [ ] **Step 4: Commit**

```sh
git add Tests/MeetingAgentCoreTests/RegressionFixtureSupport.swift Tests/MeetingAgentCoreTests/MeetingRegressionUIProjectionTests.swift
git commit -m "Add regression fixture UI projection test"
```

## Task 6: Full Verification

**Files:**
- No new files.

- [ ] **Step 1: Run focused regression tests**

Run:

```sh
swift test --filter MeetingRegression
```

Expected: PASS.

- [ ] **Step 2: Run required project test gate**

Run:

```sh
make test
```

Expected: all tests pass and coverage gate passes.

- [ ] **Step 3: Inspect status**

Run:

```sh
git status --short
```

Expected: clean worktree after all commits.

## Self-Review

- Spec coverage: capture script, fixture layout, known-failure manifest, analyzer test, UI projection replay test, exact `sourceSegmentIDs` fixture lookup, and first latest-meeting scenario are all mapped to tasks.
- Placeholder scan: no unfinished placeholder steps remain.
- Type consistency: manifest/status/purpose names match across script and test support; fixture path is consistent with the spec.
