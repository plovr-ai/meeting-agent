import XCTest
@testable import MeetingAgentCore

final class BilingualProviderRegistryTests: XCTestCase {
    func testRegistryFindsProviderByIDAndCapability() throws {
        let descriptor = ProviderDescriptor(
            id: "whisper-local",
            displayName: "Whisper Local",
            capability: .audioTranscription,
            executionMode: .local,
            supportedSourceLocales: ["en-US", "zh-CN"],
            supportedTargetLocales: [],
            requiresNetwork: false,
            requiresAPIKey: false
        )
        let registry = ProviderRegistry(descriptors: [descriptor])

        XCTAssertEqual(registry.descriptor(id: "whisper-local"), descriptor)
        XCTAssertEqual(registry.descriptors(capability: .audioTranscription), [descriptor])
        XCTAssertEqual(registry.descriptors(capability: .textTranslation), [])
    }

    func testDescriptorSupportsWildcardSourceLocales() {
        let descriptor = ProviderDescriptor(
            id: "openrouter-transcribe",
            displayName: "OpenRouter Transcribe",
            capability: .audioTranscription,
            executionMode: .hosted,
            supportedSourceLocales: ["*"],
            supportedTargetLocales: [],
            requiresNetwork: true,
            requiresAPIKey: true
        )

        XCTAssertTrue(descriptor.supports(sourceLocale: "ko-KR", targetLocale: nil))
    }

    func testBuiltInRegistryIncludesOpenAIRealtimeTranscriptionDescriptor() {
        let descriptor = BilingualPipelineFactory.builtInRegistry.descriptor(id: "openai-realtime-transcribe")

        XCTAssertEqual(descriptor?.capability, .audioTranscription)
        XCTAssertEqual(descriptor?.executionMode, .hosted)
        XCTAssertEqual(descriptor?.requiresAPIKey, true)
    }
}
