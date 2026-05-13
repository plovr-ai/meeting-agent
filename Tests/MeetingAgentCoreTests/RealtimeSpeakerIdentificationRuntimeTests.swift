import XCTest
@testable import MeetingAgentCore

@MainActor
final class RealtimeSpeakerIdentificationRuntimeTests: XCTestCase {
    func testFinalizedNewSpeakerPublishesResolution() async throws {
        let store = SpeakerProfileStore(url: temporaryDirectory().appendingPathComponent("profiles.json"))
        let recorder = ResolutionRecorder()
        let provider = FakeSpeakerEmbeddingProvider(embedding: SpeakerVoiceEmbedding(
            modelID: "fake",
            vector: [1, 0],
            durationSeconds: 3,
            sourceMeetingID: nil
        ))
        let runtime = RealtimeSpeakerIdentificationRuntime(
            embeddingProvider: provider,
            profileStore: store,
            minimumEvidenceDurationSeconds: 2,
            clipProvider: { _, destinationURL, _ in
                SpeakerAudioEvidenceClip(url: destinationURL, durationSeconds: 3, sampleRate: 16_000, channelCount: 1)
            },
            resolutionHandler: { resolution in
                await recorder.append(resolution)
            }
        )

        await runtime.submit(
            document: TranscriptDocument(segments: [
                segment(id: "s1", speakerID: "deepgram-speaker-1", start: 0, end: 3)
            ]),
            changedSegmentIDs: ["s1"],
            meetingID: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        )

        let resolutions = await recorder.resolutions
        XCTAssertEqual(resolutions.count, 1)
        XCTAssertEqual(resolutions.first?.localSpeaker.identifier, "deepgram-speaker-1")
        XCTAssertEqual(resolutions.first?.decision, .createdAnonymous)
        XCTAssertEqual(resolutions.first?.displayLabel, "Speaker 1")
        let callCount = await provider.calls()
        XCTAssertEqual(callCount, 1)
    }

    func testResolutionLogsSpeakerIdentityE2EEvents() async throws {
        let root = temporaryDirectory()
        let eventsURL = root.appendingPathComponent("performance-events.jsonl")
        let store = SpeakerProfileStore(url: root.appendingPathComponent("profiles.json"))
        let provider = FakeSpeakerEmbeddingProvider(embedding: SpeakerVoiceEmbedding(
            modelID: "fake",
            vector: [1, 0],
            durationSeconds: 3,
            sourceMeetingID: nil
        ))
        let runtime = RealtimeSpeakerIdentificationRuntime(
            embeddingProvider: provider,
            profileStore: store,
            minimumEvidenceDurationSeconds: 2,
            performanceEventLogger: PerformanceEventLogger(url: eventsURL),
            clipProvider: { _, destinationURL, _ in
                SpeakerAudioEvidenceClip(url: destinationURL, durationSeconds: 3, sampleRate: 16_000, channelCount: 1)
            },
            resolutionHandler: { _ in }
        )

        await runtime.submit(
            document: TranscriptDocument(segments: [
                segment(id: "s1", speakerID: "deepgram-speaker-1", start: 0, end: 3)
            ]),
            changedSegmentIDs: ["s1"],
            meetingID: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        )

        let events = try readLoggedEvents(from: eventsURL)
        XCTAssertTrue(events.contains { $0.event == "speaker_identity_scheduled" && $0.metadata["speakerID"] == "deepgram-speaker-1" })
        XCTAssertTrue(events.contains { $0.event == "speaker_identity_embedding_started" && $0.metadata["speakerID"] == "deepgram-speaker-1" })
        XCTAssertTrue(events.contains { $0.event == "speaker_identity_embedding_finished" && $0.metadata["speakerID"] == "deepgram-speaker-1" })
        let resolved = try XCTUnwrap(events.first { $0.event == "speaker_identity_resolved" })
        XCTAssertEqual(resolved.metadata["speakerID"], "deepgram-speaker-1")
        XCTAssertEqual(resolved.metadata["decision"], "createdAnonymous")
        XCTAssertEqual(resolved.metadata["displayLabel"], "Speaker 1")
    }

