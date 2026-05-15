import XCTest

final class TranscriptConsumptionArchitectureTests: XCTestCase {
    func testProductConsumersDoNotReadTranscriptOrSummaryFilesDirectly() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let productFiles = [
            "Sources/MeetingAgentCore/MeetingArtifactSnapshot.swift",
            "Sources/MeetingAgentCore/MeetingExportService.swift"
        ]

        for path in productFiles {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertFalse(source.contains("LegacyTranscriptBridge.readDocument"), path)
            XCTAssertFalse(source.contains("MeetingSummaryWriter.read"), path)
            XCTAssertFalse(source.contains("FileTranscriptRepository()"), path)
            XCTAssertFalse(source.contains("FileSummaryRepository()"), path)
            XCTAssertFalse(source.contains("loadCaptionDocument(for:"), path)
            XCTAssertFalse(source.contains("loadSummary(for:"), path)
        }

        let exportSource = try String(
            contentsOf: root.appendingPathComponent("Sources/MeetingAgentCore/MeetingExportService.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(exportSource.contains("LegacyTranscriptBridge.readDocument(from:"), "MeetingExportService.swift")
        XCTAssertFalse(exportSource.contains("TranscriptRepository"), "MeetingExportService.swift")
        XCTAssertFalse(exportSource.contains("SummaryRepository"), "MeetingExportService.swift")

        let viewModelSource = try String(
            contentsOf: root.appendingPathComponent("Sources/MeetingAgentCore/MeetingAgentViewModel.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(viewModelSource.contains("exportService.exportTranscript(for: record, to:"), "MeetingAgentViewModel.swift")
        XCTAssertFalse(viewModelSource.contains("exportService.exportSummary(for: record, to:"), "MeetingAgentViewModel.swift")
        XCTAssertFalse(viewModelSource.contains("exportService.exportSubtitles(for: record, format:"), "MeetingAgentViewModel.swift")
        XCTAssertFalse(viewModelSource.contains("exportService.exportKnowledgePackage(for: record, summary:"), "MeetingAgentViewModel.swift")
        XCTAssertFalse(viewModelSource.contains("exportService.summaryText(for: record)"), "MeetingAgentViewModel.swift")
    }

    func testRepositoryConsumptionIsLimitedToHydrationBoundaries() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let allowedFiles: Set<String> = [
            "Sources/MeetingAgentCore/MeetingDataRepositories.swift",
            "Sources/MeetingAgentCore/MeetingStore.swift",
            "Sources/MeetingAgentCore/MeetingAgentViewModel.swift"
        ]
        let sourceRoot = root.appendingPathComponent("Sources/MeetingAgentCore", isDirectory: true)
        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: sourceRoot,
            includingPropertiesForKeys: nil
        )
        for fileURL in fileURLs where fileURL.pathExtension == "swift" {
            let relativePath = "Sources/MeetingAgentCore/\(fileURL.lastPathComponent)"
            guard !allowedFiles.contains(relativePath) else { continue }
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            XCTAssertFalse(source.contains("FileTranscriptRepository"), relativePath)
            XCTAssertFalse(source.contains("FileSummaryRepository"), relativePath)
            XCTAssertFalse(source.contains("loadCaptionDocument(for:"), relativePath)
            XCTAssertFalse(source.contains("loadSummary(for:"), relativePath)
        }
    }

    func testRealtimeRecordingPersistenceDoesNotUseLegacyTranscriptFileBridge() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let realtimeFiles = [
            "Sources/MeetingAgentCore/RecordingTranscriptPersistenceStore.swift",
            "Sources/MeetingAgentCore/MeetingRecorder.swift"
        ]

        for path in realtimeFiles {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertFalse(source.contains("LegacyTranscriptBridge"), path)
            XCTAssertFalse(source.contains("LegacyTranscriptUpdateFileSink"), path)
            XCTAssertFalse(source.contains("transcript.txt"), path)
        }
    }

    func testSourceGrepKeepsLegacyTranscriptWriterArchitectureOutOfProviderPaths() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceRoot = root.appendingPathComponent("Sources", isDirectory: true)
        let forbiddenTerms = [
            "TranscriptFileWriter",
            "FileBackedTranscriptUpdateSink",
            "provider-transcript.legacy"
        ]
        let allowedTranscriptTextFiles: Set<String> = [
            "Sources/MeetingAgentApp/MainWindowView.swift",
            "Sources/MeetingAgentCore/BilingualTranscriptStore.swift"
        ]

        let enumerator = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: nil
        )
        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.pathExtension == "swift" else { continue }
            let relativePath = fileURL.path.replacingOccurrences(of: root.path + "/", with: "")
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            for term in forbiddenTerms {
                XCTAssertFalse(source.contains(term), "\(relativePath) contains \(term)")
            }
            if !allowedTranscriptTextFiles.contains(relativePath) {
                XCTAssertFalse(source.contains("transcript.txt"), "\(relativePath) contains transcript.txt")
            }
            XCTAssertFalse(source.contains("renderedTranscript"), "\(relativePath) contains renderedTranscript")
        }
    }
}
