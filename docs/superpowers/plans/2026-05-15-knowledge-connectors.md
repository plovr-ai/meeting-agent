# Knowledge Connectors Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the phase 1 Karpathy Wiki connector so MeetingAgent can export canonical meeting knowledge packages into `<WikiRoot>/raw/meetings/<meeting-slug>/`.

**Architecture:** Keep the canonical meeting package in `MeetingAgentCore`, add a connector boundary that writes the same package to Karpathy Wiki, and expose a small app workflow for configuring the wiki root and triggering export. GBrain remains represented by connector enum/model shape only; no GBrain command execution is wired in this phase.

**Tech Stack:** Swift 5.9, SwiftUI, XCTest, Foundation file APIs, existing `MeetingSessionState`, `MeetingExportService`, and Markdown renderers.

---

## Scope

This plan implements Phase 1 from `docs/superpowers/specs/2026-05-15-knowledge-connectors-design.md`.

It intentionally excludes reviewed item state, automatic agent execution, GBrain CLI execution, and GBrain MCP execution.

## File Structure

- Create `Sources/MeetingAgentCore/MeetingKnowledgePackageWriter.swift`
  - Owns writing `meeting.md`, `transcript.md`, `knowledge.md`, and `ingest.md` for any destination.
  - Returns the files written so connectors and UI can report success.

- Modify `Sources/MeetingAgentCore/MeetingKnowledgePackage.swift`
  - Add `renderIngest(_:)`.
  - Keep all Markdown rendering in one type.

- Modify `Sources/MeetingAgentCore/MeetingExportService.swift`
  - Replace private package file-writing with `MeetingKnowledgePackageWriter`.
  - Existing manual package export gains `ingest.md`.

- Create `Sources/MeetingAgentCore/KnowledgeConnector.swift`
  - Defines connector kind, configuration, validation, status, result, and protocol.

- Create `Sources/MeetingAgentCore/KarpathyWikiConnector.swift`
  - Validates wiki root.
  - Builds `raw/meetings/<slug>/`.
  - Writes the canonical package with `MeetingKnowledgePackageWriter`.

- Modify `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
  - Add a `syncKnowledgeToKarpathyWiki(for:wikiRoot:)` method that uses session state and connector.

- Modify `Sources/MeetingAgentApp/SettingsView.swift`
  - Add Knowledge Destinations panel with Karpathy Wiki enable toggle and wiki root path field.

- Modify `Sources/MeetingAgentApp/MainWindowView.swift`
  - Store simple app-level Karpathy Wiki settings with `@AppStorage`.
  - Add "Export to Wiki" action to the meeting overflow menu.

- Add tests:
  - `Tests/MeetingAgentCoreTests/MeetingKnowledgePackageWriterTests.swift`
  - `Tests/MeetingAgentCoreTests/KarpathyWikiConnectorTests.swift`
  - Extend `Tests/MeetingAgentCoreTests/MeetingExportServiceTests.swift`
  - Extend `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`
  - Extend source-layout tests for Settings and MainWindow.

---

### Task 1: Add `ingest.md` To The Canonical Knowledge Package

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingKnowledgePackage.swift`
- Create: `Sources/MeetingAgentCore/MeetingKnowledgePackageWriter.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingKnowledgePackageWriterTests.swift`
- Modify: `Tests/MeetingAgentCoreTests/MeetingExportServiceTests.swift`

- [ ] **Step 1: Write failing writer tests**

Create `Tests/MeetingAgentCoreTests/MeetingKnowledgePackageWriterTests.swift`:

