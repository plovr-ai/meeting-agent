import XCTest
@testable import MeetingAgentCore

final class PostMeetingTranscriptRefinementServiceTests: XCTestCase {
    func testSuccessfulRefinementPersistsSpeakerSeparatedCaptionDocument() async throws {
        let fixture = try RefinementFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let audioURL = try XCTUnwrap(fixture.record.audioURL)
        FileManager.default.createFile(atPath: audioURL.path, contents: Data([0x52, 0x49, 0x46, 0x46]))
        fixture.provider.document = TranscriptDocument(segments: [
            TranscriptSegment(
                id: "utt-1",
                speaker: TranscriptSpeaker(identifier: "deepgram-speaker-0"),
                startTimeSeconds: 0.1,
                endTimeSeconds: 1.2,
                text: "We decided to launch.",
                language: "en-US",
                sourceProvider: "deepgram-transcribe"
            ),
            TranscriptSegment(
                id: "utt-2",
                speaker: TranscriptSpeaker(identifier: "deepgram-speaker-1"),
                startTimeSeconds: 1.3,
                endTimeSeconds: 2.4,
                text: "I will follow up.",
                language: "en-US",
                sourceProvider: "deepgram-transcribe"
            )
        ])

        let result = await fixture.service.refineTranscript(
            for: fixture.record,
            liveDocument: liveDocument(),
            configuration: fixture.configuration
        )

        let document = try XCTUnwrap(result.captionDocument)
        XCTAssertEqual(document.provider?.id, "deepgram-batch-transcribe")
        XCTAssertEqual(document.provider?.model, "nova-3")
        XCTAssertEqual(document.turns.map(\.text), ["We decided to launch.", "I will follow up."])
        XCTAssertEqual(document.turns.map(\.speakerID), ["deepgram-speaker-0", "deepgram-speaker-1"])
        XCTAssertEqual(document.turns.map(\.speakerLabel), ["Speaker 1", "Speaker 2"])
        XCTAssertEqual(document.turns.map(\.source.providerID), ["deepgram-batch-transcribe", "deepgram-batch-transcribe"])
        XCTAssertEqual(result.record.transcriptRefinement?.status, .refined)
        XCTAssertEqual(result.record.transcriptRefinement?.providerID, "deepgram-batch-transcribe")

        let persisted = try FileTranscriptRepository().loadCaptionDocument(for: fixture.record)
        XCTAssertEqual(persisted.provider, document.provider)
        XCTAssertEqual(persisted.turns.map(\.id), ["utt-1", "utt-2"])
        XCTAssertEqual(persisted.turns.map(\.text), ["We decided to launch.", "I will follow up."])
    }

    func testProviderFailurePreservesLiveTranscript() async throws {
        let fixture = try RefinementFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let audioURL = try XCTUnwrap(fixture.record.audioURL)
        FileManager.default.createFile(atPath: audioURL.path, contents: Data([0x52, 0x49, 0x46, 0x46]))
        let live = liveDocument()
        try FileTranscriptRepository().saveCaptionDocument(live, for: fixture.record)
        fixture.provider.error = ProbeError.speechRecognition("provider exploded")

        let result = await fixture.service.refineTranscript(
            for: fixture.record,
            liveDocument: live,
            configuration: fixture.configuration
        )

        XCTAssertNil(result.captionDocument)
        XCTAssertEqual(result.record.transcriptRefinement?.status, .failed)
        XCTAssertTrue(result.record.transcriptRefinement?.failureReason?.contains("provider exploded") == true)
        XCTAssertEqual(try FileTranscriptRepository().loadCaptionDocument(for: fixture.record).turns.map(\.text), live.turns.map(\.text))
    }

    func testMissingAudioPreservesLiveTranscript() async throws {
        let fixture = try RefinementFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let live = liveDocument()
        try FileTranscriptRepository().saveCaptionDocument(live, for: fixture.record)

        let result = await fixture.service.refineTranscript(
            for: fixture.record,
            liveDocument: live,
            configuration: fixture.configuration
        )

        XCTAssertNil(result.captionDocument)
        XCTAssertEqual(result.record.transcriptRefinement?.status, .failed)
        XCTAssertEqual(result.record.transcriptRefinement?.failureReason, "Saved audio is not readable for transcript refinement")
        XCTAssertEqual(try FileTranscriptRepository().loadCaptionDocument(for: fixture.record).turns.map(\.text), live.turns.map(\.text))
    }

    func testRecordWithoutAudioURLPreservesLiveTranscript() async throws {
        let fixture = try RefinementFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var record = fixture.record
        record.audioURL = nil

        let result = await fixture.service.refineTranscript(
            for: record,
            liveDocument: liveDocument(),
            configuration: fixture.configuration
        )

        XCTAssertNil(result.captionDocument)
        XCTAssertEqual(result.record.transcriptRefinement?.status, .failed)
        XCTAssertEqual(result.record.transcriptRefinement?.failureReason, "No saved audio is available for transcript refinement")
        XCTAssertTrue(fixture.provider.requests.isEmpty)
    }

    func testUnsupportedBatchProviderPreservesLiveTranscript() async throws {
        let fixture = try RefinementFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var configuration = fixture.configuration
        configuration.batchTranscriptionProviderID = "future-batch-provider"

        let result = await fixture.service.refineTranscript(
            for: fixture.record,
            liveDocument: liveDocument(),
            configuration: configuration
        )

        XCTAssertNil(result.captionDocument)
        XCTAssertEqual(result.record.transcriptRefinement?.status, .failed)
        XCTAssertEqual(result.record.transcriptRefinement?.providerID, "future-batch-provider")
        XCTAssertEqual(result.record.transcriptRefinement?.failureReason, "Batch transcript provider is not supported")
        XCTAssertTrue(fixture.provider.requests.isEmpty)
    }

