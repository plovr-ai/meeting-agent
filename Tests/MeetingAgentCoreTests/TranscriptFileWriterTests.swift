import XCTest
@testable import MeetingAgentCore

final class TranscriptFileWriterTests: XCTestCase {
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

    func testUpdateSpeakerLabelRewritesStructuredAndRenderedTranscript() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("probe-transcript-\(UUID().uuidString).txt")
        let jsonURL = url.deletingPathExtension().appendingPathExtension("json")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: jsonURL)
        }
        let writer = try TranscriptFileWriter(url: url)
        try writer.replace(with: [
            TranscriptSegment(speaker: TranscriptSpeaker(identifier: "speaker-1", label: "User A"), text: "Hello"),
            TranscriptSegment(speaker: TranscriptSpeaker(identifier: "speaker-2", label: "User B"), text: "Hi"),
            TranscriptSegment(speaker: TranscriptSpeaker(identifier: "speaker-1", label: "User A"), text: "Next")
        ])

        try TranscriptFileWriter.updateSpeakerLabel(
            speakerID: "speaker-1",
            label: "Allan",
            textURL: url,
            structuredURL: jsonURL
        )

        let document = try TranscriptFileWriter.readDocument(from: jsonURL)
        XCTAssertEqual(document.segments.map(\.speakerLabel), ["Allan", "User B", "Allan"])
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Allan:\nHello\n\nUser B:\nHi\n\nAllan:\nNext\n")
    }
}
