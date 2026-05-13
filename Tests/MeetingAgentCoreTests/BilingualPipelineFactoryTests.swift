import XCTest
@testable import MeetingAgentCore

final class BilingualPipelineFactoryTests: XCTestCase {
    func testBuiltInProfilesIncludeTranscriptionChainsOnly() {
        let profiles = BilingualPipelineFactory.builtInProfiles

        XCTAssertTrue(profiles.contains { $0.id == "deepgram-stt" })
        XCTAssertTrue(profiles.contains { $0.id == "local-whisper" })
        XCTAssertTrue(profiles.contains { $0.id == "hosted-transcribe" })
        XCTAssertFalse(profiles.contains { profile in
            profile.steps.contains { $0.capability == .textTranslation }
        })
    }

    func testReliableMVPRecommendedProfileStartsWithDeepgram() throws {
        let profile = try XCTUnwrap(BilingualPipelineFactory.builtInProfiles.first {
            $0.id == SpeechTranscriptionConfiguration.defaultBilingualPipelineProfileID
        })

        XCTAssertEqual(profile.steps.first?.primary, .provider("deepgram-transcribe"))
    }

    func testBuiltInProviderDescriptorsIncludeTranscriptionProvidersOnly() {
        let registry = BilingualPipelineFactory.builtInRegistry

        XCTAssertEqual(registry.descriptor(id: "whisper-local")?.capability, .audioTranscription)
        XCTAssertEqual(registry.descriptor(id: "openrouter-transcribe")?.capability, .audioTranscription)
        XCTAssertEqual(registry.descriptor(id: "deepgram-transcribe")?.capability, .audioTranscription)
        XCTAssertEqual(registry.descriptor(id: "deepgram-transcribe")?.displayName, "Deepgram Transcribe")
        XCTAssertNil(registry.descriptor(id: "openrouter-translation"))
        XCTAssertNil(registry.descriptor(id: "qwen-local-translation"))
    }

    func testBuiltInProfilesUseOpenRouterHostedProviderIDs() {
        let ids = BilingualPipelineFactory.builtInProviderDescriptors.map(\.id)

        XCTAssertTrue(ids.contains("openrouter-transcribe"))
        XCTAssertTrue(ids.contains("deepgram-transcribe"))
        XCTAssertFalse(ids.contains("openrouter-translation"))
        XCTAssertFalse(ids.contains("openai-transcribe"))
        XCTAssertFalse(ids.contains("openai-translation"))
    }

    func testBuiltInModelOptionsContainHostedTranscriptionAndSummaryModels() {
        XCTAssertTrue(BilingualPipelineFactory.hostedTranscriptionModelOptions.contains { $0.id == "google/gemini-2.5-flash" })
        XCTAssertTrue(BilingualPipelineFactory.hostedTranscriptionModelOptions.contains { $0.id == "nova-3" })
        XCTAssertTrue(BilingualPipelineFactory.hostedSummaryModelOptions.contains { $0.id == "openai/gpt-4.1-mini" })
    }
}