    func testEmptyBatchResultPreservesLiveTranscript() async throws {
        let fixture = try RefinementFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let audioURL = try XCTUnwrap(fixture.record.audioURL)
        FileManager.default.createFile(atPath: audioURL.path, contents: Data([0x52, 0x49, 0x46, 0x46]))
        let live = liveDocument()
        try FileTranscriptRepository().saveCaptionDocument(live, for: fixture.record)
        fixture.provider.document = TranscriptDocument(segments: [
            TranscriptSegment(id: "blank", text: "   ", sourceProvider: "deepgram-transcribe")
        ])

        let result = await fixture.service.refineTranscript(
            for: fixture.record,
            liveDocument: live,
            configuration: fixture.configuration
        )

        XCTAssertNil(result.captionDocument)
        XCTAssertEqual(result.record.transcriptRefinement?.status, .failed)
        XCTAssertEqual(result.record.transcriptRefinement?.failureReason, "Batch transcript refinement returned no usable transcript")
        XCTAssertEqual(try FileTranscriptRepository().loadCaptionDocument(for: fixture.record).turns.map(\.text), live.turns.map(\.text))
    }

    func testCaptionDocumentPreservesExplicitAndRepeatedSpeakerLabels() {
        let createdAt = Date(timeIntervalSince1970: 10)
        let updatedAt = Date(timeIntervalSince1970: 20)

        let document = PostMeetingTranscriptRefinementService.captionDocument(
            from: [
                TranscriptSegment(
                    id: "utt-1",
                    speaker: TranscriptSpeaker(identifier: "speaker-a", label: "Alice"),
                    text: "First turn.",
                    language: nil
                ),
                TranscriptSegment(
                    id: "utt-2",
                    speaker: TranscriptSpeaker(identifier: "speaker-a"),
                    text: "Second turn.",
                    language: nil
                ),
                TranscriptSegment(
                    id: "utt-3",
                    speaker: TranscriptSpeaker(identifier: nil, label: "Unassigned"),
                    text: "Speakerless turn.",
                    language: nil
                )
            ],
            providerID: "deepgram-batch-transcribe",
            modelID: "nova-3",
            localeIdentifier: "zh-CN",
            createdAt: createdAt,
            updatedAt: updatedAt
        )

        XCTAssertEqual(document.speakers, [
            CaptionSpeaker(id: "speaker-a", label: "Alice", providerSpeakerID: "speaker-a")
        ])
        XCTAssertEqual(document.turns.map(\.speakerLabel), ["Alice", "Alice", "Unassigned"])
        XCTAssertEqual(document.turns.map(\.language), ["zh-CN", "zh-CN", "zh-CN"])
        XCTAssertEqual(document.createdAt, createdAt)
        XCTAssertEqual(document.updatedAt, updatedAt)
        XCTAssertEqual(document.finalizedAt, updatedAt)
    }

    private func liveDocument() -> CaptionDocument {
        CaptionDocument(turns: [
            CaptionTurn(
                id: "live-1",
                sections: [CaptionSection(text: "Live transcript")],
                state: .final,
                source: CaptionTurnSource(providerID: "deepgram-transcribe")
            )
        ])
    }
}

private struct RefinementFixture {
    let root: URL
    let store: MeetingStore
    let record: MeetingRecord
    let provider: FakeBatchAudioTranscriptionProvider
    let configuration: SpeechTranscriptionConfiguration
    let service: PostMeetingTranscriptRefinementService

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("refinement-\(UUID().uuidString)", isDirectory: true)
        store = MeetingStore(baseDirectory: root)
        record = try store.createMeeting(name: "Deepgram Batch", startedAt: Date(timeIntervalSince1970: 100)).record
        let fakeProvider = FakeBatchAudioTranscriptionProvider()
        provider = fakeProvider
        configuration = SpeechTranscriptionConfiguration(
            provider: .whisper,
            localeIdentifier: "en-US",
            whisperBinaryPath: nil,
            whisperModelPath: nil,
            transcriptionExecutionMode: .hosted,
            hostedTranscriptionProviderID: "deepgram-transcribe",
            deepgramAPIKey: "key",
            deepgramModelID: "nova-3",
            batchTranscriptionProviderID: "deepgram-batch-transcribe",
            batchTranscriptionModelID: "nova-3"
        )
        service = PostMeetingTranscriptRefinementService(
            store: store,
            saveCaptionDocument: { document, record in
                try FileTranscriptRepository().saveCaptionDocument(document, for: record)
            },
            providerFactory: { _ in fakeProvider },
            now: Date.init
        )
    }
}

private final class FakeBatchAudioTranscriptionProvider: AudioTranscriptionProvider {
    let descriptor = ProviderDescriptor(
        id: "deepgram-batch-transcribe",
        displayName: "Deepgram Batch",
        capability: .audioTranscription,
        executionMode: .hosted,
        supportedSourceLocales: ["*"],
        supportedTargetLocales: [],
        requiresNetwork: true,
        requiresAPIKey: true
    )

    var document = TranscriptDocument()
    var error: Error?
    private(set) var requests: [AudioInput] = []

    func transcribe(audio: AudioInput, options: TranscriptionOptions) async throws -> TranscriptDocument {
        requests.append(audio)
        if let error {
            throw error
        }
        return document
    }
}