```swift
import XCTest
@testable import MeetingAgentCore

final class MeetingKnowledgePackageWriterTests: XCTestCase {
    func testWritesCanonicalPackageWithIngestFile() throws {
        let fixture = try MeetingKnowledgePackageWriterFixture()
        defer { fixture.cleanup() }
        let destination = fixture.root.appendingPathComponent("package", isDirectory: true)

        let result = try MeetingKnowledgePackageWriter().write(fixture.package, to: destination)

        XCTAssertEqual(result.filesWritten.map(\.lastPathComponent).sorted(), [
            "ingest.md",
            "knowledge.md",
            "meeting.md",
            "transcript.md"
        ])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path).sorted(), [
            "ingest.md",
            "knowledge.md",
            "meeting.md",
            "transcript.md"
        ])
        let ingest = try String(contentsOf: destination.appendingPathComponent("ingest.md"), encoding: .utf8)
        XCTAssertTrue(ingest.contains("# Ingest Meeting"))
        XCTAssertTrue(ingest.contains("Treat `transcript.md` as source evidence."))
        XCTAssertTrue(ingest.contains("Treat `knowledge.md` items as proposed deltas, not automatic truth."))
        XCTAssertTrue(ingest.contains("Preserve evidence links"))
    }

    func testWriterFailsWhenDestinationExistsAsFile() throws {
        let fixture = try MeetingKnowledgePackageWriterFixture()
        defer { fixture.cleanup() }
        let destination = fixture.root.appendingPathComponent("package")
        try "not a directory".write(to: destination, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try MeetingKnowledgePackageWriter().write(fixture.package, to: destination)) { error in
            XCTAssertEqual(error as? MeetingKnowledgePackageWriterError, .destinationIsFile(destination.path))
        }
    }
}

private struct MeetingKnowledgePackageWriterFixture {
    let root: URL
    let package: MeetingKnowledgePackage

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-knowledge-package-writer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let record = MeetingRecord(
            id: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
            name: "Japan GTM Sync",
            startedAt: Date(timeIntervalSince1970: 1_777_000_000),
            endedAt: Date(timeIntervalSince1970: 1_777_000_600),
            audioURL: root.appendingPathComponent("audio.wav"),
            transcriptURL: nil,
            transcriptJSONURL: root.appendingPathComponent("transcript.json"),
            summaryURL: root.appendingPathComponent("summary.md"),
            diagnosticsURL: root.appendingPathComponent("diagnostics.json"),
            transcriptionStatus: .transcribed,
            transcriptionFailureReason: nil,
            speechProvider: .whisper,
            speechLocaleIdentifier: "en-US"
        )
        let summary = MeetingSummary(
            overview: "The team agreed to scope launch to Tokyo.",
            keyTopics: ["Japan GTM"],
            decisions: [],
            actionItems: [],
            openQuestions: [],
            risks: [],
            followUps: [],
            language: "en-US",
            sourceSegmentIDs: ["segment-1"],
            generatedAt: Date(timeIntervalSince1970: 1_777_000_700),
            provider: "test",
            status: .succeeded,
            failureReason: nil
        )
        let segment = TranscriptSegment(
            id: "segment-1",
            speaker: TranscriptSpeaker(identifier: "a", label: "Alice"),
            startTimeSeconds: 12,
            text: "Let's scope the launch to Tokyo.",
            timingSource: .precise
        )
        package = MeetingKnowledgePackage(
            record: record,
            summary: summary,
            segments: [segment],
            knowledge: MeetingKnowledge(
                decisions: [
                    MeetingKnowledgeItem(
                        id: "decision_001",
                        statement: "Launch starts with Tokyo.",
                        confidence: .high,
                        status: "Proposed",
                        evidence: [
                            MeetingKnowledgeEvidence(
                                segmentID: "segment-1",
                                speaker: "Alice",
                                timestamp: "00:00:12",
                                anchor: "t-00-00-12"
                            )
                        ]
                    )
                ]
            )
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
```

- [ ] **Step 2: Run the new tests to verify failure**

Run:

```sh
swift test --filter MeetingKnowledgePackageWriterTests
```

Expected: FAIL because `MeetingKnowledgePackageWriter` and `renderIngest` do not exist.

- [ ] **Step 3: Add ingest renderer**

In `Sources/MeetingAgentCore/MeetingKnowledgePackage.swift`, add this method inside `MeetingKnowledgePackageMarkdownRenderer` after `renderKnowledge(_:)`:

```swift
public static func renderIngest(_ package: MeetingKnowledgePackage) -> String {
    let title = title(for: package)
    return """
    # Ingest Meeting

    Read this meeting source package:

    - [[meeting]]
    - [[transcript]]
    - [[knowledge]]

    ## Source

    - Meeting ID: \(package.record.id.uuidString)
    - Title: \(title)
    - Started: \(iso(package.record.startedAt))
    - Language: \(package.summary?.language ?? package.record.speechLocaleIdentifier)

    ## Rules

    - Treat this directory as one meeting source package.
    - Treat `transcript.md` as source evidence.
    - Treat `knowledge.md` items as proposed deltas, not automatic truth.
    - Update the long-term wiki or brain according to the local schema.
    - Preserve evidence links or convert them into the destination citation format.
    - Append timeline entries for accepted decisions, actions, and important entity updates.
    - Mark inferred judgments, cultural interpretation, or relationship insight as inference.

    """
}
```

- [ ] **Step 4: Add package writer**

Create `Sources/MeetingAgentCore/MeetingKnowledgePackageWriter.swift`:

```swift
import Foundation

public enum MeetingKnowledgePackageWriterError: Error, Equatable, LocalizedError {
    case destinationIsFile(String)

    public var errorDescription: String? {
        switch self {
        case .destinationIsFile(let path):
            return "Knowledge package destination is a file: \(path)"
        }
    }
}

public struct MeetingKnowledgePackageWriteResult: Equatable {
    public let destinationURL: URL
    public let filesWritten: [URL]

    public init(destinationURL: URL, filesWritten: [URL]) {
        self.destinationURL = destinationURL
        self.filesWritten = filesWritten
    }
}

public struct MeetingKnowledgePackageWriter {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    @discardableResult
    public func write(_ package: MeetingKnowledgePackage, to destinationURL: URL) throws -> MeetingKnowledgePackageWriteResult {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: destinationURL.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            throw MeetingKnowledgePackageWriterError.destinationIsFile(destinationURL.path)
        }

        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        let files: [(String, String)] = [
            ("meeting.md", MeetingKnowledgePackageMarkdownRenderer.renderMeeting(package)),
            ("transcript.md", MeetingKnowledgePackageMarkdownRenderer.renderTranscript(package)),
            ("knowledge.md", MeetingKnowledgePackageMarkdownRenderer.renderKnowledge(package)),
            ("ingest.md", MeetingKnowledgePackageMarkdownRenderer.renderIngest(package))
        ]

        let written = try files.map { filename, content in
            let url = destinationURL.appendingPathComponent(filename)
            try content.write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        return MeetingKnowledgePackageWriteResult(destinationURL: destinationURL, filesWritten: written)
    }
}
```

- [ ] **Step 5: Route existing export through writer**

In `Sources/MeetingAgentCore/MeetingExportService.swift`, replace the body of private `exportKnowledgePackage(package:to:)` with:

```swift
private func exportKnowledgePackage(package: MeetingKnowledgePackage, to destinationURL: URL) throws {
    try MeetingKnowledgePackageWriter(fileManager: fileManager).write(package, to: destinationURL)
}
```

- [ ] **Step 6: Update existing export test for `ingest.md`**

In `Tests/MeetingAgentCoreTests/MeetingExportServiceTests.swift`, update `testExportsKnowledgePackageMarkdownFiles`:

```swift
XCTAssertEqual(files, ["ingest.md", "knowledge.md", "meeting.md", "transcript.md"])
```

Then read and assert the ingest file:

```swift
let ingest = try String(contentsOf: destination.appendingPathComponent("ingest.md"), encoding: .utf8)
XCTAssertTrue(ingest.contains("# Ingest Meeting"))
XCTAssertTrue(ingest.contains("Treat `knowledge.md` items as proposed deltas"))
```

- [ ] **Step 7: Run package writer and export service tests**

Run:

```sh
swift test --filter MeetingKnowledgePackageWriterTests
swift test --filter MeetingExportServiceTests/testExportsKnowledgePackageMarkdownFiles
```

Expected: PASS.

- [ ] **Step 8: Commit**

```sh
git add Sources/MeetingAgentCore/MeetingKnowledgePackage.swift Sources/MeetingAgentCore/MeetingKnowledgePackageWriter.swift Sources/MeetingAgentCore/MeetingExportService.swift Tests/MeetingAgentCoreTests/MeetingKnowledgePackageWriterTests.swift Tests/MeetingAgentCoreTests/MeetingExportServiceTests.swift
git commit -m "feat: write canonical meeting knowledge packages"
```

---

### Task 2: Add Connector Models And Karpathy Wiki File Connector

**Files:**
- Create: `Sources/MeetingAgentCore/KnowledgeConnector.swift`
- Create: `Sources/MeetingAgentCore/KarpathyWikiConnector.swift`
- Test: `Tests/MeetingAgentCoreTests/KarpathyWikiConnectorTests.swift`

- [ ] **Step 1: Write failing connector tests**

Create `Tests/MeetingAgentCoreTests/KarpathyWikiConnectorTests.swift`:

