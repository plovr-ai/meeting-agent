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

    func testDescriptorSupportsWildcardLocales() {
        let descriptor = ProviderDescriptor(
            id: "openai-translation",
            displayName: "Hosted Translation",
            capability: .textTranslation,
            executionMode: .hosted,
            supportedSourceLocales: ["*"],
            supportedTargetLocales: ["*"],
            requiresNetwork: true,
            requiresAPIKey: true
        )

        XCTAssertTrue(descriptor.supports(sourceLocale: "ko-KR", targetLocale: "zh-CN"))
    }
}
