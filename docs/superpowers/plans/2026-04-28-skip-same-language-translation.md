# Skip Same-Language Translation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Skip text translation calls when source and target language identifiers represent the same language.

**Architecture:** Add one shared locale-language predicate on `TranslationOptions`, then use it in the bilingual subtitle orchestrator, the live caption adapter, and the view-model scheduler. Same-language live captions become complete original-only captions, while pipeline exports emit source-only bilingual segments.

**Tech Stack:** Swift 5.9, Swift Package Manager, XCTest, macOS 14.2 target.

---

### Task 1: Shared Same-Language Predicate

**Files:**
- Modify: `Sources/MeetingAgentCore/BilingualProvider.swift`
- Modify: `Tests/MeetingAgentCoreTests/BilingualProviderRegistryTests.swift`

- [ ] **Step 1: Write locale matching tests**

Add this test to `BilingualProviderRegistryTests`:

```swift
func testTranslationOptionsDetectSameLanguageLocales() {
    XCTAssertTrue(TranslationOptions(sourceLocale: "en-US", targetLocale: "en-GB").isSameLanguage)
    XCTAssertTrue(TranslationOptions(sourceLocale: " zh_CN ", targetLocale: "zh-TW").isSameLanguage)
    XCTAssertTrue(TranslationOptions(sourceLocale: "JA", targetLocale: "ja-JP").isSameLanguage)
    XCTAssertFalse(TranslationOptions(sourceLocale: "en-US", targetLocale: "zh-CN").isSameLanguage)
    XCTAssertFalse(TranslationOptions(sourceLocale: "", targetLocale: "en-US").isSameLanguage)
    XCTAssertFalse(TranslationOptions(sourceLocale: "   ", targetLocale: "   ").isSameLanguage)
}
```

- [ ] **Step 2: Run the focused test and confirm it fails**

Run: `swift test --filter BilingualProviderRegistryTests/testTranslationOptionsDetectSameLanguageLocales`

Expected: compile failure because `isSameLanguage` does not exist.

- [ ] **Step 3: Add the shared predicate**

Add this to `BilingualProvider.swift` after `TranslationOptions`:

```swift
public extension TranslationOptions {
    var isSameLanguage: Bool {
        LocaleLanguageMatcher.isSameLanguage(sourceLocale, targetLocale)
    }
}

enum LocaleLanguageMatcher {
    static func isSameLanguage(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = languageCode(from: lhs),
              let right = languageCode(from: rhs)
        else {
            return false
        }
        return left == right
    }

    private static func languageCode(from localeIdentifier: String) -> String? {
        let normalized = localeIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        guard let language = normalized.split(separator: "-").first,
              !language.isEmpty
        else {
            return nil
        }
        return String(language)
    }
}
```

- [ ] **Step 4: Run the focused test and confirm it passes**

Run: `swift test --filter BilingualProviderRegistryTests/testTranslationOptionsDetectSameLanguageLocales`

Expected: pass.

### Task 2: Skip Same-Language Pipeline Translation

**Files:**
- Modify: `Sources/MeetingAgentCore/BilingualSubtitlePipelineOrchestrator.swift`
- Modify: `Tests/MeetingAgentCoreTests/BilingualSubtitlePipelineOrchestratorTests.swift`

- [ ] **Step 1: Make fake translation provider count calls**

Update the fake provider in `BilingualSubtitlePipelineOrchestratorTests`:

```swift
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
```

- [ ] **Step 2: Write the skip test**

Add this test:

```swift
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
```

- [ ] **Step 3: Run the focused test and confirm it fails**

Run: `swift test --filter BilingualSubtitlePipelineOrchestratorTests/testSkipsTranslationProviderWhenSourceAndTargetLanguagesMatch`

Expected: failure because the translation provider is called.

- [ ] **Step 4: Implement pipeline skip**

In `runTranslationStep`, create `let options = TranslationOptions(sourceLocale: sourceLocale, targetLocale: targetLocale)`. If `options.isSameLanguage`, return a `TranslatedTranscript` with source-only segments before iterating providers.

- [ ] **Step 5: Run the focused test and confirm it passes**

Run: `swift test --filter BilingualSubtitlePipelineOrchestratorTests/testSkipsTranslationProviderWhenSourceAndTargetLanguagesMatch`

Expected: pass.

### Task 3: Skip Same-Language Live Caption Translation

**Files:**
- Modify: `Sources/MeetingAgentCore/LiveMeetingCockpit.swift`
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Modify: `Tests/MeetingAgentCoreTests/LiveCaptionTranslationAdapterTests.swift`
- Modify: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] **Step 1: Write adapter skip test**

Add this to `LiveCaptionTranslationAdapterTests`:

```swift
func testSameLanguageFinalCaptionDoesNotCallTranslationProvider() async throws {
    var store = LiveCaptionStore(sourceLocale: "en-US", targetLocale: "en-GB")
    let turn = store.append(TranscriptSegment(id: "segment-1", text: "hello", language: "en-US", isFinal: true))
    let provider = FakeTextTranslationProvider(translations: ["segment-1": "translated"])
    let adapter = LiveCaptionTranslationAdapter(provider: provider)

    try await adapter.translate(turn: turn, in: &store)

    XCTAssertEqual(provider.translateCallCount, 0)
    XCTAssertNil(store.turns.first?.translatedText)
    XCTAssertEqual(store.turns.first?.translationHealth, .live)
}
```