```swift
import XCTest
@testable import MeetingAgentCore

final class KarpathyWikiConnectorTests: XCTestCase {
    func testValidationFailsWhenRootMissing() async {
        let connector = KarpathyWikiConnector()
        let configuration = KnowledgeConnectorConfiguration(
            kind: .karpathyWiki,
            isEnabled: true,
            rootURL: nil,
            commandPath: nil,
            autoSyncEnabled: false,
            requireReviewBeforeSync: true
        )

        let validation = await connector.validate(configuration: configuration)

        XCTAssertEqual(validation.status, .unavailable)
        XCTAssertEqual(validation.message, "Karpathy Wiki root is not configured.")
    }

    func testSyncWritesPackageUnderRawMeetingsSlug() async throws {
        let fixture = try KarpathyWikiConnectorFixture()
        defer { fixture.cleanup() }
        let configuration = KnowledgeConnectorConfiguration(
            kind: .karpathyWiki,
            isEnabled: true,
            rootURL: fixture.wikiRoot,
            commandPath: nil,
            autoSyncEnabled: false,
            requireReviewBeforeSync: true
        )

        let result = try await KarpathyWikiConnector().sync(package: fixture.package, configuration: configuration)

        XCTAssertEqual(result.connectorID, "karpathy-wiki")
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertTrue(result.destinationDescription.hasSuffix("raw/meetings/2026-04-27-japan-gtm-sync"))
        XCTAssertEqual(result.filesWritten.map(\.lastPathComponent).sorted(), [
            "ingest.md",
            "knowledge.md",
            "meeting.md",
            "transcript.md"
        ])
        let packageURL = fixture.wikiRoot
            .appendingPathComponent("raw", isDirectory: true)
            .appendingPathComponent("meetings", isDirectory: true)
            .appendingPathComponent("2026-04-27-japan-gtm-sync", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: packageURL.appendingPathComponent("meeting.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: packageURL.appendingPathComponent("ingest.md").path))
    }

    func testSyncFailsWhenDestinationAlreadyExists() async throws {
        let fixture = try KarpathyWikiConnectorFixture()
        defer { fixture.cleanup() }
        let packageURL = fixture.wikiRoot
            .appendingPathComponent("raw", isDirectory: true)
            .appendingPathComponent("meetings", isDirectory: true)
            .appendingPathComponent("2026-04-27-japan-gtm-sync", isDirectory: true)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try "existing".write(to: packageURL.appendingPathComponent("meeting.md"), atomically: true, encoding: .utf8)
        let configuration = KnowledgeConnectorConfiguration(
            kind: .karpathyWiki,
            isEnabled: true,
            rootURL: fixture.wikiRoot,
            commandPath: nil,
            autoSyncEnabled: false,
            requireReviewBeforeSync: true
        )

        do {
            _ = try await KarpathyWikiConnector().sync(package: fixture.package, configuration: configuration)
            XCTFail("Expected sync to fail")
        } catch {
            XCTAssertEqual(error as? KnowledgeConnectorError, .destinationAlreadyExists(packageURL.path))
        }
    }
}

private struct KarpathyWikiConnectorFixture {
    let root: URL
    let wikiRoot: URL
    let package: MeetingKnowledgePackage

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("karpathy-wiki-connector-\(UUID().uuidString)", isDirectory: true)
        wikiRoot = root.appendingPathComponent("wiki", isDirectory: true)
        try FileManager.default.createDirectory(at: wikiRoot, withIntermediateDirectories: true)
        let record = MeetingRecord(
            id: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
            name: "Japan GTM Sync",
            startedAt: Date(timeIntervalSince1970: 1_777_000_000),
            endedAt: Date(timeIntervalSince1970: 1_777_000_600),
            audioURL: root.appendingPathComponent("audio.wav"),
            transcriptURL: nil,
            transcriptJSONURL: root.appendingPathComponent("transcript.json"),
            summaryURL: root.appendingPathComponent("summary.md"),
            diagnosticsURL: root.appendingPathComponent("diagnostics.json"),
            transcriptionStatus: .transcribed,
            transcriptionFailureReason: nil,
            speechProvider: .whisper,
            speechLocaleIdentifier: "en-US"
        )
        let segment = TranscriptSegment(
            id: "segment-1",
            speaker: TranscriptSpeaker(identifier: "a", label: "Alice"),
            startTimeSeconds: 12,
            text: "Let's start with Tokyo.",
            timingSource: .precise
        )
        package = MeetingKnowledgePackage(
            record: record,
            summary: nil,
            segments: [segment],
            knowledge: MeetingKnowledge()
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```sh
swift test --filter KarpathyWikiConnectorTests
```

Expected: FAIL because connector types do not exist.

- [ ] **Step 3: Add connector models**

Create `Sources/MeetingAgentCore/KnowledgeConnector.swift`:

```swift
import Foundation

public enum KnowledgeConnectorKind: String, Codable, Equatable {
    case karpathyWiki
    case gbrain
}

public enum KnowledgeConnectorAvailabilityStatus: String, Codable, Equatable {
    case available
    case unavailable
}

public struct KnowledgeConnectorValidation: Codable, Equatable {
    public let status: KnowledgeConnectorAvailabilityStatus
    public let message: String

    public init(status: KnowledgeConnectorAvailabilityStatus, message: String) {
        self.status = status
        self.message = message
    }

    public static func available(_ message: String) -> KnowledgeConnectorValidation {
        KnowledgeConnectorValidation(status: .available, message: message)
    }

    public static func unavailable(_ message: String) -> KnowledgeConnectorValidation {
        KnowledgeConnectorValidation(status: .unavailable, message: message)
    }
}

