import XCTest

final class TranscriptConsumptionArchitectureTests: XCTestCase {
    func testProductConsumersDoNotReadTranscriptOrSummaryFilesDirectly() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let productFiles = [
            "Sources/MeetingAgentCore/MeetingAgentViewModel.swift",
            "Sources/MeetingAgentCore/MeetingArtifactSnapshot.swift",
            "Sources/MeetingAgentCore/MeetingExportService.swift"
        ]

        for path in productFiles {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertFalse(source.contains("TranscriptFileWriter.readDocument"), path)
            XCTAssertFalse(source.contains("MeetingSummaryWriter.read"), path)
        }

        let exportSource = try String(
            contentsOf: root.appendingPathComponent("Sources/MeetingAgentCore/MeetingExportService.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(exportSource.contains("TranscriptFileWriter.readDocument(from:"), "MeetingExportService.swift")
    }
}
