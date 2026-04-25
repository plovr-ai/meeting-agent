import XCTest
@testable import MeetingAgentCore

final class TranscriptionFailureIsolatorTests: XCTestCase {
    func testAppendFailureWritesTranscriptFailureAndDisablesTranscriber() throws {
        let transcriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("probe-transcript-\(UUID().uuidString).txt")
        let transcriptJSONURL = transcriptURL.deletingPathExtension().appendingPathExtension("json")
        defer {
            try? FileManager.default.removeItem(at: transcriptURL)
            try? FileManager.default.removeItem(at: transcriptJSONURL)
        }
        try TranscriptFileWriter(url: transcriptURL).replace(with: [
            TranscriptSegment(id: "stale", text: "stale structured text")
        ])
        let transcriber = FailingAppendTranscriber()
        let isolator = TranscriptionFailureIsolator(
            transcriber: transcriber,
            transcriptURL: transcriptURL
        )
        let frame = AudioFrame(
            pcm: Data([0x01, 0x00]),
            sampleRate: 16_000,
            channelCount: 1,
            timestampNanos: 1
        )

        try isolator.append(frame)
        try isolator.append(frame)

        XCTAssertFalse(isolator.isActive)
        XCTAssertEqual(transcriber.appendCount, 1)
        XCTAssertEqual(transcriber.finishCount, 1)
        XCTAssertEqual(
            try String(contentsOf: transcriptURL, encoding: .utf8),
            "Speech recognition failed: Speech recognition error: chunk failed\n"
        )
        XCTAssertEqual(try TranscriptFileWriter.readDocument(from: transcriptJSONURL), TranscriptDocument())
    }
}

private final class FailingAppendTranscriber: AudioFrameTranscriber {
    private(set) var appendCount = 0
    private(set) var finishCount = 0

    func append(_ frame: AudioFrame) throws {
        appendCount += 1
        throw ProbeError.speechRecognition("chunk failed")
    }

    func finish() {
        finishCount += 1
    }
}