public struct KnowledgeConnectorConfiguration: Codable, Equatable {
    public let kind: KnowledgeConnectorKind
    public let isEnabled: Bool
    public let rootURL: URL?
    public let commandPath: String?
    public let autoSyncEnabled: Bool
    public let requireReviewBeforeSync: Bool

    public init(
        kind: KnowledgeConnectorKind,
        isEnabled: Bool,
        rootURL: URL?,
        commandPath: String?,
        autoSyncEnabled: Bool,
        requireReviewBeforeSync: Bool
    ) {
        self.kind = kind
        self.isEnabled = isEnabled
        self.rootURL = rootURL
        self.commandPath = commandPath
        self.autoSyncEnabled = autoSyncEnabled
        self.requireReviewBeforeSync = requireReviewBeforeSync
    }
}

public enum KnowledgeSyncStatus: String, Codable, Equatable {
    case succeeded
    case failed
}

public struct KnowledgeSyncResult: Codable, Equatable {
    public let connectorID: String
    public let status: KnowledgeSyncStatus
    public let destinationDescription: String
    public let filesWritten: [URL]
    public let commandOutput: String?
    public let syncedAt: Date

    public init(
        connectorID: String,
        status: KnowledgeSyncStatus,
        destinationDescription: String,
        filesWritten: [URL],
        commandOutput: String?,
        syncedAt: Date
    ) {
        self.connectorID = connectorID
        self.status = status
        self.destinationDescription = destinationDescription
        self.filesWritten = filesWritten
        self.commandOutput = commandOutput
        self.syncedAt = syncedAt
    }
}

public enum KnowledgeConnectorError: Error, Equatable, LocalizedError {
    case missingRoot
    case invalidConnectorKind(KnowledgeConnectorKind)
    case destinationAlreadyExists(String)

    public var errorDescription: String? {
        switch self {
        case .missingRoot:
            return "Karpathy Wiki root is not configured."
        case .invalidConnectorKind(let kind):
            return "Invalid knowledge connector kind: \(kind.rawValue)"
        case .destinationAlreadyExists(let path):
            return "Knowledge destination already exists: \(path)"
        }
    }
}

public protocol KnowledgeConnector {
    var id: String { get }
    var displayName: String { get }

    func validate(configuration: KnowledgeConnectorConfiguration) async -> KnowledgeConnectorValidation
    func sync(package: MeetingKnowledgePackage, configuration: KnowledgeConnectorConfiguration) async throws -> KnowledgeSyncResult
}
```

- [ ] **Step 4: Add Karpathy connector**

Create `Sources/MeetingAgentCore/KarpathyWikiConnector.swift`:

```swift
import Foundation

public struct KarpathyWikiConnector: KnowledgeConnector {
    public let id = "karpathy-wiki"
    public let displayName = "Karpathy Wiki"

    private let fileManager: FileManager
    private let writer: MeetingKnowledgePackageWriter
    private let now: () -> Date

    public init(
        fileManager: FileManager = .default,
        writer: MeetingKnowledgePackageWriter = MeetingKnowledgePackageWriter(),
        now: @escaping () -> Date = Date.init
    ) {
        self.fileManager = fileManager
        self.writer = writer
        self.now = now
    }

    public func validate(configuration: KnowledgeConnectorConfiguration) async -> KnowledgeConnectorValidation {
        guard configuration.kind == .karpathyWiki else {
            return .unavailable("Configuration is not for Karpathy Wiki.")
        }
        guard let rootURL = configuration.rootURL else {
            return .unavailable("Karpathy Wiki root is not configured.")
        }

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            return .unavailable("Karpathy Wiki root is a file.")
        }

        let parent = rootURL.deletingLastPathComponent()
        guard fileManager.isWritableFile(atPath: parent.path) || fileManager.isWritableFile(atPath: rootURL.path) else {
            return .unavailable("Karpathy Wiki root is not writable.")
        }

