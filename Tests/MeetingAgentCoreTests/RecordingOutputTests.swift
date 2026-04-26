import XCTest
@testable import MeetingAgentCore

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
        XCTAssertEqual(output.transcriptJSONURL.lastPathComponent, "capture.json")
        XCTAssertEqual(output.diagnosticsURL.lastPathComponent, "diagnostics.json")
        XCTAssertEqual(output.wavURL.deletingLastPathComponent(), output.directory)
        XCTAssertEqual(output.transcriptURL.deletingLastPathComponent(), output.directory)
        XCTAssertEqual(output.transcriptJSONURL.deletingLastPathComponent(), output.directory)
        XCTAssertEqual(output.diagnosticsURL.deletingLastPathComponent(), output.directory)
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
        XCTAssertEqual(output.transcriptJSONURL.lastPathComponent, "20260425-132530.json")
        XCTAssertEqual(output.diagnosticsURL.lastPathComponent, "diagnostics.json")
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

    func testSpeechLocaleDefaultsToEnglish() throws {
        let options = try ProbeOptions(arguments: ["--seconds", "5"])

        XCTAssertEqual(options.speechLocaleIdentifier, "en-US")
    }

    func testSpeechLocaleCanBeConfigured() throws {
        let options = try ProbeOptions(arguments: ["--seconds", "5", "--stt-locale", "zh-CN"])

        XCTAssertEqual(options.speechLocaleIdentifier, "zh-CN")
    }

    func testSpeechProviderDefaultsToWhisper() throws {
        let options = try ProbeOptions(arguments: ["--seconds", "5"])

        XCTAssertEqual(options.speechProvider, .whisper)
    }

    func testSpeechProviderCanBeConfiguredToLocal() throws {
        let options = try ProbeOptions(arguments: ["--seconds", "5", "--stt-provider", "local"])

        XCTAssertEqual(options.speechProvider, .local)
    }

    func testSpeechProviderCanBeConfiguredToWhisper() throws {
        let options = try ProbeOptions(arguments: ["--seconds", "5", "--stt-provider", "whisper"])

        XCTAssertEqual(options.speechProvider, .whisper)
    }

    func testProbeOptionsAcceptBilingualTargetAndProfile() throws {
        let options = try ProbeOptions(arguments: [
            "--seconds", "5",
            "--wav",
            "--target-locale", "ja-JP",
            "--bilingual-profile", "local-whisper-local-translation"
        ])

        XCTAssertEqual(options.targetLocaleIdentifier, "ja-JP")
        XCTAssertEqual(options.bilingualPipelineProfileID, "local-whisper-local-translation")
    }

    func testUnknownSpeechProviderIsRejected() {
        XCTAssertThrowsError(try ProbeOptions(arguments: ["--seconds", "5", "--stt-provider", "openai"])) { error in
            XCTAssertEqual(String(describing: error), "Invalid arguments: Unsupported --stt-provider openai. Supported providers: local, whisper")
        }
    }

    func testTranscriptWriterReplacesPartialTextWithLatestText() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("probe-transcript-\(UUID().uuidString).txt")
        let jsonURL = url.deletingPathExtension().appendingPathExtension("json")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: jsonURL)
        }

        let writer = try TranscriptFileWriter(url: url)
        try writer.replace(with: "hello")
        try writer.replace(with: "hello world")
        try writer.close()

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "hello world\n")
        XCTAssertEqual(try TranscriptFileWriter.readDocument(from: jsonURL), TranscriptDocument())
    }

    func testTranscriptWriterPlainTextReplaceClearsStructuredSegments() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("probe-transcript-\(UUID().uuidString).txt")
        let jsonURL = url.deletingPathExtension().appendingPathExtension("json")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: jsonURL)
        }

        let writer = try TranscriptFileWriter(url: url)
        try writer.replace(with: [TranscriptSegment(id: "segment-1", text: "structured text")])
        try writer.replace(with: "Speech recognition unavailable")

        XCTAssertEqual(TranscriptFileWriter.renderedTranscript(textURL: url, structuredURL: jsonURL), "Speech recognition unavailable\n")
        XCTAssertEqual(try TranscriptFileWriter.readDocument(from: jsonURL), TranscriptDocument())
    }

    func testTranscriptWriterRendersTextFromStructuredSegments() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("probe-transcript-\(UUID().uuidString).txt")
        let jsonURL = url.deletingPathExtension().appendingPathExtension("json")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: jsonURL)
        }

        let writer = try TranscriptFileWriter(url: url)
        try writer.replace(with: [
            TranscriptSegment(
                id: "segment-1",
                startTimeSeconds: 0,
                endTimeSeconds: 1.25,
                text: "hello",
                language: "en-US",
                sourceProvider: "whisper",
                isFinal: true,
                confidence: 0.87,
                createdAt: Date(timeIntervalSince1970: 1_777_000_000),
                timingSource: .approximate
            )
        ])
        try writer.close()

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "User A:\nhello\n")
        let document = try TranscriptFileWriter.readDocument(from: jsonURL)
        XCTAssertEqual(document.version, 1)
        XCTAssertEqual(document.segments.first?.id, "segment-1")
        XCTAssertEqual(document.segments.first?.speakerID, "speaker-1")
        XCTAssertEqual(document.segments.first?.speakerLabel, "User A")
        XCTAssertEqual(document.segments.first?.startTimeSeconds, 0)
        XCTAssertEqual(document.segments.first?.endTimeSeconds, 1.25)
        XCTAssertEqual(document.segments.first?.language, "en-US")
        XCTAssertEqual(document.segments.first?.sourceProvider, "whisper")
        XCTAssertEqual(document.segments.first?.isFinal, true)
        XCTAssertEqual(document.segments.first?.confidence, 0.87)
        XCTAssertEqual(document.segments.first?.timingSource, .approximate)
    }

    func testRenderedTranscriptPrefersStructuredSegmentsAndFallsBackToPlainText() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("probe-transcript-\(UUID().uuidString).txt")
        let jsonURL = url.deletingPathExtension().appendingPathExtension("json")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: jsonURL)
        }

        try "legacy text\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(TranscriptFileWriter.renderedTranscript(textURL: url, structuredURL: jsonURL), "legacy text\n")

        let writer = try TranscriptFileWriter(url: url)
        try writer.replace(with: [TranscriptSegment(id: "segment-1", text: "structured text")])

        XCTAssertEqual(TranscriptFileWriter.renderedTranscript(textURL: url, structuredURL: jsonURL), "User A:\nstructured text")
    }
}
