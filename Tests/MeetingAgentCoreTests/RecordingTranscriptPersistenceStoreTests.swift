import XCTest
@testable import MeetingAgentCore

final class RecordingTranscriptPersistenceStoreTests: XCTestCase {
    func testUpsertAppendsEventWithoutImmediateTextSnapshot() throws {
        let fixture = try StoreFixture()
        let store = try RecordingTranscriptPersistenceStore(
            transcriptURL: fixture.transcriptURL,
            snapshotInterval: 10,
            now: fixture.now
        )

        try store.apply(.upsert(TranscriptSegment(id: "segment-1", text: "hello", isFinal: false)))

        XCTAssertEqual(store.currentDocument.segments.map(\.id), ["segment-1"])
        XCTAssertEqual(try String(contentsOf: fixture.transcriptURL, encoding: .utf8), "")
        XCTAssertEqual(try TranscriptFileWriter.readDocument(from: fixture.structuredURL), TranscriptDocument())
        XCTAssertEqual(try fixture.eventLogLineCount(), 1)
    }

    func testDebouncedSnapshotWritesCompleteArtifacts() throws {
        let fixture = try StoreFixture()
        let store = try RecordingTranscriptPersistenceStore(
            transcriptURL: fixture.transcriptURL,
            snapshotInterval: 2,
            now: fixture.now
        )

        try store.apply(.upsert(TranscriptSegment(id: "segment-1", text: "hello", isFinal: true)))
        fixture.currentDate = Date(timeIntervalSince1970: 3)
        try store.apply(.upsert(TranscriptSegment(id: "segment-2", text: "world", isFinal: true)))

        let document = try TranscriptFileWriter.readDocument(from: fixture.structuredURL)
        XCTAssertEqual(document.segments.map(\.id), ["segment-1", "segment-2"])
        XCTAssertEqual(try String(contentsOf: fixture.transcriptURL, encoding: .utf8), "User A:\nhello world\n")
    }

    func testSnapshotWritesCaptionDocumentForRepositoryHydration() throws {
        let fixture = try StoreFixture()
        let store = try RecordingTranscriptPersistenceStore(
            transcriptURL: fixture.transcriptURL,
            snapshotInterval: 10,
            now: fixture.now
        )

        try store.apply(.upsert(TranscriptSegment(
            id: "segment-1",
            speaker: TranscriptSpeaker(identifier: "speaker-0", label: "Alice"),
            startTimeSeconds: 1,
            endTimeSeconds: 2,
            text: "hello",
            language: "en-US",
            sourceProvider: "whisper",
            isFinal: true,
            createdAt: Date(timeIntervalSince1970: 1_777_000_000),
            timingSource: .precise
        )), forceSnapshot: true)

        let document = try FileTranscriptRepository().loadCaptionDocument(for: fixture.record)

        XCTAssertEqual(document.turns.map(\.id), ["segment-1"])
        XCTAssertEqual(document.turns.first?.speakerID, "speaker-0")
        XCTAssertEqual(document.turns.first?.speakerLabel, "Alice")
        XCTAssertEqual(document.turns.first?.text, "hello")
        XCTAssertEqual(document.turns.first?.state, .final)
        XCTAssertEqual(document.turns.first?.source.providerID, "whisper")
    }

    func testDraftTranslationPatchDoesNotSnapshotBeforeDebounce() throws {
        let fixture = try StoreFixture()
        let store = try RecordingTranscriptPersistenceStore(
            transcriptURL: fixture.transcriptURL,
            snapshotInterval: 10,
            now: fixture.now
        )

        try store.apply(.upsert(TranscriptSegment(id: "segment-1", text: "Confirm owner.", isFinal: true)))
        try store.apply(.translationPatch(
            segmentID: "segment-1",
            text: "确认负责人。",
            targetLocale: "zh-CN",
            isFinal: false
        ))

        XCTAssertEqual(store.currentDocument.segments.first?.translatedText, "确认负责人。")
        XCTAssertEqual(try String(contentsOf: fixture.transcriptURL, encoding: .utf8), "")
        XCTAssertEqual(try fixture.eventLogLineCount(), 2)
    }

