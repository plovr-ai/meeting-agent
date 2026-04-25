import XCTest
@testable import CoreAudioTapProbe

final class RecordingOutputTests: XCTestCase {
    func testDefaultRecordingOutputPlacesWavAndTranscriptInRecordDirectory() throws {
        let originalDirectory = FileManager.default.currentDirectoryPath
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("probe-record-output-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(temporaryDirectory.path))
        defer {
            FileManager.default.changeCurrentDirectoryPath(originalDirectory)
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let base = URL(fileURLWithPath: "/tmp/capture.wav")

        let output = try RecordingOutput.defaultOutput(forRequestedWavPath: base.path)

        let expectedDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".record", isDirectory: true)
        XCTAssertEqual(output.directory.path, expectedDirectory.path)
        XCTAssertEqual(output.wavURL.lastPathComponent, "capture.wav")
        XCTAssertEqual(output.transcriptURL.lastPathComponent, "capture.txt")
        XCTAssertEqual(output.wavURL.deletingLastPathComponent(), output.directory)
        XCTAssertEqual(output.transcriptURL.deletingLastPathComponent(), output.directory)
    }

    func testDefaultRecordingOutputUsesTimestampWhenWavPathIsEmpty() throws {
        let originalDirectory = FileManager.default.currentDirectoryPath
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("probe-record-output-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(temporaryDirectory.path))
        defer {
            FileManager.default.changeCurrentDirectoryPath(originalDirectory)
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let timestamp = calendar.date(from: DateComponents(year: 2026, month: 4, day: 25, hour: 13, minute: 25, second: 30))!

        let output = try RecordingOutput.defaultOutput(
            forRequestedWavPath: "",
            timestamp: timestamp,
            timeZone: timeZone
        )

        XCTAssertEqual(output.wavURL.lastPathComponent, "20260425-132530.wav")
        XCTAssertEqual(output.transcriptURL.lastPathComponent, "20260425-132530.txt")
    }

    func testWavFlagWithoutValueEnablesTimestampedRecording() throws {
        let options = try ProbeOptions(arguments: ["--pid", "123", "--seconds", "5", "--wav"])

        XCTAssertEqual(options.pid, 123)
        XCTAssertEqual(options.seconds, 5)
        XCTAssertEqual(options.wavPath, "")
    }

    func testWavFlagBeforeAnotherFlagEnablesTimestampedRecording() throws {
        let options = try ProbeOptions(arguments: ["--pid", "123", "--wav", "--seconds", "5"])

        XCTAssertEqual(options.pid, 123)
        XCTAssertEqual(options.seconds, 5)
        XCTAssertEqual(options.wavPath, "")
    }

    func testTranscriptWriterReplacesPartialTextWithLatestText() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("probe-transcript-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try TranscriptFileWriter(url: url)
        try writer.replace(with: "hello")
        try writer.replace(with: "hello world")
        try writer.close()

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "hello world\n")
    }
}
