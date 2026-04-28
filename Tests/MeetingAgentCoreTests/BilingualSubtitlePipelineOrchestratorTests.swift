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

    func testFallsBackFromDirectBilingualProfileToTraditionalProfile() async throws {
        let direct = FakeDirectBilingualProvider(id: "direct", result: .failure(ProbeError.speechRecognition("direct unavailable")))
        let transcription = FakeAudioTranscriptionProvider(id: "stt", result: .success(TranscriptDocument(segments: [
            TranscriptSegment(id: "segment-1", text: "hello", language: "en-US", sourceProvider: "stt")
        ])))
        let translation = FakeTextTranslationProvider(id: "mt", result: .success(TranslatedTranscript(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            segments: [
                BilingualSubtitleSegment(id: "segment-1", sourceText: "hello", targetText: "你好", providerChain: ["stt", "mt"])
            ],
            provenance: PipelineProvenance(profileID: "traditional")
        )))
        let directProfile = BilingualPipelineProfile(id: "direct-profile", displayName: "Direct", steps: [
            PipelineStep(capability: .bilingualSubtitle, primary: .provider("direct"), fallbacks: [.profile("traditional")])
        ])
        let traditionalProfile = BilingualPipelineProfile(id: "traditional", displayName: "Traditional", steps: [
            PipelineStep(capability: .audioTranscription, primary: .provider("stt")),
            PipelineStep(capability: .textTranslation, primary: .provider("mt"))
        ])
        let orchestrator = BilingualSubtitlePipelineOrchestrator(
            profiles: [directProfile, traditionalProfile],
            audioTranscriptionProviders: [transcription],
            textTranslationProviders: [translation],
            directBilingualProviders: [direct]
        )

        let output = try await orchestrator.generate(
            audio: AudioInput(localeIdentifier: "en-US"),
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            profileID: "direct-profile"
        )

        XCTAssertEqual(output.segments.first?.targetText, "你好")
        XCTAssertEqual(output.provenance.profileID, "direct-profile")
        XCTAssertEqual(output.provenance.fallbackReasons["direct"], "Speech recognition error: direct unavailable")
    }

    func testReturnsDirectBilingualProviderOutput() async throws {
        let direct = FakeDirectBilingualProvider(id: "direct", result: .success(BilingualTranscript(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            segments: [BilingualSubtitleSegment(id: "segment-1", sourceText: "hello", targetText: "你好")],
            provenance: PipelineProvenance(profileID: "direct-profile")
        )))
        let profile = BilingualPipelineProfile(id: "direct-profile", displayName: "Direct", steps: [
            PipelineStep(capability: .bilingualSubtitle, primary: .provider("direct"))
        ])
        let orchestrator = BilingualSubtitlePipelineOrchestrator(
            profiles: [profile],
            directBilingualProviders: [direct]
        )

        let output = try await orchestrator.generate(
            audio: AudioInput(localeIdentifier: "en-US"),
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            profileID: "direct-profile"
        )

        XCTAssertEqual(output.segments.first?.targetText, "你好")
        XCTAssertEqual(output.provenance.successfulProviders, ["direct"])
    }

    func testReturnsSourceOnlySegmentsWhenAllTranslationProvidersFail() async throws {
        let transcription = FakeAudioTranscriptionProvider(id: "stt", result: .success(TranscriptDocument(segments: [
            TranscriptSegment(id: "segment-1", startTimeSeconds: 1, endTimeSeconds: 2, text: "hello", language: "en-US", sourceProvider: "stt")
        ])))
        let failedTranslation = FakeTextTranslationProvider(id: "mt", result: .failure(ProbeError.speechRecognition("translation failed")))
        let profile = BilingualPipelineProfile(id: "profile", displayName: "Profile", steps: [
            PipelineStep(capability: .audioTranscription, primary: .provider("missing"), fallbacks: [.profile("ignored"), .provider("stt")]),
            PipelineStep(capability: .textTranslation, primary: .provider("missing-mt"), fallbacks: [.profile("ignored"), .provider("mt")])
        ])
        let orchestrator = BilingualSubtitlePipelineOrchestrator(
            profiles: [profile],
            audioTranscriptionProviders: [transcription],
            textTranslationProviders: [failedTranslation]
        )

        let output = try await orchestrator.generate(
            audio: AudioInput(localeIdentifier: "en-US"),
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            profileID: "profile"
        )

        XCTAssertEqual(output.segments.first?.sourceText, "hello")
        XCTAssertEqual(output.segments.first?.targetText, "")
        XCTAssertEqual(output.segments.first?.status, .sourceOnly)
        XCTAssertEqual(output.segments.first?.errorMessage, "all translation providers failed")
        XCTAssertEqual(output.provenance.fallbackReasons["mt"], "Speech recognition error: translation failed")
    }

    func testSkipsTranslationProviderWhenSourceAndTargetLanguagesMatch() async throws {
        let transcription = FakeAudioTranscriptionProvider(id: "stt", result: .success(TranscriptDocument(segments: [
            TranscriptSegment(id: "segment-1", startTimeSeconds: 1, endTimeSeconds: 2, text: "hello", language: "en-US", sourceProvider: "stt")
        ])))
        let translation = FakeTextTranslationProvider(id: "mt", result: .success(TranslatedTranscript(
            sourceLocale: "en-US",
            targetLocale: "en-GB",
            segments: [
                BilingualSubtitleSegment(id: "segment-1", sourceText: "hello", targetText: "translated")
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
            targetLocale: "en-GB",
            profileID: "profile"
        )

        XCTAssertEqual(translation.translateCallCount, 0)
        XCTAssertEqual(output.segments.first?.sourceText, "hello")
        XCTAssertEqual(output.segments.first?.targetText, "")
        XCTAssertEqual(output.segments.first?.status, .sourceOnly)
        XCTAssertEqual(output.provenance.successfulProviders, ["stt"])
    }

    func testThrowsForMissingProfilesCyclesUnsupportedStepsAndBadOrdering() async {
        let cycleProfile = BilingualPipelineProfile(id: "cycle", displayName: "Cycle", steps: [
            PipelineStep(capability: .bilingualSubtitle, primary: .profile("cycle"))
        ])
        let translationOnlyProfile = BilingualPipelineProfile(id: "translation-only", displayName: "Translation", steps: [
            PipelineStep(capability: .textTranslation, primary: .provider("mt"))
        ])
        let speechTranslationProfile = BilingualPipelineProfile(id: "speech", displayName: "Speech", steps: [
            PipelineStep(capability: .speechTranslation, primary: .provider("speech"))
        ])
        let emptyProfile = BilingualPipelineProfile(id: "empty", displayName: "Empty", steps: [])
        let failedDirectProfile = BilingualPipelineProfile(id: "failed-direct", displayName: "Direct", steps: [
            PipelineStep(capability: .bilingualSubtitle, primary: .provider("missing"))
        ])
        let failedTranscriptionProfile = BilingualPipelineProfile(id: "failed-stt", displayName: "STT", steps: [
            PipelineStep(capability: .audioTranscription, primary: .provider("missing"))
        ])
        let orchestrator = BilingualSubtitlePipelineOrchestrator(
            profiles: [
                cycleProfile,
                translationOnlyProfile,
                speechTranslationProfile,
                emptyProfile,
                failedDirectProfile,
                failedTranscriptionProfile
            ]
        )

        await assertPipelineError(orchestrator, profileID: "missing", "Bilingual pipeline profile not found: missing")
        await assertPipelineError(orchestrator, profileID: "cycle", "Bilingual pipeline profile cycle detected at cycle")
        await assertPipelineError(orchestrator, profileID: "translation-only", "Bilingual pipeline missing transcript before translation")
        await assertPipelineError(orchestrator, profileID: "speech", "Unsupported bilingual pipeline step: speechTranslation")
        await assertPipelineError(orchestrator, profileID: "empty", "Bilingual pipeline did not produce output for profile empty")
        await assertPipelineError(orchestrator, profileID: "failed-direct", "Bilingual pipeline step failed: bilingualSubtitle")
        await assertPipelineError(orchestrator, profileID: "failed-stt", "Bilingual pipeline step failed: audioTranscription")
    }
}

private func assertPipelineError(
    _ orchestrator: BilingualSubtitlePipelineOrchestrator,
    profileID: String,
    _ expectedDescription: String,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await orchestrator.generate(
            audio: AudioInput(localeIdentifier: "en-US"),
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            profileID: profileID
        )
        XCTFail("Expected pipeline error", file: file, line: line)
    } catch {
        XCTAssertEqual(String(describing: error), expectedDescription, file: file, line: line)
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

private final class FakeTextTranslationProvider: TextTranslationProvider {
    let descriptor: ProviderDescriptor
    let result: Result<TranslatedTranscript, Error>
    private(set) var translateCallCount = 0

    init(id: String, result: Result<TranslatedTranscript, Error>) {
        descriptor = ProviderDescriptor(id: id, displayName: id, capability: .textTranslation, executionMode: .hosted, supportedSourceLocales: ["*"], supportedTargetLocales: ["*"], requiresNetwork: false, requiresAPIKey: false)
        self.result = result
    }

    func translate(transcript: TranscriptDocument, options: TranslationOptions) async throws -> TranslatedTranscript {
        translateCallCount += 1
        return try result.get()
    }
}

private struct FakeDirectBilingualProvider: DirectBilingualSubtitleProvider {
    let descriptor: ProviderDescriptor
    let result: Result<BilingualTranscript, Error>

    init(id: String, result: Result<BilingualTranscript, Error>) {
        descriptor = ProviderDescriptor(id: id, displayName: id, capability: .bilingualSubtitle, executionMode: .hosted, supportedSourceLocales: ["*"], supportedTargetLocales: ["*"], requiresNetwork: false, requiresAPIKey: false)
        self.result = result
    }

    func generate(audio: AudioInput, options: BilingualSubtitleOptions) async throws -> BilingualTranscript {
        try result.get()
    }
}
