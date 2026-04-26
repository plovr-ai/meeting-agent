import XCTest
@testable import MeetingAgentCore

final class BilingualTranscriptStoreTests: XCTestCase {
    func testWritesJSONAndTextArtifacts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = BilingualTranscriptStore(directoryURL: directory)
        let transcript = BilingualTranscript(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            segments: [
                BilingualSubtitleSegment(id: "segment-1", sourceText: "hello", targetText: "你好")
            ],
            provenance: PipelineProvenance(profileID: "profile")
        )

        let artifacts = try store.save(transcript)

        XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts.jsonURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts.textURL.path))
        XCTAssertEqual(try String(contentsOf: artifacts.textURL, encoding: .utf8), """
        User A:
        Source: hello
        Target: 你好
        """)
    }
}
