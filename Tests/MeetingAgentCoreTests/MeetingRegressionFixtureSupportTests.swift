import XCTest
@testable import MeetingAgentCore

final class MeetingRegressionFixtureSupportTests: XCTestCase {
    func testManifestDecodesKnownFailureScenario() throws {
        let data = Data(#"""
        {
          "id": "microsoft-teams-public-preview-en-zh",
          "sourceMeetingID": "D5C47AEC-4E86-4C66-9B61-FEE3D151006C",
          "scenario": "single-speaker-long-no-speech-final",
          "sourceLocale": "en-US",
          "targetLocale": "zh-CN",
          "purpose": "knownFailure",
          "expectedAnalyzerStatus": "fail",
          "expectedFailures": []
        }
        """#.utf8)

        let manifest = try JSONDecoder.meetingAgent.decode(RegressionFixtureManifest.self, from: data)

        XCTAssertEqual(manifest.id, "microsoft-teams-public-preview-en-zh")
        XCTAssertEqual(manifest.scenario, "single-speaker-long-no-speech-final")
        XCTAssertEqual(manifest.purpose, .knownFailure)
        XCTAssertEqual(manifest.expectedAnalyzerStatus, .fail)
        XCTAssertEqual(manifest.expectedFailures, [])
    }

    func testExpectedUIDecodesDisplayModeRows() throws {
        let data = Data(#"""
        {
          "displayModes": {
            "both": [
              {
                "sourceSegmentIDs": ["segment-1", "segment-2"],
                "primaryText": "source",
                "sourceText": "source",
                "isFinal": true
              }
            ],
            "captions": [
              {
                "sourceSegmentIDs": ["segment-1", "segment-2"],
                "primaryText": "source"
              }
            ]
          }
        }
        """#.utf8)

        let expected = try JSONDecoder.meetingAgent.decode(RegressionExpectedUI.self, from: data)

        XCTAssertEqual(expected.displayModes["both"]?.first?.sourceSegmentIDs, ["segment-1", "segment-2"])
        XCTAssertEqual(expected.displayModes["both"]?.first?.primaryText, "source")
        XCTAssertEqual(expected.displayModes["both"]?.first?.sourceText, "source")
        XCTAssertEqual(expected.displayModes["captions"]?.first?.primaryText, "source")
    }

    func testLoadTranscriptProjectsCaptionDocumentFixtures() throws {
        let fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("caption-regression-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let captionDocument = CaptionDocument(turns: [
            CaptionTurn(
                id: "turn-1",
                speakerID: "speaker-0",
                speakerLabel: "User A",
                sections: [
                    CaptionSection(id: "section-1", text: "第一句。", utteranceIDs: ["utt-1"]),
                    CaptionSection(id: "section-2", text: "第二句。", utteranceIDs: ["utt-2"])
                ],
                state: .final,
                source: CaptionTurnSource(providerID: "deepgram-transcribe", utteranceIDs: ["utt-1", "utt-2"])
            )
        ])
        try JSONEncoder.meetingAgent.encode(captionDocument)
            .write(to: fixtureURL.appendingPathComponent("transcript.json"))

        let transcript = try RegressionFixtureFiles.loadTranscript(in: fixtureURL)

        XCTAssertEqual(transcript.version, 2)
        XCTAssertEqual(transcript.segments.map(\.id), ["turn-1"])
        XCTAssertEqual(transcript.segments.first?.text, "第一句。\n第二句。")
        XCTAssertEqual(transcript.segments.first?.speakerID, "speaker-0")
    }
}
