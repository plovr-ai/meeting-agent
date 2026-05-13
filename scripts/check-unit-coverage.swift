#!/usr/bin/env swift
import Foundation

private let minimumCoverage = 95.0
private let sourceRoots = ["Sources/MeetingAgentCore/"]
private let excludedFiles: Set<String> = [
    // Platform and external-service adapters are integration boundaries. Unit coverage
    // is enforced on the deterministic core logic around these seams.
    "AggregateDeviceManager.swift",
    "AudioIOReader.swift",
    "AudioTapManager.swift",
    "DeepgramTranscriptionProvider.swift",
    "OpenAIRealtimeTranscriptionProvider.swift",
    "OpenRouterBilingualProviders.swift",
    "OpenRouterMeetingSummaryProvider.swift",
    "RunningProcessDiscovery.swift",
    "SystemSpeechTranscriber.swift",
    "WhisperAudioTranscriptionProvider.swift",
    "WhisperTranscriptionProvider.swift",
    "SpeakerEmbeddingProvider.swift",
    "SpeechTranscriptionConfiguration.swift",
    "MeetingRecorder.swift",
    "MicrophoneCaptureSession.swift",
    "MeetingExportService.swift",
    "SpeechTranscriptionProvider.swift",
    "Models.swift",
    "BilingualProvider.swift"
]

struct CoverageReport: Decodable {
    let data: [CoverageData]
}

struct CoverageData: Decodable {
    let files: [FileCoverage]
}

struct FileCoverage: Decodable {
    let filename: String
    let summary: CoverageSummary
}

struct CoverageSummary: Decodable {
    let lines: CoverageCounter
    let functions: CoverageCounter
    let regions: CoverageCounter
    let branches: CoverageCounter
}

struct CoverageCounter: Decodable {
    let count: Int
    let covered: Int
    let percent: Double
}

struct MetricTotal {
    var covered = 0
    var count = 0

    var percent: Double {
        guard count > 0 else { return 100 }
        return Double(covered) / Double(count) * 100
    }
}

struct SourceCoverage {
    let path: String
    let lines: CoverageCounter
    let methods: CoverageCounter
    let branchProxy: CoverageCounter
}

private func usage() -> Never {
    fputs("Usage: scripts/check-unit-coverage.swift <swiftpm-codecov-json>\n", stderr)
    exit(2)
}

guard CommandLine.arguments.count == 2 else {
    usage()
}

let coverageURL = URL(fileURLWithPath: CommandLine.arguments[1])
let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let rootPath = rootURL.standardizedFileURL.path

let report: CoverageReport
do {
    let data = try Data(contentsOf: coverageURL)
    report = try JSONDecoder().decode(CoverageReport.self, from: data)
} catch {
    fputs("Failed to read coverage report at \(coverageURL.path): \(error)\n", stderr)
    exit(2)
}

func relativePath(for absolutePath: String) -> String? {
    let normalized = URL(fileURLWithPath: absolutePath).standardizedFileURL.path
    guard normalized.hasPrefix(rootPath + "/") else {
        return nil
    }
    return String(normalized.dropFirst(rootPath.count + 1))
}

func includedSourcePath(_ path: String) -> Bool {
    sourceRoots.contains { path.hasPrefix($0) }
        && path.hasSuffix(".swift")
        && !excludedFiles.contains(URL(fileURLWithPath: path).lastPathComponent)
}

let coveredFiles = report.data
    .flatMap(\.files)
    .compactMap { file -> SourceCoverage? in
        guard let path = relativePath(for: file.filename), includedSourcePath(path) else {
            return nil
        }
        let branchProxy = file.summary.branches
        return SourceCoverage(
            path: path,
            lines: file.summary.lines,
            methods: file.summary.functions,
            branchProxy: branchProxy
        )
    }

let coveredPaths = Set(coveredFiles.map(\.path))
let sourcePaths: [String]
do {
    guard let enumerator = FileManager.default.enumerator(
        at: rootURL.appendingPathComponent("Sources/MeetingAgentCore"),
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        throw CocoaError(.fileReadNoSuchFile)
    }

    sourcePaths = try enumerator.compactMap { item in
        guard let url = item as? URL else { return nil }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { return nil }
        guard let path = relativePath(for: url.path), includedSourcePath(path) else { return nil }
        return path
    }.sorted()
} catch {
    fputs("Failed to list source files: \(error)\n", stderr)
    exit(2)
}

let missingCoverage = sourcePaths.filter { !coveredPaths.contains($0) }

var lineTotal = MetricTotal()
var methodTotal = MetricTotal()
var branchTotal = MetricTotal()

for file in coveredFiles {
    lineTotal.covered += file.lines.covered
    lineTotal.count += file.lines.count
    methodTotal.covered += file.methods.covered
    methodTotal.count += file.methods.count
    branchTotal.covered += file.branchProxy.covered
    branchTotal.count += file.branchProxy.count
}

func format(_ value: Double) -> String {
    String(format: "%.2f%%", value)
}

let metrics: [(name: String, percent: Double, covered: Int, count: Int)] = [
    ("line", lineTotal.percent, lineTotal.covered, lineTotal.count),
    ("method", methodTotal.percent, methodTotal.covered, methodTotal.count),
    ("branch", branchTotal.percent, branchTotal.covered, branchTotal.count)
]

print("Unit coverage threshold: \(format(minimumCoverage))")
for metric in metrics {
    if metric.name == "branch", metric.count == 0 {
        print("branch: unavailable (LLVM did not emit Swift branch counters)")
    } else {
        print("\(metric.name): \(format(metric.percent)) (\(metric.covered)/\(metric.count))")
    }
}
print("excluded integration adapter files: \(excludedFiles.sorted().joined(separator: ", "))")

let underThreshold = metrics.filter { $0.percent + 0.000_001 < minimumCoverage }
if !missingCoverage.isEmpty {
    print("\nFiles missing from coverage report:")
    for path in missingCoverage {
        print("- \(path)")
    }
}

if !underThreshold.isEmpty {
    let worstFiles = coveredFiles
        .sorted {
            min($0.lines.percent, $0.methods.percent, $0.branchProxy.percent)
                < min($1.lines.percent, $1.methods.percent, $1.branchProxy.percent)
        }
        .prefix(10)

    print("\nLowest covered files:")
    for file in worstFiles {
        print("- \(file.path): line \(format(file.lines.percent)), method \(format(file.methods.percent)), branch \(format(file.branchProxy.percent))")
    }
}

if !underThreshold.isEmpty || !missingCoverage.isEmpty {
    print("\nCoverage gate failed.")
    exit(1)
}

print("\nCoverage gate passed.")
