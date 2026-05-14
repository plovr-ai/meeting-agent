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

struct Metadata: Codable {
    var id: String
    var speechLocaleIdentifier: String?
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

struct CaptionDocument: Codable {
    var turns: [CaptionTurn]
}

struct CaptionTurn: Codable {
    var id: String
    var sections: [CaptionSection]
    var state: String
}

struct CaptionSection: Codable {
    var text: String
}

struct TranslationRecord: Codable {
    var sourceSegmentIDs: [String]
    var sourceText: String
    var translatedText: String
    var displayState: String
    var laneID: TranslationLane
}

struct TranslationLane: Codable {
    var sourceLocale: String
    var targetLocale: String
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
        case "--meeting":
            meeting = value
        case "--name":
            name = value
        case "--scenario":
            scenario = value
        case "--output":
            output = value
        default:
            throw fatal("Unknown argument \(key)")
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

func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}

func decodeJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
    try decoder().decode(type, from: Data(contentsOf: url))
}

func loadTranscript(from url: URL) throws -> TranscriptDocument {
    let data = try Data(contentsOf: url)
    do {
        return try decoder().decode(TranscriptDocument.self, from: data)
    } catch {
        let captionDocument = try decoder().decode(CaptionDocument.self, from: data)
        return TranscriptDocument(segments: captionDocument.turns.map { turn in
            TranscriptSegment(
                id: turn.id,
                text: turn.sections
                    .map(\.text)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n"),
                isFinal: turn.state == "final",
                speechFinal: turn.state == "final"
            )
        })
    }
}

func decodeJSONLLines<T: Decodable>(_ type: T.Type, from url: URL) throws -> [T] {
    try String(contentsOf: url, encoding: .utf8)
        .split(separator: "\n")
        .map { try decoder().decode(type, from: Data($0.utf8)) }
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
    process.arguments = [
        "swift",
        "scripts/analyze-meeting-performance.swift",
        "--assert-translation-e2e",
        fixtureURL.path
    ]
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

    let metadata = try decodeJSON(Metadata.self, from: destination.appendingPathComponent("metadata.json"))
    let transcript = try loadTranscript(from: destination.appendingPathComponent("transcript.json"))
    let translations = try decodeJSONLLines(TranslationRecord.self, from: destination.appendingPathComponent("translation-results.jsonl"))
    try writeJSON(expectedUI(transcript: transcript, translations: translations), to: destination.appendingPathComponent("expected-ui.json"))

    let analyzer = runAnalyzer(fixtureURL: destination)
    let sourceLocale = translations.first?.laneID.sourceLocale ?? metadata.speechLocaleIdentifier ?? "en-US"
    let targetLocale = translations.first?.laneID.targetLocale ?? "zh-CN"
    let manifest = Manifest(
        id: arguments.name,
        sourceMeetingID: metadata.id,
        scenario: arguments.scenario,
        sourceLocale: sourceLocale,
        targetLocale: targetLocale,
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
