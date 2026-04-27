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
        XCTAssertEqual(registry.descriptor(id: "openrouter-transcribe")?.capability, .audioTranscription)
        XCTAssertEqual(registry.descriptor(id: "deepgram-transcribe")?.capability, .audioTranscription)
        XCTAssertEqual(registry.descriptor(id: "deepgram-transcribe")?.displayName, "Deepgram Transcribe")
        XCTAssertEqual(registry.descriptor(id: "openrouter-translation")?.capability, .textTranslation)
        XCTAssertEqual(registry.descriptor(id: "qwen-local-translation")?.capability, .textTranslation)
    }

    func testBuiltInProfilesUseOpenRouterHostedProviderIDs() {
        let ids = BilingualPipelineFactory.builtInProviderDescriptors.map(\.id)

        XCTAssertTrue(ids.contains("openrouter-transcribe"))
        XCTAssertTrue(ids.contains("deepgram-transcribe"))
        XCTAssertTrue(ids.contains("openrouter-translation"))
        XCTAssertFalse(ids.contains("openai-transcribe"))
        XCTAssertFalse(ids.contains("openai-translation"))
    }

    func testBuiltInModelOptionsContainSeparateHostedTranscriptionAndTranslationModels() {
        XCTAssertTrue(BilingualPipelineFactory.hostedTranscriptionModelOptions.contains { $0.id == "google/gemini-2.5-flash" })
        XCTAssertTrue(BilingualPipelineFactory.hostedTranscriptionModelOptions.contains { $0.id == "nova-3" })
        XCTAssertTrue(BilingualPipelineFactory.hostedTranslationModelOptions.contains { $0.id == "openai/gpt-4.1-mini" })
    }
}