        return .available("Karpathy Wiki root is available.")
    }

    public func sync(package: MeetingKnowledgePackage, configuration: KnowledgeConnectorConfiguration) async throws -> KnowledgeSyncResult {
        guard configuration.kind == .karpathyWiki else {
            throw KnowledgeConnectorError.invalidConnectorKind(configuration.kind)
        }
        guard let rootURL = configuration.rootURL else {
            throw KnowledgeConnectorError.missingRoot
        }

        let destination = packageURL(for: package, rootURL: rootURL)
        if fileManager.fileExists(atPath: destination.path) {
            throw KnowledgeConnectorError.destinationAlreadyExists(destination.path)
        }

        let result = try writer.write(package, to: destination)
        return KnowledgeSyncResult(
            connectorID: id,
            status: .succeeded,
            destinationDescription: destination.path,
            filesWritten: result.filesWritten,
            commandOutput: nil,
            syncedAt: now()
        )
    }

    public func packageURL(for package: MeetingKnowledgePackage, rootURL: URL) -> URL {
        rootURL
            .appendingPathComponent("raw", isDirectory: true)
            .appendingPathComponent("meetings", isDirectory: true)
            .appendingPathComponent(Self.slug(for: package), isDirectory: true)
    }

    public static func slug(for package: MeetingKnowledgePackage) -> String {
        let date = String(ISO8601DateFormatter().string(from: package.record.startedAt).prefix(10))
        let title = package.summary?.autoGeneratedTitle ?? package.record.name
        let slugTitle = slugify(title)
        if slugTitle.isEmpty {
            return "\(date)-\(package.record.id.uuidString.prefix(8).lowercased())"
        }
        return "\(date)-\(slugTitle)"
    }

    private static func slugify(_ value: String) -> String {
        let lowercased = value.lowercased()
        let allowed = CharacterSet.alphanumerics
        var scalars: [String] = []
        var previousWasDash = false

        for scalar in lowercased.unicodeScalars {
            if allowed.contains(scalar) {
                scalars.append(String(scalar))
                previousWasDash = false
            } else if !previousWasDash {
                scalars.append("-")
                previousWasDash = true
            }
        }

        return scalars
            .joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
```

- [ ] **Step 5: Run connector tests**

Run:

```sh
swift test --filter KarpathyWikiConnectorTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```sh
git add Sources/MeetingAgentCore/KnowledgeConnector.swift Sources/MeetingAgentCore/KarpathyWikiConnector.swift Tests/MeetingAgentCoreTests/KarpathyWikiConnectorTests.swift
git commit -m "feat: add Karpathy wiki connector"
```

---

### Task 3: Add ViewModel Sync Entry Point

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] **Step 1: Add failing ViewModel test**

Add this test to `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift` near the export tests:

```swift
func testSyncKnowledgeToKarpathyWikiWritesPackageAndUpdatesStatus() async throws {
    let fixture = try MeetingAgentViewModelFixture()
    defer { fixture.cleanup() }
    let viewModel = fixture.viewModel
    let stored = try fixture.storeMeeting(
        name: "Japan GTM Sync",
        startedAt: Date(timeIntervalSince1970: 1_777_000_000)
    )
    try fixture.saveCaptionDocument(
        CaptionDocument(turns: [
            CaptionTurn(
                id: "turn-1",
                speaker: TranscriptSpeaker(identifier: "a", label: "Alice"),
                segments: [
                    CaptionSegment(
                        id: "segment-1",
                        text: "Let's start with Tokyo.",
                        startTimeSeconds: 12,
                        endTimeSeconds: 15,
                        isFinal: true
                    )
                ]
            )
        ]),
        for: stored.record
    )
    try viewModel.loadMeetings()
    let wikiRoot = fixture.root.appendingPathComponent("wiki", isDirectory: true)

    let result = try await viewModel.syncKnowledgeToKarpathyWiki(for: stored.record.id, wikiRoot: wikiRoot)

    XCTAssertEqual(result.status, .succeeded)
    XCTAssertEqual(viewModel.statusText, "Knowledge exported to Karpathy Wiki")
    XCTAssertTrue(FileManager.default.fileExists(atPath: wikiRoot
        .appendingPathComponent("raw", isDirectory: true)
        .appendingPathComponent("meetings", isDirectory: true)
        .appendingPathComponent("2026-04-27-japan-gtm-sync", isDirectory: true)
        .appendingPathComponent("ingest.md")
        .path))
}
```

If local fixture helper names differ, use the existing helper methods in the export test section and keep the same assertions.

- [ ] **Step 2: Run test to verify failure**

Run:

```sh
swift test --filter MeetingAgentViewModelTests/testSyncKnowledgeToKarpathyWikiWritesPackageAndUpdatesStatus
```

Expected: FAIL because `syncKnowledgeToKarpathyWiki` does not exist.

- [ ] **Step 3: Add ViewModel method**

In `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`, add this method after `exportKnowledgePackage(for:to:)`:

