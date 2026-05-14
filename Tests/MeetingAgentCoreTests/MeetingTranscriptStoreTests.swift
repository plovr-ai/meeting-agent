import XCTest
@testable import MeetingAgentCore

final class MeetingTranscriptStoreTests: XCTestCase {
    func testAppliesSpeechEventsToTranscriptJSONWithoutCreatingTranscriptText() throws {
        let directory = try temporaryDirectory()
        let store = try MeetingTranscriptStore(
            directoryURL: directory,
            provider: CaptionProviderInfo(id: "deepgram", model: "nova-3", locale: "zh-CN")
        )

        let document = try store.apply(.final(payload(id: "utt-1", text: "我们确认负责人。", speakerID: "speaker-0")), forceSnapshot: true)

        XCTAssertEqual(document.version, 2)
        XCTAssertEqual(document.turns.first?.text, "我们确认负责人。")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("transcript.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("transcript-events.jsonl").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("transcript.txt").path))
    }

    func testReplaysEventsWhenTranscriptJSONIsMissing() throws {
        let directory = try temporaryDirectory()
        let first = try MeetingTranscriptStore(directoryURL: directory)
        _ = try first.apply(.final(payload(id: "utt-1", text: "第一句。", speakerID: "speaker-0")), forceSnapshot: true)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("transcript.json"))

        let recovered = try MeetingTranscriptStore(directoryURL: directory)

        XCTAssertEqual(recovered.currentDocument.turns.first?.text, "第一句。")
    }

    func testDraftReplacementPersistsAsSingleTurn() throws {
        let directory = try temporaryDirectory()
        let store = try MeetingTranscriptStore(directoryURL: directory)

        _ = try store.apply(.hypothesis(payload(id: "utt-1", resultID: "r1", text: "A", speakerID: "speaker-0")), forceSnapshot: true)
        let document = try store.apply(.hypothesis(payload(id: "utt-1", resultID: "r2", text: "AB", speakerID: "speaker-0")), forceSnapshot: true)

        XCTAssertEqual(document.turns.count, 1)
        XCTAssertEqual(document.turns.first?.text, "AB")
        let persisted = try MeetingTranscriptStore.readDocument(from: directory.appendingPathComponent("transcript.json"))
        XCTAssertEqual(persisted.turns.count, 1)
        XCTAssertEqual(persisted.turns.first?.text, "AB")
    }

    private func payload(
        id: String,
        resultID: String? = nil,
        text: String,
        speakerID: String
    ) -> SpeechUtterancePayload {
        SpeechUtterancePayload(
            providerID: "deepgram",
            providerResultID: resultID,
            providerUtteranceID: id,
            speaker: TranscriptSpeaker(identifier: speakerID),
            startTimeSeconds: nil,
            endTimeSeconds: nil,
            text: text,
            language: "zh-CN",
            confidence: 0.9,
            boundary: SpeechBoundary(punctuationFinal: SpeechBoundary.detectsPunctuationFinal(in: text))
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingTranscriptStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
