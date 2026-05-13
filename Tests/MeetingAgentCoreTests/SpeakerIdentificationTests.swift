import XCTest
@testable import MeetingAgentCore

final class SpeakerIdentificationTests: XCTestCase {
    func testResolverMatchesExistingProfileAboveAutoThreshold() {
        let profileID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let profile = SpeakerProfile(
            id: profileID,
            displayName: "Allan",
            anonymousName: "Speaker 1",
            confirmationStatus: .confirmed,
            embeddings: [
                SpeakerVoiceEmbedding(
                    modelID: "fake",
                    vector: [1, 0, 0],
                    durationSeconds: 4,
                    sourceMeetingID: nil
                )
            ]
        )
        let resolver = SpeakerIdentityResolver(autoMatchThreshold: 0.80, reviewThreshold: 0.65)

        let result = resolver.resolve(
            localSpeaker: TranscriptSpeaker(identifier: "deepgram-speaker-2"),
            candidate: SpeakerVoiceEmbedding(
                modelID: "fake",
                vector: [0.98, 0.02, 0],
                durationSeconds: 4,
                sourceMeetingID: nil
            ),
            profiles: [profile],
            nextAnonymousName: "Speaker 2"
        )

        XCTAssertEqual(result.decision, .matched)
        XCTAssertEqual(result.profile.id, profileID)
        XCTAssertEqual(result.displayLabel, "Allan")
        XCTAssertGreaterThan(result.confidence, 0.80)
        XCTAssertEqual(result.localSpeaker.identifier, "deepgram-speaker-2")
    }

    func testResolverMarksAmbiguousMatchForReview() {
        let profile = SpeakerProfile(
            displayName: nil,
            anonymousName: "Speaker 1",
            confirmationStatus: .anonymous,
            embeddings: [
                SpeakerVoiceEmbedding(modelID: "fake", vector: [1, 0], durationSeconds: 4, sourceMeetingID: nil)
            ]
        )
        let resolver = SpeakerIdentityResolver(autoMatchThreshold: 0.90, reviewThreshold: 0.70)

        let result = resolver.resolve(
            localSpeaker: TranscriptSpeaker(identifier: "speaker-a"),
            candidate: SpeakerVoiceEmbedding(modelID: "fake", vector: [0.7, 0.7], durationSeconds: 4, sourceMeetingID: nil),
            profiles: [profile],
            nextAnonymousName: "Speaker 2"
        )

        XCTAssertEqual(result.decision, .needsConfirmation)
        XCTAssertEqual(result.profile.id, profile.id)
        XCTAssertEqual(result.displayLabel, "Speaker 1")
    }

    func testResolverCreatesAnonymousProfileWhenBelowReviewThreshold() {
        let existing = SpeakerProfile(
            displayName: "Allan",
            anonymousName: "Speaker 1",
            confirmationStatus: .confirmed,
            embeddings: [
                SpeakerVoiceEmbedding(modelID: "fake", vector: [1, 0], durationSeconds: 4, sourceMeetingID: nil)
            ]
        )
        let resolver = SpeakerIdentityResolver(autoMatchThreshold: 0.90, reviewThreshold: 0.70)
        let candidate = SpeakerVoiceEmbedding(modelID: "fake", vector: [0, 1], durationSeconds: 3, sourceMeetingID: nil)

        let result = resolver.resolve(
            localSpeaker: TranscriptSpeaker(identifier: "speaker-b"),
            candidate: candidate,
            profiles: [existing],
            nextAnonymousName: "Speaker 2"
        )

        XCTAssertEqual(result.decision, .createdAnonymous)
        XCTAssertNotEqual(result.profile.id, existing.id)
        XCTAssertEqual(result.profile.displayName, nil)
        XCTAssertEqual(result.profile.anonymousName, "Speaker 2")
        XCTAssertEqual(result.profile.embeddings, [candidate])
        XCTAssertEqual(result.displayLabel, "Speaker 2")
    }

    func testProfileAddEmbeddingKeepsNewestBoundedEmbeddings() {
        var profile = SpeakerProfile(
            displayName: "Allan",
            anonymousName: "Speaker 1",
            confirmationStatus: .confirmed,
            embeddings: [
                SpeakerVoiceEmbedding(modelID: "fake", vector: [1], durationSeconds: 1, sourceMeetingID: nil, createdAt: Date(timeIntervalSince1970: 1)),
                SpeakerVoiceEmbedding(modelID: "fake", vector: [2], durationSeconds: 1, sourceMeetingID: nil, createdAt: Date(timeIntervalSince1970: 2))
            ]
        )

        profile.addEmbedding(
            SpeakerVoiceEmbedding(modelID: "fake", vector: [3], durationSeconds: 1, sourceMeetingID: nil, createdAt: Date(timeIntervalSince1970: 3)),
            maxEmbeddings: 2
        )

        XCTAssertEqual(profile.embeddings.map(\.vector), [[2], [3]])
    }

    func testProfileAddEmbeddingRecordsNewSourceMeetingID() {
        let meetingID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
        var profile = SpeakerProfile(
            displayName: "Allan",
            anonymousName: "Speaker 1",
            confirmationStatus: .confirmed,
            embeddings: [],
            sourceMeetingIDs: []
        )

        profile.addEmbedding(
            SpeakerVoiceEmbedding(
                modelID: "fake",
                vector: [1],
                durationSeconds: 1,
                sourceMeetingID: meetingID
            )
        )

        XCTAssertEqual(profile.sourceMeetingIDs, [meetingID])
    }

    func testProfileDisplayLabelFallsBackToAnonymousName() {
        let named = SpeakerProfile(
            displayName: " Allan ",
            anonymousName: "Speaker 1",
            confirmationStatus: .confirmed,
            embeddings: []
        )
        let anonymous = SpeakerProfile(
            displayName: " ",
            anonymousName: "Speaker 2",
            confirmationStatus: .anonymous,
            embeddings: []
        )

        XCTAssertEqual(named.displayLabel, "Allan")
        XCTAssertEqual(anonymous.displayLabel, "Speaker 2")
    }

    func testCosineSimilarityReturnsZeroForMismatchedOrZeroVectors() {
        XCTAssertEqual(SpeakerIdentityResolver.cosineSimilarity([1, 0], [1]), 0)
        XCTAssertEqual(SpeakerIdentityResolver.cosineSimilarity([0, 0], [1, 0]), 0)
        XCTAssertEqual(SpeakerIdentityResolver.cosineSimilarity([1, 0], [0, 1]), 0, accuracy: 0.0001)
    }
}
