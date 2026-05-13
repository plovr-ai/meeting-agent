import XCTest
@testable import MeetingAgentCore

final class SpeakerProfileStoreTests: XCTestCase {
    func testLoadProfilesReturnsEmptyWhenStoreDoesNotExist() throws {
        let store = SpeakerProfileStore(url: temporaryDirectory().appendingPathComponent("speaker-profiles.json"))

        XCTAssertEqual(try store.loadProfiles(), [])
    }

    func testSaveAndLoadProfilesRoundTripsJSON() throws {
        let store = SpeakerProfileStore(url: temporaryDirectory().appendingPathComponent("speaker-profiles.json"))
        let date = Date(timeIntervalSince1970: 1_000)
        let profile = SpeakerProfile(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            displayName: "Allan",
            anonymousName: "Speaker 1",
            confirmationStatus: .confirmed,
            embeddings: [
                SpeakerVoiceEmbedding(modelID: "fake", vector: [1, 0], durationSeconds: 3, sourceMeetingID: nil, createdAt: date)
            ],
            createdAt: date,
            updatedAt: date
        )

        try store.saveProfiles([profile])

        XCTAssertEqual(try store.loadProfiles(), [profile])
    }

    func testNextAnonymousNameSkipsExistingSpeakerNames() throws {
        let store = SpeakerProfileStore(url: temporaryDirectory().appendingPathComponent("speaker-profiles.json"))
        try store.saveProfiles([
            SpeakerProfile(displayName: nil, anonymousName: "Speaker 1", confirmationStatus: .anonymous, embeddings: []),
            SpeakerProfile(displayName: "Allan", anonymousName: "Speaker 2", confirmationStatus: .confirmed, embeddings: [])
        ])

        XCTAssertEqual(try store.nextAnonymousName(), "Speaker 3")
    }

    func testUpsertReplacesProfileByID() throws {
        let store = SpeakerProfileStore(url: temporaryDirectory().appendingPathComponent("speaker-profiles.json"))
        let profileID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let date = Date(timeIntervalSince1970: 2_000)
        try store.saveProfiles([
            SpeakerProfile(
                id: profileID,
                displayName: nil,
                anonymousName: "Speaker 1",
                confirmationStatus: .anonymous,
                embeddings: [],
                createdAt: date,
                updatedAt: date
            )
        ])

        let updated = SpeakerProfile(
            id: profileID,
            displayName: "Allan",
            anonymousName: "Speaker 1",
            confirmationStatus: .confirmed,
            embeddings: [
                SpeakerVoiceEmbedding(modelID: "fake", vector: [1], durationSeconds: 3, sourceMeetingID: nil, createdAt: date)
            ],
            createdAt: date,
            updatedAt: date
        )
        try store.upsert(updated)

        XCTAssertEqual(try store.loadProfiles(), [updated])
    }

    func testDefaultStoreInitializerIsUsable() throws {
        let store = SpeakerProfileStore()

        _ = try store.nextAnonymousName()
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakerProfileStoreTests-\(UUID().uuidString)", isDirectory: true)
    }
}