    func testDuplicateSpeakerIsNotRescheduledAfterResolution() async throws {
        let store = SpeakerProfileStore(url: temporaryDirectory().appendingPathComponent("profiles.json"))
        let provider = FakeSpeakerEmbeddingProvider(embedding: SpeakerVoiceEmbedding(
            modelID: "fake",
            vector: [1, 0],
            durationSeconds: 3,
            sourceMeetingID: nil
        ))
        let runtime = RealtimeSpeakerIdentificationRuntime(
            embeddingProvider: provider,
            profileStore: store,
            minimumEvidenceDurationSeconds: 2,
            clipProvider: { _, destinationURL, _ in
                SpeakerAudioEvidenceClip(url: destinationURL, durationSeconds: 3, sampleRate: 16_000, channelCount: 1)
            },
            resolutionHandler: { _ in }
        )
        let document = TranscriptDocument(segments: [
            segment(id: "s1", speakerID: "speaker-a", start: 0, end: 3)
        ])

        await runtime.submit(document: document, changedSegmentIDs: ["s1"], meetingID: UUID?.none)
        await runtime.submit(document: document, changedSegmentIDs: ["s1"], meetingID: UUID?.none)

        let callCount = await provider.calls()
        XCTAssertEqual(callCount, 1)
    }

    func testInsufficientEvidenceDoesNotCreateProfile() async throws {
        let store = SpeakerProfileStore(url: temporaryDirectory().appendingPathComponent("profiles.json"))
        let provider = FakeSpeakerEmbeddingProvider(embedding: SpeakerVoiceEmbedding(
            modelID: "fake",
            vector: [1, 0],
            durationSeconds: 1,
            sourceMeetingID: nil
        ))
        let runtime = RealtimeSpeakerIdentificationRuntime(
            embeddingProvider: provider,
            profileStore: store,
            minimumEvidenceDurationSeconds: 2,
            clipProvider: { _, _, _ in Optional<SpeakerAudioEvidenceClip>.none },
            resolutionHandler: { _ in }
        )

        await runtime.submit(
            document: TranscriptDocument(segments: [
                segment(id: "s1", speakerID: "speaker-a", start: 0, end: 1)
            ]),
            changedSegmentIDs: ["s1"],
            meetingID: UUID?.none
        )

        let callCount = await provider.calls()
        XCTAssertEqual(callCount, 0)
        XCTAssertEqual(try store.loadProfiles(), [])
    }

    func testMissingClipAfterEnoughEvidenceDoesNotCreateProfile() async throws {
        let store = SpeakerProfileStore(url: temporaryDirectory().appendingPathComponent("profiles.json"))
        let provider = FakeSpeakerEmbeddingProvider(embedding: SpeakerVoiceEmbedding(
            modelID: "fake",
            vector: [1, 0],
            durationSeconds: 3,
            sourceMeetingID: nil
        ))
        let runtime = RealtimeSpeakerIdentificationRuntime(
            embeddingProvider: provider,
            profileStore: store,
            minimumEvidenceDurationSeconds: 2,
            clipProvider: { _, _, _ in Optional<SpeakerAudioEvidenceClip>.none },
            resolutionHandler: { _ in }
        )

        await runtime.submit(
            document: TranscriptDocument(segments: [
                segment(id: "s1", speakerID: "speaker-a", start: 0, end: 3)
            ]),
            changedSegmentIDs: ["s1"],
            meetingID: UUID?.none
        )

        let callCount = await provider.calls()
        XCTAssertEqual(callCount, 0)
        XCTAssertEqual(try store.loadProfiles(), [])
    }