```swift
public func syncKnowledgeToKarpathyWiki(for meetingID: UUID, wikiRoot: URL) async throws -> KnowledgeSyncResult {
    guard let record = meetings.first(where: { $0.id == meetingID }) else {
        let error = MeetingExportError.missingArtifact("meeting")
        statusText = "Karpathy Wiki export failed: \(Self.errorMessage(error))"
        throw error
    }

    do {
        let session = try sessionState(for: record)
        let document = session.transcript.captionDocument.transcriptDocument
        let summary = session.summary.summary
        let knowledge: MeetingKnowledge
        if let summary {
            knowledge = MeetingKnowledgeExtractor.fromSummary(summary, segments: document.segments)
        } else {
            knowledge = MeetingKnowledge(failureReason: "Knowledge extraction was not available.")
        }
        let package = MeetingKnowledgePackage(
            record: record,
            summary: summary,
            segments: document.segments,
            knowledge: knowledge
        )
        let configuration = KnowledgeConnectorConfiguration(
            kind: .karpathyWiki,
            isEnabled: true,
            rootURL: wikiRoot,
            commandPath: nil,
            autoSyncEnabled: false,
            requireReviewBeforeSync: true
        )
        let result = try await KarpathyWikiConnector().sync(package: package, configuration: configuration)
        statusText = "Knowledge exported to Karpathy Wiki"
        return result
    } catch {
        statusText = "Karpathy Wiki export failed: \(Self.errorMessage(error))"
        throw error
    }
}
```

- [ ] **Step 4: Run ViewModel test**

Run:

```sh
swift test --filter MeetingAgentViewModelTests/testSyncKnowledgeToKarpathyWikiWritesPackageAndUpdatesStatus
```

Expected: PASS.

- [ ] **Step 5: Commit**

```sh
git add Sources/MeetingAgentCore/MeetingAgentViewModel.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift
git commit -m "feat: sync meeting knowledge to Karpathy wiki"
```

---

### Task 4: Add Settings And Meeting UI Wiring

**Files:**
- Modify: `Sources/MeetingAgentApp/SettingsView.swift`
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift`
- Test: `Tests/MeetingAgentCoreTests/SettingsViewLayoutTests.swift`
- Test: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

- [ ] **Step 1: Add failing source-layout tests**

In `Tests/MeetingAgentCoreTests/SettingsViewLayoutTests.swift`, add:

```swift
func testSettingsViewExposesKarpathyWikiDestinationControls() throws {
    let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/MeetingAgentApp/SettingsView.swift")
    let source = try String(contentsOf: sourceURL)

    XCTAssertTrue(source.contains("SettingsCommandCenterPanel(\"Knowledge Destinations\")"))
    XCTAssertTrue(source.contains("Toggle(\"Export to Karpathy Wiki\""))
    XCTAssertTrue(source.contains("TextField(\"Wiki root\""))
    XCTAssertTrue(source.contains("Text(\"GBrain sync is planned\")"))
}
```

In `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`, update `testActionMenuExposesImplementedExportActionsOnly`:

```swift
XCTAssertTrue(source.contains("exportToKarpathyWiki"))
XCTAssertTrue(source.contains("Label(\"Export to Wiki\", systemImage: \"books.vertical\")"))
XCTAssertTrue(source.contains("viewModel.syncKnowledgeToKarpathyWiki(for: meeting.id"))
```

- [ ] **Step 2: Run layout tests to verify failure**

Run:

```sh
swift test --filter SettingsViewLayoutTests/testSettingsViewExposesKarpathyWikiDestinationControls
swift test --filter MainWindowViewLayoutTests/testActionMenuExposesImplementedExportActionsOnly
```

Expected: FAIL because UI controls and action are not wired.

- [ ] **Step 3: Extend SettingsView inputs**

In `Sources/MeetingAgentApp/SettingsView.swift`, add properties:

```swift
    @Binding var karpathyWikiEnabled: Bool
    @Binding var karpathyWikiRootPath: String
```

Update the initializer signature to accept:

```swift
        karpathyWikiEnabled: Binding<Bool>,
        karpathyWikiRootPath: Binding<String>,
```

Inside the initializer body, assign:

```swift
        _karpathyWikiEnabled = karpathyWikiEnabled
        _karpathyWikiRootPath = karpathyWikiRootPath
```

- [ ] **Step 4: Add Settings knowledge panel**

In `SettingsView.body`, insert this panel before `Validation`:

```swift
                SettingsCommandCenterPanel("Knowledge Destinations") {
                    Toggle("Export to Karpathy Wiki", isOn: $karpathyWikiEnabled)
                        .toggleStyle(.checkbox)

                    TextField("Wiki root", text: $karpathyWikiRootPath)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!karpathyWikiEnabled)

                    Text("GBrain sync is planned for a later connector phase.")
                        .commandCenterCaption(CommandCenterPalette.secondaryText)
                }
