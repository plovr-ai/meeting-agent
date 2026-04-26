import XCTest
@testable import MeetingAgentCore

final class BilingualPipelineProfileTests: XCTestCase {
    func testTraditionalProfileValidatesKnownProviders() throws {
        let registry = ProviderRegistry(descriptors: [
            ProviderDescriptor(id: "whisper-local", displayName: "Whisper", capability: .audioTranscription, executionMode: .local, supportedSourceLocales: ["*"], supportedTargetLocales: [], requiresNetwork: false, requiresAPIKey: false),
            ProviderDescriptor(id: "openai-translation", displayName: "Translation", capability: .textTranslation, executionMode: .hosted, supportedSourceLocales: ["*"], supportedTargetLocales: ["*"], requiresNetwork: true, requiresAPIKey: true)
        ])
        let profile = BilingualPipelineProfile(
            id: "local-whisper-hosted-translation",
            displayName: "Local Whisper + Hosted Translation",
            steps: [
                PipelineStep(capability: .audioTranscription, primary: .provider("whisper-local")),
                PipelineStep(capability: .textTranslation, primary: .provider("openai-translation"))
            ]
        )

        XCTAssertNoThrow(try profile.validate(registry: registry, profilesByID: [profile.id: profile]))
    }

    func testValidationRejectsAmbiguousFallbackID() {
        let registry = ProviderRegistry(descriptors: [
            ProviderDescriptor(id: "fallback", displayName: "Fallback Provider", capability: .textTranslation, executionMode: .hosted, supportedSourceLocales: ["*"], supportedTargetLocales: ["*"], requiresNetwork: true, requiresAPIKey: true)
        ])
        let fallbackProfile = BilingualPipelineProfile(id: "fallback", displayName: "Fallback Profile", steps: [])
        let profile = BilingualPipelineProfile(
            id: "profile",
            displayName: "Profile",
            steps: [
                PipelineStep(capability: .textTranslation, primary: .provider("fallback"), fallbacks: [.profile("fallback")])
            ]
        )

        XCTAssertThrowsError(try profile.validate(registry: registry, profilesByID: [
            profile.id: profile,
            fallbackProfile.id: fallbackProfile
        ])) { error in
            XCTAssertEqual(String(describing: error), "Invalid pipeline profile profile: fallback id fallback is both a provider and a profile")
        }
    }
}
