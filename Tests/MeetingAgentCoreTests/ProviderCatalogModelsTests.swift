import XCTest
@testable import MeetingAgentCore

final class ProviderCatalogModelsTests: XCTestCase {
    func testDescriptorMatchesWildcardAndExplicitLocales() {
        let wildcard = ProviderDescriptor(
            id: "wildcard",
            displayName: "Wildcard",
            capability: .audioTranscription,
            executionMode: .hosted,
            supportedSourceLocales: ["*"],
            supportedTargetLocales: [],
            requiresNetwork: true,
            requiresAPIKey: true
        )
        let explicit = ProviderDescriptor(
            id: "explicit",
            displayName: "Explicit",
            capability: .audioTranscription,
            executionMode: .local,
            supportedSourceLocales: ["en-US"],
            supportedTargetLocales: ["zh-CN"],
            requiresNetwork: false,
            requiresAPIKey: false
        )

        XCTAssertTrue(wildcard.supports(sourceLocale: "ja-JP", targetLocale: nil))
        XCTAssertTrue(explicit.supports(sourceLocale: "en-US", targetLocale: "zh-CN"))
        XCTAssertFalse(explicit.supports(sourceLocale: "ja-JP", targetLocale: "zh-CN"))
        XCTAssertFalse(explicit.supports(sourceLocale: "en-US", targetLocale: "fr-FR"))
    }

    func testProviderRegistryLooksUpAndSortsDescriptors() {
        let local = ProviderDescriptor(
            id: "whisper-local",
            displayName: "Whisper Local",
            capability: .audioTranscription,
            executionMode: .local,
            supportedSourceLocales: ["*"],
            supportedTargetLocales: [],
            requiresNetwork: false,
            requiresAPIKey: false
        )
        let hosted = ProviderDescriptor(
            id: "deepgram-transcribe",
            displayName: "Deepgram",
            capability: .audioTranscription,
            executionMode: .hosted,
            supportedSourceLocales: ["*"],
            supportedTargetLocales: [],
            requiresNetwork: true,
            requiresAPIKey: true
        )

        let registry = ProviderRegistry(descriptors: [local, hosted])

        XCTAssertEqual(registry.descriptor(id: "whisper-local"), local)
        XCTAssertNil(registry.descriptor(id: "missing"))
        XCTAssertEqual(
            registry.descriptors(capability: .audioTranscription).map(\.id),
            ["deepgram-transcribe", "whisper-local"]
        )
    }

    func testAudioInputAndTranscriptionOptionsNormalizeDefaults() {
        let frame = AudioFrame(pcm: Data([1, 2]), sampleRate: 16_000, channelCount: 1, timestampNanos: 10)
        let input = AudioInput(frames: [frame], localeIdentifier: "en-US")
        let options = TranscriptionOptions(sourceLocale: "en-US")

        XCTAssertNil(input.wavURL)
        XCTAssertEqual(input.frames, [frame])
        XCTAssertEqual(input.localeIdentifier, "en-US")
        XCTAssertEqual(options.sourceLocale, "en-US")
    }
}
