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

    func testPipelineReferenceIDsAndValidationErrors() {
        XCTAssertEqual(PipelineReference.provider("provider-id").id, "provider-id")
        XCTAssertEqual(PipelineReference.profile("profile-id").id, "profile-id")
        XCTAssertEqual(
            String(describing: BilingualPipelineProfileError.invalidProfile(id: "profile", reason: "bad step")),
            "Invalid pipeline profile profile: bad step"
        )
    }

    func testValidationRejectsUnknownProviderWrongCapabilityAndUnknownProfile() {
        let registry = ProviderRegistry(descriptors: [
            ProviderDescriptor(id: "translator", displayName: "Translator", capability: .textTranslation, executionMode: .hosted, supportedSourceLocales: ["*"], supportedTargetLocales: ["*"], requiresNetwork: true, requiresAPIKey: true)
        ])

        let unknownProviderProfile = BilingualPipelineProfile(
            id: "unknown-provider",
            displayName: "Unknown Provider",
            steps: [PipelineStep(capability: .audioTranscription, primary: .provider("missing"))]
        )
        XCTAssertThrowsError(try unknownProviderProfile.validate(registry: registry, profilesByID: [:])) { error in
            XCTAssertEqual(String(describing: error), "Invalid pipeline profile unknown-provider: provider missing is not registered")
        }

        let wrongCapabilityProfile = BilingualPipelineProfile(
            id: "wrong-capability",
            displayName: "Wrong Capability",
            steps: [PipelineStep(capability: .audioTranscription, primary: .provider("translator"))]
        )
        XCTAssertThrowsError(try wrongCapabilityProfile.validate(registry: registry, profilesByID: [:])) { error in
            XCTAssertEqual(String(describing: error), "Invalid pipeline profile wrong-capability: provider translator does not support audioTranscription")
        }

        let unknownProfile = BilingualPipelineProfile(
            id: "unknown-profile",
            displayName: "Unknown Profile",
            steps: [PipelineStep(capability: .textTranslation, primary: .profile("missing-profile"))]
        )
        XCTAssertThrowsError(try unknownProfile.validate(registry: registry, profilesByID: [:])) { error in
            XCTAssertEqual(String(describing: error), "Invalid pipeline profile unknown-profile: profile missing-profile is not registered")
        }
    }
}