    func testFinalTranslationPatchForcesSnapshot() throws {
        let fixture = try StoreFixture()
        let store = try RecordingTranscriptPersistenceStore(
            transcriptURL: fixture.transcriptURL,
            snapshotInterval: 10,
            now: fixture.now
        )

        try store.apply(.upsert(TranscriptSegment(id: "segment-1", text: "Confirm owner.", isFinal: true)))
        try store.apply(.translationPatch(
            segmentID: "segment-1",
            text: "确认负责人。",
            targetLocale: "zh-CN",
            isFinal: true
        ))

        let document = try TranscriptFileWriter.readDocument(from: fixture.structuredURL)
        XCTAssertEqual(document.segments.first?.translatedText, "确认负责人。")
        XCTAssertEqual(document.segments.first?.translationIsFinal, true)
        let captionDocument = try FileTranscriptRepository().loadCaptionDocument(for: fixture.record)
        XCTAssertEqual(captionDocument.turns.first?.translatedText, "确认负责人。")
        XCTAssertEqual(captionDocument.turns.first?.translationTargetLocale, "zh-CN")
        XCTAssertEqual(captionDocument.turns.first?.translationIsFinal, true)
        XCTAssertEqual(try String(contentsOf: fixture.transcriptURL, encoding: .utf8), "User A:\nConfirm owner.\n")
        XCTAssertEqual(try fixture.eventLogLineCount(), 2)
    }

    func testCloseFlushesFinalSnapshot() throws {
        let fixture = try StoreFixture()
        let store = try RecordingTranscriptPersistenceStore(
            transcriptURL: fixture.transcriptURL,
            snapshotInterval: 10,
            now: fixture.now
        )

        try store.apply(.upsert(TranscriptSegment(id: "segment-1", text: "hello", isFinal: true)))
        try store.close()

        XCTAssertEqual(try String(contentsOf: fixture.transcriptURL, encoding: .utf8), "User A:\nhello\n")
        XCTAssertEqual(
            try TranscriptFileWriter.readDocument(from: fixture.structuredURL).segments.map(\.id),
            ["segment-1"]
        )
    }

    func testRecoversFromSnapshotPlusEventLog() throws {
        let fixture = try StoreFixture()
        try TranscriptFileWriter(url: fixture.transcriptURL).replace(with: [
            TranscriptSegment(id: "snapshot-segment", text: "from snapshot", isFinal: true)
        ])
        var currentDate = Date(timeIntervalSince1970: 0)
        let firstStore = try RecordingTranscriptPersistenceStore(
            transcriptURL: fixture.transcriptURL,
            snapshotInterval: 10,
            now: { currentDate }
        )
        try firstStore.apply(.upsert(TranscriptSegment(id: "event-segment", text: "from event", isFinal: true)))

        currentDate = Date(timeIntervalSince1970: 1)
        let recovered = try RecordingTranscriptPersistenceStore(
            transcriptURL: fixture.transcriptURL,
            snapshotInterval: 10,
            now: { currentDate }
        )

        XCTAssertEqual(recovered.currentDocument.segments.map(\.id), ["snapshot-segment", "event-segment"])
        try recovered.flushSnapshot()
        XCTAssertEqual(
            try TranscriptFileWriter.readDocument(from: fixture.structuredURL).segments.map(\.id),
            ["snapshot-segment", "event-segment"]
        )
    }

    func testReplaceWithPlainTextForcesSnapshotAndClearsStructuredDocument() throws {
        let fixture = try StoreFixture()
        let store = try RecordingTranscriptPersistenceStore(
            transcriptURL: fixture.transcriptURL,
            snapshotInterval: 10,
            now: fixture.now
        )

        try store.apply(.upsert(TranscriptSegment(id: "segment-1", text: "hello", isFinal: true)))
        try store.apply(.replaceWithPlainText("Speech recognition unavailable"))

        XCTAssertEqual(try String(contentsOf: fixture.transcriptURL, encoding: .utf8), "Speech recognition unavailable\n")
        XCTAssertTrue(try TranscriptFileWriter.readDocument(from: fixture.structuredURL).segments.isEmpty)
        XCTAssertTrue(try FileTranscriptRepository().loadCaptionDocument(for: fixture.record).turns.isEmpty)
    }