```

Keep the existing `.disabled(isRecording)` on the whole view.

- [ ] **Step 5: Update SettingsView call site**

In `Sources/MeetingAgentApp/MainWindowView.swift`, find the `SettingsView(` call and pass:

```swift
                    karpathyWikiEnabled: $karpathyWikiEnabled,
                    karpathyWikiRootPath: $karpathyWikiRootPath,
```

Add these properties near the other top-level state in `MainWindowView`:

```swift
    @AppStorage("knowledge.karpathyWikiEnabled") private var karpathyWikiEnabled = false
    @AppStorage("knowledge.karpathyWikiRootPath") private var karpathyWikiRootPath = ""
```

- [ ] **Step 6: Thread Export to Wiki action**

In `MeetingDetailView` parameters, add:

```swift
    let exportToKarpathyWiki: (MeetingRecord) -> Void
```

Pass it through the nested view initializers next to `exportKnowledgePackage`.

At the `MeetingDetailView` call site in `MainWindowView`, add:

```swift
                    exportToKarpathyWiki: { meeting in
                        guard karpathyWikiEnabled,
                              !karpathyWikiRootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        else {
                            NSSound.beep()
                            return
                        }
                        Task {
                            do {
                                let root = URL(fileURLWithPath: karpathyWikiRootPath)
                                _ = try await viewModel.syncKnowledgeToKarpathyWiki(for: meeting.id, wikiRoot: root)
                            } catch {
                                NSSound.beep()
                            }
                        }
                    },
```

In the overflow menu, add this button after "Export Knowledge Package":

```swift
            Button {
                exportToKarpathyWiki()
            } label: {
                Label("Export to Wiki", systemImage: "books.vertical")
            }
            .disabled(isRecording || meeting.transcriptJSONURL == nil)
```

- [ ] **Step 7: Run layout tests**

Run:

```sh
swift test --filter SettingsViewLayoutTests/testSettingsViewExposesKarpathyWikiDestinationControls
swift test --filter MainWindowViewLayoutTests/testActionMenuExposesImplementedExportActionsOnly
```

Expected: PASS.

- [ ] **Step 8: Commit**

```sh
git add Sources/MeetingAgentApp/SettingsView.swift Sources/MeetingAgentApp/MainWindowView.swift Tests/MeetingAgentCoreTests/SettingsViewLayoutTests.swift Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift
git commit -m "feat: expose Karpathy wiki export in app"
```

---

### Task 5: Full Verification

**Files:**
- No code changes unless verification finds a defect.

- [ ] **Step 1: Run focused tests**

Run:

```sh
swift test --filter MeetingKnowledgePackageWriterTests
swift test --filter KarpathyWikiConnectorTests
swift test --filter MeetingExportServiceTests/testExportsKnowledgePackageMarkdownFiles
swift test --filter MeetingAgentViewModelTests/testSyncKnowledgeToKarpathyWikiWritesPackageAndUpdatesStatus
swift test --filter SettingsViewLayoutTests/testSettingsViewExposesKarpathyWikiDestinationControls
swift test --filter MainWindowViewLayoutTests/testActionMenuExposesImplementedExportActionsOnly
```

Expected: all PASS.

- [ ] **Step 2: Run required project test command**

Run:

```sh
make test
```

Expected: all tests pass and coverage gate succeeds.

- [ ] **Step 3: Inspect git status**

Run:

```sh
git status --short
```

Expected: only intentional files are modified, plus any pre-existing unrelated untracked `.env` remains untouched.

- [ ] **Step 4: Final commit if verification fixes were needed**

If Step 1 or Step 2 required fixes, commit those fixes:

```sh
git add Sources/MeetingAgentCore Sources/MeetingAgentApp Tests/MeetingAgentCoreTests
git commit -m "fix: stabilize Karpathy wiki connector"
```

If no fixes were needed, do not create an empty commit.

---

## Self-Review

Spec coverage:

- Canonical package plus `ingest.md`: Task 1.
- Connector abstraction: Task 2.
- Karpathy Wiki file protocol under `raw/meetings`: Task 2.
- ViewModel sync boundary using in-memory session state: Task 3.
- Settings and meeting UX: Task 4.
- Failure isolation and validation: Tasks 2 and 3.
- GBrain phase 1 representation without execution: Task 2 via `KnowledgeConnectorKind.gbrain`.
- Full verification with `make test`: Task 5.

Placeholder scan:

- No steps rely on unspecified code.
- Every code-changing step includes concrete Swift snippets or exact file edits.
- Every test step has a command and expected result.

Type consistency:

- `MeetingKnowledgePackageWriter` returns `MeetingKnowledgePackageWriteResult`.
- `KarpathyWikiConnector` uses `KnowledgeConnectorConfiguration`, `KnowledgeConnectorValidation`, and `KnowledgeSyncResult`.
- `MeetingAgentViewModel.syncKnowledgeToKarpathyWiki` returns `KnowledgeSyncResult`.
