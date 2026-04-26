import XCTest

final class MainWindowViewLayoutTests: XCTestCase {
    func testRecordingAndRetryButtonsShareActionRow() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MeetingAgentApp/MainWindowView.swift")
        let source = try String(contentsOf: sourceURL)

        guard let stopRange = source.range(of: "Button(\"Stop Recording\")") else {
            return XCTFail("Stop Recording button is missing")
        }
        guard let retryRange = source.range(of: "Button(\"Retry Transcription\")") else {
            return XCTFail("Retry Transcription button is missing")
        }
        XCTAssertLessThan(stopRange.lowerBound, retryRange.lowerBound)

        let precedingSource = source[..<stopRange.lowerBound]
        guard let actionRowStart = precedingSource.range(of: "HStack", options: .backwards) else {
            return XCTFail("Recording action row is missing")
        }

        let actionRow = source[actionRowStart.lowerBound..<retryRange.upperBound]
        XCTAssertTrue(actionRow.contains("Button(\"Stop Recording\")"))
        XCTAssertTrue(actionRow.contains("Button(\"Retry Transcription\")"))
    }

    func testSummaryDownloadAndRegenerateControlsAreRemoved() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MeetingAgentApp/MainWindowView.swift")
        let source = try String(contentsOf: sourceURL)

        XCTAssertFalse(source.contains("Label(\"Summary\", systemImage: \"text.badge.checkmark\")"))
        XCTAssertFalse(source.contains("Button(\"Regenerate Summary\")"))
    }
}
