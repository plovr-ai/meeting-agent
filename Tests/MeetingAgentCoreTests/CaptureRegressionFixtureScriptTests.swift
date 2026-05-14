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
        try Data().write(to: meetingURL.appendingPathComponent("performance-events.jsonl"))

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
        try Data(#"""
        {"sourceSegmentIDs":["turn-1"],"sourceText":"你好。\n我们开始。","translatedText":"Hello. Let's begin.","displayState":"stableFinal","laneID":{"sourceLocale":"zh-CN","targetLocale":"en-US"}}
        """#.utf8).write(to: meetingURL.appendingPathComponent("translation-results.jsonl"))

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
        XCTAssertEqual(expectedUI.displayModes["both"]?.first?.sourceSegmentIDs, ["turn-1"])
        XCTAssertEqual(expectedUI.displayModes["both"]?.first?.sourceText, "你好。\n我们开始。")
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