- [ ] **Step 2: Write view-model scheduler skip test**

Add this near the existing live caption translation tests in `MeetingAgentViewModelTests`:

```swift
func testDrainRecordingFramesSkipsCaptionTranslationWhenSourceAndTargetLanguagesMatch() async throws {
    let fixture = try ViewModelRecorderFixture()
    var providerFactoryCallCount = 0
    let provider = ViewModelFakeTextTranslationProvider(translations: ["segment-1": "translated"])
    let target = AudioCaptureTarget(processID: 10, displayName: "zoom.us", bundleIdentifier: "us.zoom.xos")
    let viewModel = MeetingAgentViewModel(
        store: fixture.store,
        recorder: fixture.recorder,
        speechConfiguration: SpeechTranscriptionConfiguration(
            provider: .whisper,
            localeIdentifier: "en-US",
            targetLocaleIdentifier: "en-GB",
            whisperBinaryPath: nil,
            whisperModelPath: nil,
            transcriptionExecutionMode: .hosted,
            translationExecutionMode: .hosted,
            hostedTranscriptionProviderID: "deepgram-transcribe",
            hostedTranslationProviderID: "openrouter-translation",
            openRouterAPIKey: "settings-openrouter-key",
            deepgramAPIKey: "settings-deepgram-key"
        ),
        captionTranslationProviderFactory: { _ in
            providerFactoryCallCount += 1
            return provider
        },
        processTargetsProvider: { [target] }
    )
    try await viewModel.startRecording(for: target)
    let record = try XCTUnwrap(viewModel.meetings.first)
    let transcriptWriter = try TranscriptFileWriter(url: XCTUnwrap(record.transcriptURL))
    try transcriptWriter.replace(with: [
        TranscriptSegment(id: "segment-1", text: "Alex is the launch owner.", language: "en-US", isFinal: true)
    ])

    viewModel.drainRecordingFrames()
    try await Task.sleep(nanoseconds: 20_000_000)

    XCTAssertEqual(providerFactoryCallCount, 0)
    XCTAssertEqual(provider.requests.count, 0)
    XCTAssertNil(viewModel.liveCaptionTurns.first?.translatedText)
    XCTAssertEqual(viewModel.liveCaptionTurns.first?.translationHealth, .live)
    XCTAssertEqual(viewModel.meetingProgressHealth.translation, .live)
}
```

- [ ] **Step 3: Run focused tests and confirm they fail**

Run: `swift test --filter LiveCaptionTranslationAdapterTests/testSameLanguageFinalCaptionDoesNotCallTranslationProvider`

Expected: failure because the provider is called.

Run: `swift test --filter MeetingAgentViewModelTests/testDrainRecordingFramesSkipsCaptionTranslationWhenSourceAndTargetLanguagesMatch`

Expected: failure because the provider factory is called or the caption remains pending.

- [ ] **Step 4: Add a completion helper to the store**

Add this method to `LiveCaptionStore`:

```swift
public mutating func markTranslationCompleteWithoutText(forTurnID turnID: String) {
    guard let index = turns.firstIndex(where: { $0.id == turnID }) else { return }
    turns[index].translatedText = nil
    turns[index].translationHealth = .live
}
```

- [ ] **Step 5: Use the helper in adapter and scheduler**

In `LiveCaptionTranslationAdapter.translate`, return early after marking complete when `TranslationOptions(sourceLocale: turn.sourceLocale, targetLocale: turn.targetLocale).isSameLanguage`.

In `MeetingAgentViewModel.scheduleCaptionTextTranslationIfNeeded`, first mark same-language pending final turns complete, store their translation keys, publish `liveCaptionTurns`, update translation health, and exclude those turns from provider candidates.

- [ ] **Step 6: Run focused tests and confirm they pass**

Run the two focused test commands from Step 3.

Expected: both pass.

### Task 4: Full Verification and Commit

**Files:**
- All modified implementation, tests, spec, and plan files.

- [ ] **Step 1: Run local verification**

Run: `make test`

Expected: all tests pass.

- [ ] **Step 2: Inspect diff**

Run: `git diff --check`

Expected: no whitespace errors.

- [ ] **Step 3: Commit**

Run:

```bash
git add Sources/MeetingAgentCore/BilingualProvider.swift Sources/MeetingAgentCore/BilingualSubtitlePipelineOrchestrator.swift Sources/MeetingAgentCore/LiveMeetingCockpit.swift Sources/MeetingAgentCore/MeetingAgentViewModel.swift Tests/MeetingAgentCoreTests/BilingualProviderRegistryTests.swift Tests/MeetingAgentCoreTests/BilingualSubtitlePipelineOrchestratorTests.swift Tests/MeetingAgentCoreTests/LiveCaptionTranslationAdapterTests.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift docs/superpowers/specs/2026-04-28-skip-same-language-translation-design.md docs/superpowers/plans/2026-04-28-skip-same-language-translation.md
git commit -m "feat: skip same-language translation (#43)"
```

Expected: commit succeeds.
