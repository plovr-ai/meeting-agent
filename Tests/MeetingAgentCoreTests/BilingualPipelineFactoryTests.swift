import XCTest
@testable import MeetingAgentCore

final class BilingualPipelineFactoryTests: XCTestCase {
    func testBuiltInProfilesIncludeInitialExperimentChains() {
        let profiles = BilingualPipelineFactory.builtInProfiles

        XCTAssertTrue(profiles.contains { $0.id == "local-whisper-hosted-translation" })
        XCTAssertTrue(profiles.contains { $0.id == "local-whisper-local-translation" })
        XCTAssertTrue(profiles.contains { $0.id == "hosted-transcribe-hosted-translation" })
    }

    func testBuiltInProviderDescriptorsIncludeWhisperAndTranslationPlaceholders() {
        let registry = BilingualPipelineFactory.builtInRegistry

        XCTAssertEqual(registry.descriptor(id: "whisper-local")?.capability, .audioTranscription)
        XCTAssertEqual(registry.descriptor(id: "openai-translation")?.capability, .textTranslation)
        XCTAssertEqual(registry.descriptor(id: "qwen-local-translation")?.capability, .textTranslation)
    }
}
