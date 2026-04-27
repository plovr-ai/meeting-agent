import XCTest
@testable import MeetingAgentCore

final class CredentialStoreTests: XCTestCase {
    func testMemoryCredentialStoreSavesLoadsAndDeletesValues() throws {
        let store = MemoryCredentialStore()

        try store.save("openai-key", for: .openAI)
        try store.save("deepgram-key", for: .deepgram)

        XCTAssertEqual(try store.load(.openAI), "openai-key")
        XCTAssertEqual(try store.load(.deepgram), "deepgram-key")

        try store.delete(.openAI)
        XCTAssertNil(try store.load(.openAI))
        XCTAssertEqual(try store.load(.deepgram), "deepgram-key")
    }

    func testBlankCredentialsAreDeleted() throws {
        let store = MemoryCredentialStore()
        try store.save("deepgram-key", for: .deepgram)

        try store.save("   ", for: .deepgram)

        XCTAssertNil(try store.load(.deepgram))
    }

    func testServiceAndAccountNamesAreStable() {
        XCTAssertEqual(CredentialKind.openAI.service, "MeetingAgent")
        XCTAssertEqual(CredentialKind.openAI.account, "openai-api-key")
        XCTAssertEqual(CredentialKind.deepgram.account, "deepgram-api-key")
        XCTAssertEqual(CredentialKind.openRouter.account, "openrouter-api-key")
    }
}
