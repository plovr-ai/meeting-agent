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

    func testTranslationOptionsDetectSameLanguageLocales() {
        XCTAssertTrue(TranslationOptions(sourceLocale: "en-US", targetLocale: "en-GB").isSameLanguage)
        XCTAssertTrue(TranslationOptions(sourceLocale: " zh_CN ", targetLocale: "zh-TW").isSameLanguage)
        XCTAssertTrue(TranslationOptions(sourceLocale: "JA", targetLocale: "ja-JP").isSameLanguage)
        XCTAssertFalse(TranslationOptions(sourceLocale: "en-US", targetLocale: "zh-CN").isSameLanguage)
        XCTAssertFalse(TranslationOptions(sourceLocale: "", targetLocale: "en-US").isSameLanguage)
        XCTAssertFalse(TranslationOptions(sourceLocale: "   ", targetLocale: "   ").isSameLanguage)
    }

    func testBuiltInRegistryIncludesOpenAIRealtimeTranscriptionDescriptor() {
        let descriptor = BilingualPipelineFactory.builtInRegistry.descriptor(id: "openai-realtime-transcribe")

        XCTAssertEqual(descriptor?.capability, .audioTranscription)
        XCTAssertEqual(descriptor?.executionMode, .hosted)
        XCTAssertEqual(descriptor?.requiresAPIKey, true)
    }
}