    func testReplaceAllForcesSnapshotAndCanBeReplayed() throws {
        let fixture = try StoreFixture()
        let store = try RecordingTranscriptPersistenceStore(
            transcriptURL: fixture.transcriptURL,
            snapshotInterval: 10,
            now: fixture.now
        )

        try store.apply(.replaceAll([
            TranscriptSegment(id: "segment-1", text: "first", isFinal: true),
            TranscriptSegment(id: "segment-2", text: "second", isFinal: true)
        ]))

        XCTAssertEqual(try String(contentsOf: fixture.transcriptURL, encoding: .utf8), "User A:\nfirst second\n")
        let recovered = try RecordingTranscriptPersistenceStore(
            transcriptURL: fixture.transcriptURL,
            snapshotInterval: 10,
            now: fixture.now
        )
        XCTAssertEqual(recovered.currentDocument.segments.map(\.id), ["segment-1", "segment-2"])
    }

    func testRecoveryReplaysTranslationPatchAndPlainTextReplacement() throws {
        let fixture = try StoreFixture()
        let store = try RecordingTranscriptPersistenceStore(
            transcriptURL: fixture.transcriptURL,
            snapshotInterval: 10,
            now: fixture.now
        )

        try store.apply(.upsert(TranscriptSegment(id: "segment-1", text: "Confirm owner.", isFinal: true)))
        try store.apply(.translationPatch(
            segmentID: "segment-1",
            text: "确认负责人。",
            targetLocale: "zh-CN",
            isFinal: true
        ))
        let recoveredTranslation = try RecordingTranscriptPersistenceStore(
            transcriptURL: fixture.transcriptURL,
            snapshotInterval: 10,
            now: fixture.now
        )

        XCTAssertEqual(recoveredTranslation.currentDocument.segments.first?.translatedText, "确认负责人。")

        try store.apply(.replaceWithPlainText("Speech recognition unavailable"))
        let recoveredPlainText = try RecordingTranscriptPersistenceStore(
            transcriptURL: fixture.transcriptURL,
            snapshotInterval: 10,
            now: fixture.now
        )
        try recoveredPlainText.flushSnapshot()

        XCTAssertTrue(recoveredPlainText.currentDocument.segments.isEmpty)
        XCTAssertEqual(try String(contentsOf: fixture.transcriptURL, encoding: .utf8), "Speech recognition unavailable\n")
        XCTAssertTrue(try FileTranscriptRepository().loadCaptionDocument(for: fixture.record).turns.isEmpty)
    }

    func testTranslationPatchRejectsBlankInputs() throws {
        let fixture = try StoreFixture()
        let store = try RecordingTranscriptPersistenceStore(
            transcriptURL: fixture.transcriptURL,
            snapshotInterval: 10,
            now: fixture.now
        )
        try store.apply(.upsert(TranscriptSegment(id: "segment-1", text: "Confirm owner.", isFinal: true)))

        XCTAssertThrowsError(try store.apply(.translationPatch(
            segmentID: " ",
            text: "确认负责人。",
            targetLocale: "zh-CN",
            isFinal: true
        )))
        XCTAssertThrowsError(try store.apply(.translationPatch(
            segmentID: "segment-1",
            text: " ",
            targetLocale: "zh-CN",
            isFinal: true
        )))
        XCTAssertThrowsError(try store.apply(.translationPatch(
            segmentID: "segment-1",
            text: "确认负责人。",
            targetLocale: " ",
            isFinal: true
        )))
    }

    func testMalformedEventLogFailsRecovery() throws {
        let fixture = try StoreFixture()
        try #"{"type":"upsert"}"#.write(to: fixture.eventLogURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try RecordingTranscriptPersistenceStore(
            transcriptURL: fixture.transcriptURL,
            snapshotInterval: 10,
            now: fixture.now
        ))
    }
}

private final class StoreFixture {
    let directory: URL
    let transcriptURL: URL
    let structuredURL: URL
    let eventLogURL: URL
    let record: MeetingRecord
    var currentDate = Date(timeIntervalSince1970: 0)

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "recording-transcript-store-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        transcriptURL = directory.appendingPathComponent("transcript.txt")
        structuredURL = directory.appendingPathComponent("transcript.json")
        eventLogURL = directory.appendingPathComponent("transcript-events.jsonl")
        record = MeetingRecord(
            id: UUID(),
            name: "Fixture",
            startedAt: currentDate,
            endedAt: nil,
            audioURL: directory.appendingPathComponent("audio.wav"),
            transcriptURL: transcriptURL,
            transcriptJSONURL: structuredURL
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func now() -> Date {
        currentDate
    }

    func eventLogLineCount() throws -> Int {
        let contents = try String(contentsOf: eventLogURL, encoding: .utf8)
        return contents.split(whereSeparator: \.isNewline).count
    }
}
