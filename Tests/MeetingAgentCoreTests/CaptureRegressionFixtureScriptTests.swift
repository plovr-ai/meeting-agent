import XCTest
@testable import MeetingAgentCore

final class CaptureRegressionFixtureScriptTests: XCTestCase {
    func testCaptureRegressionFixtureScriptAcceptsCaptionDocumentTranscript() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-regression-fixture-\(UUID().uuidString)", isDirectory: true)
        let meetingURL = root.appendingPathComponent("meeting", isDirectory: true)
        let outputURL = root.appendingPathComponent("fixtures", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: meetingURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        try Data("RIFF fixture".utf8).write(to: meetingURL.appendingPathComponent("audio.wav"))
        try Data(#"{"id":"6C613B9D-16F9-40F2-B7FD-11508D9A41A1","speechLocaleIdentifier":"zh-CN"}"#.utf8)
            .write(to: meetingURL.appendingPathComponent("metadata.json"))
        try Data(#"{"warnings":[]}"#.utf8).write(to: meetingURL.appendingPathComponent("diagnostics.json"))
        try Data().write(to: meetingURL.appendingPathComponent("transcript-events.jsonl"))
        try [
            #"{"event":"recording_started","wallTime":"2026-05-01T00:00:00Z"}"#,
            #"{"event":"deepgram_audio_frame_sent","wallTime":"2026-05-01T00:00:00Z"}"#,
            #"{"event":"caption_turn_visible","wallTime":"2026-05-01T00:00:01Z","audioTime":0.5,"segmentID":"turn-1","isFinal":true,"metadata":{"path":"realtime"}}"#
        ].joined(separator: "\n").appending("\n")
            .write(to: meetingURL.appendingPathComponent("performance-events.jsonl"), atomically: true, encoding: .utf8)

        let captionDocument = CaptionDocument(turns: [
            CaptionTurn(
                id: "turn-1",
                speakerID: "speaker-0",
                speakerLabel: "User A",
                sections: [
                    CaptionSection(id: "section-1", text: "你好。", utteranceIDs: ["utt-1"]),
                    CaptionSection(id: "section-2", text: "我们开始。", utteranceIDs: ["utt-2"])
                ],
                state: .final,
                source: CaptionTurnSource(providerID: "deepgram-transcribe", utteranceIDs: ["utt-1", "utt-2"])
            )
        ])
        try JSONEncoder.meetingAgent.encode(captionDocument)
            .write(to: meetingURL.appendingPathComponent("transcript.json"))

        let result = try runCaptureScript(
            arguments: [
                "--meeting", meetingURL.path,
                "--name", "caption-v2",
                "--scenario", "caption-document-v2",
                "--output", outputURL.path
            ]
        )

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("segments=1"), result.stdout)
        let expectedUIURL = outputURL
            .appendingPathComponent("caption-v2", isDirectory: true)
            .appendingPathComponent("expected-ui.json")
        let expectedUI = try JSONDecoder.meetingAgent.decode(
            RegressionExpectedUI.self,
            from: Data(contentsOf: expectedUIURL)
        )
        XCTAssertEqual(expectedUI.displayModes["captions"]?.first?.sourceSegmentIDs, ["turn-1"])
        XCTAssertEqual(expectedUI.displayModes["captions"]?.first?.primaryText, "你好。\n我们开始。")
    }

    private func runCaptureScript(arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift", "scripts/capture-regression-fixture.swift"] + arguments
        process.currentDirectoryURL = RegressionFixtureFiles.repositoryRoot

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        return (
            process.terminationStatus,
            String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }
}