    func testEmbeddingFailureDoesNotCreateProfile() async throws {
        let store = SpeakerProfileStore(url: temporaryDirectory().appendingPathComponent("profiles.json"))
        let provider = FailingSpeakerEmbeddingProvider()
        let runtime = RealtimeSpeakerIdentificationRuntime(
            embeddingProvider: provider,
            profileStore: store,
            minimumEvidenceDurationSeconds: 2,
            clipProvider: { _, destinationURL, _ in
                SpeakerAudioEvidenceClip(url: destinationURL, durationSeconds: 3, sampleRate: 16_000, channelCount: 1)
            },
            resolutionHandler: { _ in }
        )

        await runtime.submit(
            document: TranscriptDocument(segments: [
                segment(id: "s1", speakerID: "speaker-a", start: 0, end: 3)
            ]),
            changedSegmentIDs: ["s1"],
            meetingID: UUID?.none
        )

        let callCount = await provider.calls()
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(try store.loadProfiles(), [])
    }

    func testResetAllowsSpeakerToBeScheduledAgain() async throws {
        let store = SpeakerProfileStore(url: temporaryDirectory().appendingPathComponent("profiles.json"))
        let provider = FakeSpeakerEmbeddingProvider(embedding: SpeakerVoiceEmbedding(
            modelID: "fake",
            vector: [1, 0],
            durationSeconds: 3,
            sourceMeetingID: nil
        ))
        let runtime = RealtimeSpeakerIdentificationRuntime(
            embeddingProvider: provider,
            profileStore: store,
            minimumEvidenceDurationSeconds: 2,
            clipProvider: { _, destinationURL, _ in
                SpeakerAudioEvidenceClip(url: destinationURL, durationSeconds: 3, sampleRate: 16_000, channelCount: 1)
            },
            resolutionHandler: { _ in }
        )
        let document = TranscriptDocument(segments: [
            segment(id: "s1", speakerID: "speaker-a", start: 0, end: 3)
        ])

        await runtime.submit(document: document, changedSegmentIDs: ["s1"], meetingID: UUID?.none)
        runtime.reset()
        await runtime.submit(document: document, changedSegmentIDs: ["s1"], meetingID: UUID?.none)

        let callCount = await provider.calls()
        XCTAssertEqual(callCount, 2)
    }

    private func segment(id: String, speakerID: String, start: Double, end: Double) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            speaker: TranscriptSpeaker(identifier: speakerID),
            startTimeSeconds: start,
            endTimeSeconds: end,
            text: "hello",
            isFinal: true
        )
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RealtimeSpeakerIdentificationRuntimeTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func readLoggedEvents(from url: URL) throws -> [PerformanceEvent] {
        let decoder = JSONDecoder.meetingAgent
        return try String(contentsOf: url, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map { try decoder.decode(PerformanceEvent.self, from: Data($0.utf8)) }
    }
}

private actor ResolutionRecorder {
    private(set) var resolutions: [SpeakerIdentityResolution] = []

    func append(_ resolution: SpeakerIdentityResolution) {
        resolutions.append(resolution)
    }
}

private actor FakeSpeakerEmbeddingProvider: SpeakerEmbeddingProvider {
    private let embedding: SpeakerVoiceEmbedding
    private(set) var callCount = 0

    init(embedding: SpeakerVoiceEmbedding) {
        self.embedding = embedding
    }

    func embedding(for request: SpeakerEmbeddingRequest) async throws -> SpeakerVoiceEmbedding {
        callCount += 1
        var copy = embedding
        copy.sourceMeetingID = request.sourceMeetingID
        return copy
    }

    func calls() -> Int {
        callCount
    }
}

private actor FailingSpeakerEmbeddingProvider: SpeakerEmbeddingProvider {
    private(set) var callCount = 0

    func embedding(for request: SpeakerEmbeddingRequest) async throws -> SpeakerVoiceEmbedding {
        callCount += 1
        throw SpeakerEmbeddingProviderError.sidecarError("unavailable")
    }

    func calls() -> Int {
        callCount
    }
}
