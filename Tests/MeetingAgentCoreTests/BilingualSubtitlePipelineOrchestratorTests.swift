import XCTest
@testable import MeetingAgentCore

final class BilingualSubtitlePipelineOrchestratorTests: XCTestCase {
    func testTraditionalChainRunsTranscriptionThenTranslation() async throws {
        let transcription = FakeAudioTranscriptionProvider(id: "stt", result: .success(TranscriptDocument(segments: [
            TranscriptSegment(id: "segment-1", text: "hello", language: "en-US", sourceProvider: "stt")
        ])))
        let translation = FakeTextTranslationProvider(id: "mt", result: .success(TranslatedTranscript(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            segments: [
                BilingualSubtitleSegment(id: "segment-1", sourceText: "hello", targetText: "你好", providerChain: ["stt", "mt"])
            ],
            provenance: PipelineProvenance(profileID: "profile")
        )))
        let profile = BilingualPipelineProfile(id: "profile", displayName: "Profile", steps: [
            PipelineStep(capability: .audioTranscription, primary: .provider("stt")),
            PipelineStep(capability: .textTranslation, primary: .provider("mt"))
        ])
        let orchestrator = BilingualSubtitlePipelineOrchestrator(
            profiles: [profile],
            audioTranscriptionProviders: [transcription],
            textTranslationProviders: [translation]
        )

        let output = try await orchestrator.generate(
            audio: AudioInput(localeIdentifier: "en-US"),
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            profileID: "profile"
        )

        XCTAssertEqual(output.segments.first?.sourceText, "hello")
        XCTAssertEqual(output.segments.first?.targetText, "你好")
        XCTAssertEqual(output.provenance.successfulProviders, ["stt", "mt"])
    }

    func testFallsBackFromFailedTranslationAndPreservesSource() async throws {
        let transcription = FakeAudioTranscriptionProvider(id: "stt", result: .success(TranscriptDocument(segments: [
            TranscriptSegment(id: "segment-1", text: "hello", language: "en-US", sourceProvider: "stt")
        ])))
        let failedTranslation = FakeTextTranslationProvider(id: "mt-primary", result: .failure(ProbeError.speechRecognition("translation timed out")))
        let fallbackTranslation = FakeTextTranslationProvider(id: "mt-fallback", result: .success(TranslatedTranscript(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            segments: [
                BilingualSubtitleSegment(id: "segment-1", sourceText: "hello", targetText: "你好", providerChain: ["stt", "mt-fallback"])
            ],
            provenance: PipelineProvenance(profileID: "profile")
        )))
        let profile = BilingualPipelineProfile(id: "profile", displayName: "Profile", steps: [
            PipelineStep(capability: .audioTranscription, primary: .provider("stt")),
            PipelineStep(capability: .textTranslation, primary: .provider("mt-primary"), fallbacks: [.provider("mt-fallback")])
        ])
        let orchestrator = BilingualSubtitlePipelineOrchestrator(
            profiles: [profile],
            audioTranscriptionProviders: [transcription],
            textTranslationProviders: [failedTranslation, fallbackTranslation]
        )

        let output = try await orchestrator.generate(
            audio: AudioInput(localeIdentifier: "en-US"),
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            profileID: "profile"
        )

        XCTAssertEqual(output.segments.first?.targetText, "你好")
        XCTAssertEqual(output.provenance.attemptedProviders, ["stt", "mt-primary", "mt-fallback"])
        XCTAssertEqual(output.provenance.fallbackReasons["mt-primary"], "Speech recognition error: translation timed out")
    }
}

private struct FakeAudioTranscriptionProvider: AudioTranscriptionProvider {
    let descriptor: ProviderDescriptor
    let result: Result<TranscriptDocument, Error>

    init(id: String, result: Result<TranscriptDocument, Error>) {
        descriptor = ProviderDescriptor(id: id, displayName: id, capability: .audioTranscription, executionMode: .local, supportedSourceLocales: ["*"], supportedTargetLocales: [], requiresNetwork: false, requiresAPIKey: false)
        self.result = result
    }

    func transcribe(audio: AudioInput, options: TranscriptionOptions) async throws -> TranscriptDocument {
        try result.get()
    }
}

private struct FakeTextTranslationProvider: TextTranslationProvider {
    let descriptor: ProviderDescriptor
    let result: Result<TranslatedTranscript, Error>

    init(id: String, result: Result<TranslatedTranscript, Error>) {
        descriptor = ProviderDescriptor(id: id, displayName: id, capability: .textTranslation, executionMode: .hosted, supportedSourceLocales: ["*"], supportedTargetLocales: ["*"], requiresNetwork: false, requiresAPIKey: false)
        self.result = result
    }

    func translate(transcript: TranscriptDocument, options: TranslationOptions) async throws -> TranslatedTranscript {
        try result.get()
    }
}
