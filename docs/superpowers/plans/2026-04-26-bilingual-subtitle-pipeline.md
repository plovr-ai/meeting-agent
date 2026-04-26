# Bilingual Subtitle Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a configurable bilingual subtitle pipeline that can compose local or hosted providers, switch profiles, and fall back across providers or full chains.

**Architecture:** Add provider-neutral bilingual data models and capability descriptors in `MeetingAgentCore`, then implement a profile resolver and orchestration layer above concrete model providers. Keep existing audio capture and transcript behavior intact while adding bilingual artifacts beside current transcript files.

**Tech Stack:** Swift 5.9, XCTest, existing `MeetingAgentCore` package, existing local Whisper transcription implementation.

---

## File Structure

- Create `Sources/MeetingAgentCore/BilingualTranscript.swift`: bilingual transcript segment models, statuses, translated transcript model, provenance model, and text formatter.
- Create `Sources/MeetingAgentCore/BilingualProvider.swift`: provider capability descriptors, provider registry, provider protocols, options, and audio input model.
- Create `Sources/MeetingAgentCore/BilingualPipelineProfile.swift`: profile models, step fallback references, and profile validation.
- Create `Sources/MeetingAgentCore/BilingualSubtitlePipelineOrchestrator.swift`: orchestrates direct and multi-step chains, fallback, provenance, and partial-output behavior.
- Create `Sources/MeetingAgentCore/WhisperAudioTranscriptionProvider.swift`: adapter from the existing Whisper implementation to the new `AudioTranscriptionProvider` boundary.
- Create `Sources/MeetingAgentCore/BilingualTranscriptStore.swift`: writes `bilingual-transcript.json` and `bilingual-transcript.txt` artifacts.
- Modify `Sources/MeetingAgentCore/MeetingRecorder.swift`: after recording/transcription, optionally run the bilingual pipeline when configured.
- Modify `Sources/MeetingAgentCore/SpeechTranscriptionConfiguration.swift`: add target locale and selected bilingual pipeline profile settings.
- Modify `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`: expose target locale and pipeline profile selection state.
- Modify `Sources/CoreAudioTapProbe/ProbeMain.swift` and `Sources/MeetingAgentCore/ProbeOptions.swift`: add CLI flags for target locale and profile.
- Add tests in `Tests/MeetingAgentCoreTests/BilingualTranscriptTests.swift`, `BilingualProviderRegistryTests.swift`, `BilingualPipelineProfileTests.swift`, `BilingualSubtitlePipelineOrchestratorTests.swift`, `WhisperAudioTranscriptionProviderTests.swift`, and `BilingualTranscriptStoreTests.swift`.

## Task 1: Bilingual Transcript Models And Formatter

**Files:**
- Create: `Sources/MeetingAgentCore/BilingualTranscript.swift`
- Test: `Tests/MeetingAgentCoreTests/BilingualTranscriptTests.swift`

- [ ] **Step 1: Write failing model and formatter tests**

Create `Tests/MeetingAgentCoreTests/BilingualTranscriptTests.swift`:

```swift
import XCTest
@testable import MeetingAgentCore

final class BilingualTranscriptTests: XCTestCase {
    func testFormatterRendersSourceAndTargetBySpeakerTurn() {
        let transcript = BilingualTranscript(
            sourceLocale: "ko-KR",
            targetLocale: "zh-CN",
            segments: [
                BilingualSubtitleSegment(
                    id: "segment-1",
                    startTimeSeconds: 1.0,
                    endTimeSeconds: 2.0,
                    speaker: TranscriptSpeaker(identifier: "speaker-1"),
                    sourceText: "오늘 회의는 여기까지 하겠습니다.",
                    targetText: "今天的会议先到这里。",
                    confidence: 0.92,
                    status: .complete,
                    errorMessage: nil,
                    providerChain: ["whisper-local", "openai-translation"]
                )
            ],
            provenance: PipelineProvenance(profileID: "local-whisper-hosted-translation")
        )

        XCTAssertEqual(BilingualTranscriptFormatter.render(transcript), """
        User A:
        Source: 오늘 회의는 여기까지 하겠습니다.
        Target: 今天的会议先到这里。
        """)
    }

    func testFormatterPreservesSourceOnlyFailedTranslation() {
        let transcript = BilingualTranscript(
            sourceLocale: "en-US",
            targetLocale: "ja-JP",
            segments: [
                BilingualSubtitleSegment(
                    id: "segment-1",
                    speaker: .default,
                    sourceText: "Please review the contract.",
                    targetText: "",
                    status: .sourceOnly,
                    errorMessage: "translation timed out",
                    providerChain: ["whisper-local", "openai-translation"]
                )
            ],
            provenance: PipelineProvenance(profileID: "profile")
        )

        XCTAssertEqual(BilingualTranscriptFormatter.render(transcript), """
        User A:
        Source: Please review the contract.
        Target: [translation unavailable: translation timed out]
        """)
    }

    func testCodableRoundTripKeepsProviderChainAndStatus() throws {
        let transcript = BilingualTranscript(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            segments: [
                BilingualSubtitleSegment(
                    id: "segment-1",
                    speaker: TranscriptSpeaker(identifier: "speaker-1", label: "Manager"),
                    sourceText: "hello",
                    targetText: "你好",
                    status: .complete,
                    providerChain: ["provider-a"]
                )
            ],
            provenance: PipelineProvenance(
                profileID: "profile",
                attemptedProviders: ["provider-a"],
                successfulProviders: ["provider-a"]
            )
        )

        let data = try JSONEncoder().encode(transcript)
        let decoded = try JSONDecoder().decode(BilingualTranscript.self, from: data)

        XCTAssertEqual(decoded, transcript)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter BilingualTranscriptTests`

Expected: build fails because `BilingualTranscript`, `BilingualSubtitleSegment`, `PipelineProvenance`, and `BilingualTranscriptFormatter` do not exist.

- [ ] **Step 3: Implement bilingual models and formatter**

Create `Sources/MeetingAgentCore/BilingualTranscript.swift`:

```swift
import Foundation

public enum BilingualSubtitleSegmentStatus: String, Codable, Equatable {
    case complete
    case sourceOnly
    case targetOnly
    case failed
}

public struct PipelineProvenance: Codable, Equatable {
    public var profileID: String
    public var attemptedProviders: [String]
    public var successfulProviders: [String]
    public var fallbackReasons: [String: String]

    public init(
        profileID: String,
        attemptedProviders: [String] = [],
        successfulProviders: [String] = [],
        fallbackReasons: [String: String] = [:]
    ) {
        self.profileID = profileID
        self.attemptedProviders = attemptedProviders
        self.successfulProviders = successfulProviders
        self.fallbackReasons = fallbackReasons
    }
}

public struct TranslatedTranscript: Codable, Equatable {
    public var sourceLocale: String
    public var targetLocale: String
    public var segments: [BilingualSubtitleSegment]
    public var provenance: PipelineProvenance

    public init(
        sourceLocale: String,
        targetLocale: String,
        segments: [BilingualSubtitleSegment],
        provenance: PipelineProvenance
    ) {
        self.sourceLocale = sourceLocale
        self.targetLocale = targetLocale
        self.segments = segments
        self.provenance = provenance
    }
}

public struct BilingualTranscript: Codable, Equatable {
    public var sourceLocale: String
    public var targetLocale: String
    public var segments: [BilingualSubtitleSegment]
    public var provenance: PipelineProvenance

    public init(
        sourceLocale: String,
        targetLocale: String,
        segments: [BilingualSubtitleSegment],
        provenance: PipelineProvenance
    ) {
        self.sourceLocale = sourceLocale
        self.targetLocale = targetLocale
        self.segments = segments
        self.provenance = provenance
    }
}

public struct BilingualSubtitleSegment: Codable, Equatable, Identifiable {
    public var id: String
    public var speakerID: String?
    public var speakerLabel: String?
    public var startTimeSeconds: Double?
    public var endTimeSeconds: Double?
    public var sourceText: String
    public var targetText: String
    public var confidence: Double?
    public var status: BilingualSubtitleSegmentStatus
    public var errorMessage: String?
    public var providerChain: [String]

    public var speaker: TranscriptSpeaker {
        TranscriptSpeaker(identifier: speakerID, label: speakerLabel)
    }

    public init(
        id: String = UUID().uuidString,
        startTimeSeconds: Double? = nil,
        endTimeSeconds: Double? = nil,
        speaker: TranscriptSpeaker = .default,
        sourceText: String,
        targetText: String,
        confidence: Double? = nil,
        status: BilingualSubtitleSegmentStatus = .complete,
        errorMessage: String? = nil,
        providerChain: [String] = []
    ) {
        self.id = id
        self.speakerID = speaker.identifier
        self.speakerLabel = speaker.label
        self.startTimeSeconds = startTimeSeconds
        self.endTimeSeconds = endTimeSeconds
        self.sourceText = sourceText
        self.targetText = targetText
        self.confidence = confidence
        self.status = status
        self.errorMessage = errorMessage
        self.providerChain = providerChain
    }
}

public enum BilingualTranscriptFormatter {
    public static func render(_ transcript: BilingualTranscript) -> String {
        var mapper = SpeakerLabelMapper()
        return transcript.segments.map { segment in
            let targetText = renderedTarget(for: segment)
            return [
                mapper.label(for: segment.speaker) + ":",
                "Source: \(segment.sourceText)",
                "Target: \(targetText)"
            ].joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }

    private static func renderedTarget(for segment: BilingualSubtitleSegment) -> String {
        if !segment.targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return segment.targetText
        }
        if let errorMessage = segment.errorMessage, !errorMessage.isEmpty {
            return "[translation unavailable: \(errorMessage)]"
        }
        return "[translation unavailable]"
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter BilingualTranscriptTests`

Expected: all `BilingualTranscriptTests` pass.

- [ ] **Step 5: Commit**

Run:

```bash
git add Sources/MeetingAgentCore/BilingualTranscript.swift Tests/MeetingAgentCoreTests/BilingualTranscriptTests.swift
git commit -m "Add bilingual transcript models"
```

## Task 2: Provider Descriptors, Registry, And Protocols

**Files:**
- Create: `Sources/MeetingAgentCore/BilingualProvider.swift`
- Test: `Tests/MeetingAgentCoreTests/BilingualProviderRegistryTests.swift`

- [ ] **Step 1: Write failing registry tests**

Create `Tests/MeetingAgentCoreTests/BilingualProviderRegistryTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter BilingualProviderRegistryTests`

Expected: build fails because provider descriptor types do not exist.

- [ ] **Step 3: Implement provider descriptors and protocols**

Create `Sources/MeetingAgentCore/BilingualProvider.swift`:

```swift
import Foundation

public enum ProviderCapability: String, Codable, Equatable {
    case audioTranscription
    case textTranslation
    case speechTranslation
    case bilingualSubtitle
}

public enum ProviderExecutionMode: String, Codable, Equatable {
    case local
    case hosted
}

public struct ProviderDescriptor: Codable, Equatable {
    public var id: String
    public var displayName: String
    public var capability: ProviderCapability
    public var executionMode: ProviderExecutionMode
    public var supportedSourceLocales: [String]
    public var supportedTargetLocales: [String]
    public var requiresNetwork: Bool
    public var requiresAPIKey: Bool

    public init(
        id: String,
        displayName: String,
        capability: ProviderCapability,
        executionMode: ProviderExecutionMode,
        supportedSourceLocales: [String],
        supportedTargetLocales: [String],
        requiresNetwork: Bool,
        requiresAPIKey: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.capability = capability
        self.executionMode = executionMode
        self.supportedSourceLocales = supportedSourceLocales
        self.supportedTargetLocales = supportedTargetLocales
        self.requiresNetwork = requiresNetwork
        self.requiresAPIKey = requiresAPIKey
    }

    public func supports(sourceLocale: String, targetLocale: String?) -> Bool {
        supports(locale: sourceLocale, in: supportedSourceLocales)
            && (targetLocale.map { supports(locale: $0, in: supportedTargetLocales) } ?? true)
    }

    private func supports(locale: String, in supportedLocales: [String]) -> Bool {
        supportedLocales.contains("*") || supportedLocales.contains(locale)
    }
}

public struct ProviderRegistry {
    private var descriptorsByID: [String: ProviderDescriptor]

    public init(descriptors: [ProviderDescriptor]) {
        descriptorsByID = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0) })
    }

    public func descriptor(id: String) -> ProviderDescriptor? {
        descriptorsByID[id]
    }

    public func descriptors(capability: ProviderCapability) -> [ProviderDescriptor] {
        descriptorsByID.values
            .filter { $0.capability == capability }
            .sorted { $0.id < $1.id }
    }
}

public struct AudioInput: Equatable {
    public var wavURL: URL?
    public var frames: [AudioFrame]
    public var localeIdentifier: String

    public init(wavURL: URL? = nil, frames: [AudioFrame] = [], localeIdentifier: String) {
        self.wavURL = wavURL
        self.frames = frames
        self.localeIdentifier = localeIdentifier
    }
}

public struct TranscriptionOptions: Equatable {
    public var sourceLocale: String
    public init(sourceLocale: String) { self.sourceLocale = sourceLocale }
}

public struct TranslationOptions: Equatable {
    public var sourceLocale: String
    public var targetLocale: String
    public init(sourceLocale: String, targetLocale: String) {
        self.sourceLocale = sourceLocale
        self.targetLocale = targetLocale
    }
}

public typealias SpeechTranslationOptions = TranslationOptions
public typealias BilingualSubtitleOptions = TranslationOptions

public protocol AudioTranscriptionProvider {
    var descriptor: ProviderDescriptor { get }
    func transcribe(audio: AudioInput, options: TranscriptionOptions) async throws -> TranscriptDocument
}

public protocol TextTranslationProvider {
    var descriptor: ProviderDescriptor { get }
    func translate(transcript: TranscriptDocument, options: TranslationOptions) async throws -> TranslatedTranscript
}

public protocol SpeechTranslationProvider {
    var descriptor: ProviderDescriptor { get }
    func translateSpeech(audio: AudioInput, options: SpeechTranslationOptions) async throws -> TranslatedTranscript
}

public protocol DirectBilingualSubtitleProvider {
    var descriptor: ProviderDescriptor { get }
    func generate(audio: AudioInput, options: BilingualSubtitleOptions) async throws -> BilingualTranscript
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter BilingualProviderRegistryTests`

Expected: all registry tests pass.

- [ ] **Step 5: Commit**

Run:

```bash
git add Sources/MeetingAgentCore/BilingualProvider.swift Tests/MeetingAgentCoreTests/BilingualProviderRegistryTests.swift
git commit -m "Add bilingual provider registry"
```

## Task 3: Pipeline Profiles And Validation

**Files:**
- Create: `Sources/MeetingAgentCore/BilingualPipelineProfile.swift`
- Test: `Tests/MeetingAgentCoreTests/BilingualPipelineProfileTests.swift`

- [ ] **Step 1: Write failing profile tests**

Create `Tests/MeetingAgentCoreTests/BilingualPipelineProfileTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter BilingualPipelineProfileTests`

Expected: build fails because profile types do not exist.

- [ ] **Step 3: Implement profile models and validation**

Create `Sources/MeetingAgentCore/BilingualPipelineProfile.swift`:

```swift
import Foundation

public enum PipelineReference: Codable, Equatable {
    case provider(String)
    case profile(String)

    public var id: String {
        switch self {
        case .provider(let id), .profile(let id): return id
        }
    }
}

public struct PipelineStep: Codable, Equatable {
    public var capability: ProviderCapability
    public var primary: PipelineReference
    public var fallbacks: [PipelineReference]

    public init(capability: ProviderCapability, primary: PipelineReference, fallbacks: [PipelineReference] = []) {
        self.capability = capability
        self.primary = primary
        self.fallbacks = fallbacks
    }
}

public struct BilingualPipelineProfile: Codable, Equatable {
    public var id: String
    public var displayName: String
    public var steps: [PipelineStep]

    public init(id: String, displayName: String, steps: [PipelineStep]) {
        self.id = id
        self.displayName = displayName
        self.steps = steps
    }

    public func validate(registry: ProviderRegistry, profilesByID: [String: BilingualPipelineProfile]) throws {
        for step in steps {
            try validate(reference: step.primary, step: step, registry: registry, profilesByID: profilesByID)
            for fallback in step.fallbacks {
                try validate(reference: fallback, step: step, registry: registry, profilesByID: profilesByID)
            }
        }
    }

    private func validate(
        reference: PipelineReference,
        step: PipelineStep,
        registry: ProviderRegistry,
        profilesByID: [String: BilingualPipelineProfile]
    ) throws {
        let provider = registry.descriptor(id: reference.id)
        let profile = profilesByID[reference.id]
        if provider != nil && profile != nil {
            throw BilingualPipelineProfileError.invalidProfile(id: id, reason: "fallback id \(reference.id) is both a provider and a profile")
        }
        switch reference {
        case .provider(let providerID):
            guard let provider else {
                throw BilingualPipelineProfileError.invalidProfile(id: id, reason: "provider \(providerID) is not registered")
            }
            guard provider.capability == step.capability else {
                throw BilingualPipelineProfileError.invalidProfile(id: id, reason: "provider \(providerID) does not support \(step.capability.rawValue)")
            }
        case .profile(let profileID):
            guard profile != nil else {
                throw BilingualPipelineProfileError.invalidProfile(id: id, reason: "profile \(profileID) is not registered")
            }
        }
    }
}

public enum BilingualPipelineProfileError: Error, CustomStringConvertible, Equatable {
    case invalidProfile(id: String, reason: String)

    public var description: String {
        switch self {
        case .invalidProfile(let id, let reason):
            return "Invalid pipeline profile \(id): \(reason)"
        }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter BilingualPipelineProfileTests`

Expected: all profile tests pass.

- [ ] **Step 5: Commit**

Run:

```bash
git add Sources/MeetingAgentCore/BilingualPipelineProfile.swift Tests/MeetingAgentCoreTests/BilingualPipelineProfileTests.swift
git commit -m "Add bilingual pipeline profiles"
```

## Task 4: Orchestrator For Traditional Chain And Fallback

**Files:**
- Create: `Sources/MeetingAgentCore/BilingualSubtitlePipelineOrchestrator.swift`
- Test: `Tests/MeetingAgentCoreTests/BilingualSubtitlePipelineOrchestratorTests.swift`

- [ ] **Step 1: Write failing orchestration tests with fake providers**

Create `Tests/MeetingAgentCoreTests/BilingualSubtitlePipelineOrchestratorTests.swift`:

```swift
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
```

Add fake providers at the bottom of the test file:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter BilingualSubtitlePipelineOrchestratorTests`

Expected: build fails because `BilingualSubtitlePipelineOrchestrator` does not exist.

- [ ] **Step 3: Implement minimal orchestrator for transcription plus text translation**

Create `Sources/MeetingAgentCore/BilingualSubtitlePipelineOrchestrator.swift`:

```swift
import Foundation

public final class BilingualSubtitlePipelineOrchestrator {
    private let profilesByID: [String: BilingualPipelineProfile]
    private let audioTranscriptionProviders: [String: AudioTranscriptionProvider]
    private let textTranslationProviders: [String: TextTranslationProvider]

    public init(
        profiles: [BilingualPipelineProfile],
        audioTranscriptionProviders: [AudioTranscriptionProvider] = [],
        textTranslationProviders: [TextTranslationProvider] = []
    ) {
        self.profilesByID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        self.audioTranscriptionProviders = Dictionary(uniqueKeysWithValues: audioTranscriptionProviders.map { ($0.descriptor.id, $0) })
        self.textTranslationProviders = Dictionary(uniqueKeysWithValues: textTranslationProviders.map { ($0.descriptor.id, $0) })
    }

    public func generate(
        audio: AudioInput,
        sourceLocale: String,
        targetLocale: String,
        profileID: String
    ) async throws -> BilingualTranscript {
        guard let profile = profilesByID[profileID] else {
            throw BilingualPipelineError.profileNotFound(profileID)
        }

        var provenance = PipelineProvenance(profileID: profileID)
        var transcript: TranscriptDocument?

        for step in profile.steps {
            switch step.capability {
            case .audioTranscription:
                transcript = try await runTranscriptionStep(step, audio: audio, sourceLocale: sourceLocale, provenance: &provenance)
            case .textTranslation:
                guard let transcript else {
                    throw BilingualPipelineError.missingTranscriptBeforeTranslation
                }
                let translated = try await runTranslationStep(step, transcript: transcript, sourceLocale: sourceLocale, targetLocale: targetLocale, provenance: &provenance)
                return BilingualTranscript(sourceLocale: sourceLocale, targetLocale: targetLocale, segments: translated.segments, provenance: provenance)
            case .speechTranslation, .bilingualSubtitle:
                throw BilingualPipelineError.unsupportedStep(step.capability)
            }
        }

        throw BilingualPipelineError.noBilingualOutput(profileID)
    }

    private func runTranscriptionStep(
        _ step: PipelineStep,
        audio: AudioInput,
        sourceLocale: String,
        provenance: inout PipelineProvenance
    ) async throws -> TranscriptDocument {
        for reference in [step.primary] + step.fallbacks {
            guard case .provider(let providerID) = reference else { continue }
            guard let provider = audioTranscriptionProviders[providerID] else { continue }
            provenance.attemptedProviders.append(providerID)
            do {
                let result = try await provider.transcribe(audio: audio, options: TranscriptionOptions(sourceLocale: sourceLocale))
                provenance.successfulProviders.append(providerID)
                return result
            } catch {
                provenance.fallbackReasons[providerID] = String(describing: error)
            }
        }
        throw BilingualPipelineError.stepFailed(step.capability)
    }

    private func runTranslationStep(
        _ step: PipelineStep,
        transcript: TranscriptDocument,
        sourceLocale: String,
        targetLocale: String,
        provenance: inout PipelineProvenance
    ) async throws -> TranslatedTranscript {
        for reference in [step.primary] + step.fallbacks {
            guard case .provider(let providerID) = reference else { continue }
            guard let provider = textTranslationProviders[providerID] else { continue }
            provenance.attemptedProviders.append(providerID)
            do {
                let result = try await provider.translate(
                    transcript: transcript,
                    options: TranslationOptions(sourceLocale: sourceLocale, targetLocale: targetLocale)
                )
                provenance.successfulProviders.append(providerID)
                return result
            } catch {
                provenance.fallbackReasons[providerID] = String(describing: error)
            }
        }
        return TranslatedTranscript(
            sourceLocale: sourceLocale,
            targetLocale: targetLocale,
            segments: transcript.segments.map {
                BilingualSubtitleSegment(
                    id: $0.id,
                    startTimeSeconds: $0.startTimeSeconds,
                    endTimeSeconds: $0.endTimeSeconds,
                    speaker: $0.speaker,
                    sourceText: $0.text,
                    targetText: "",
                    confidence: $0.confidence,
                    status: .sourceOnly,
                    errorMessage: "all translation providers failed",
                    providerChain: provenance.successfulProviders
                )
            },
            provenance: provenance
        )
    }
}

public enum BilingualPipelineError: Error, CustomStringConvertible, Equatable {
    case profileNotFound(String)
    case missingTranscriptBeforeTranslation
    case unsupportedStep(ProviderCapability)
    case stepFailed(ProviderCapability)
    case noBilingualOutput(String)

    public var description: String {
        switch self {
        case .profileNotFound(let id): return "Bilingual pipeline profile not found: \(id)"
        case .missingTranscriptBeforeTranslation: return "Bilingual pipeline missing transcript before translation"
        case .unsupportedStep(let capability): return "Unsupported bilingual pipeline step: \(capability.rawValue)"
        case .stepFailed(let capability): return "Bilingual pipeline step failed: \(capability.rawValue)"
        case .noBilingualOutput(let id): return "Bilingual pipeline did not produce output for profile \(id)"
        }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter BilingualSubtitlePipelineOrchestratorTests`

Expected: all orchestrator tests pass.

- [ ] **Step 5: Commit**

Run:

```bash
git add Sources/MeetingAgentCore/BilingualSubtitlePipelineOrchestrator.swift Tests/MeetingAgentCoreTests/BilingualSubtitlePipelineOrchestratorTests.swift
git commit -m "Add bilingual pipeline orchestrator"
```

## Task 5: Direct Bilingual Profile Fallback

**Files:**
- Modify: `Sources/MeetingAgentCore/BilingualSubtitlePipelineOrchestrator.swift`
- Test: `Tests/MeetingAgentCoreTests/BilingualSubtitlePipelineOrchestratorTests.swift`

- [ ] **Step 1: Add failing direct-provider fallback test**

Add this test to `BilingualSubtitlePipelineOrchestratorTests`:

```swift
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
```

Add this fake provider:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter BilingualSubtitlePipelineOrchestratorTests/testFallsBackFromDirectBilingualProfileToTraditionalProfile`

Expected: build fails because the orchestrator initializer has no `directBilingualProviders` parameter and `.bilingualSubtitle` is unsupported.

- [ ] **Step 3: Add direct bilingual execution and profile fallback**

Modify `BilingualSubtitlePipelineOrchestrator`:

```swift
private let directBilingualProviders: [String: DirectBilingualSubtitleProvider]
```

Update the initializer:

```swift
public init(
    profiles: [BilingualPipelineProfile],
    audioTranscriptionProviders: [AudioTranscriptionProvider] = [],
    textTranslationProviders: [TextTranslationProvider] = [],
    directBilingualProviders: [DirectBilingualSubtitleProvider] = []
) {
    self.profilesByID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
    self.audioTranscriptionProviders = Dictionary(uniqueKeysWithValues: audioTranscriptionProviders.map { ($0.descriptor.id, $0) })
    self.textTranslationProviders = Dictionary(uniqueKeysWithValues: textTranslationProviders.map { ($0.descriptor.id, $0) })
    self.directBilingualProviders = Dictionary(uniqueKeysWithValues: directBilingualProviders.map { ($0.descriptor.id, $0) })
}
```

Replace `generate` with a recursive helper that carries original provenance:

```swift
public func generate(
    audio: AudioInput,
    sourceLocale: String,
    targetLocale: String,
    profileID: String
) async throws -> BilingualTranscript {
    var provenance = PipelineProvenance(profileID: profileID)
    return try await generate(
        audio: audio,
        sourceLocale: sourceLocale,
        targetLocale: targetLocale,
        profileID: profileID,
        provenance: &provenance,
        visitedProfiles: []
    )
}
```

Add direct step handling:

```swift
case .bilingualSubtitle:
    return try await runDirectBilingualStep(
        step,
        audio: audio,
        sourceLocale: sourceLocale,
        targetLocale: targetLocale,
        provenance: &provenance,
        visitedProfiles: visitedProfiles
    )
```

Implement direct fallback:

```swift
private func runDirectBilingualStep(
    _ step: PipelineStep,
    audio: AudioInput,
    sourceLocale: String,
    targetLocale: String,
    provenance: inout PipelineProvenance,
    visitedProfiles: Set<String>
) async throws -> BilingualTranscript {
    for reference in [step.primary] + step.fallbacks {
        switch reference {
        case .provider(let providerID):
            guard let provider = directBilingualProviders[providerID] else { continue }
            provenance.attemptedProviders.append(providerID)
            do {
                var output = try await provider.generate(
                    audio: audio,
                    options: BilingualSubtitleOptions(sourceLocale: sourceLocale, targetLocale: targetLocale)
                )
                provenance.successfulProviders.append(providerID)
                output.provenance = provenance
                return output
            } catch {
                provenance.fallbackReasons[providerID] = String(describing: error)
            }
        case .profile(let fallbackProfileID):
            return try await generate(
                audio: audio,
                sourceLocale: sourceLocale,
                targetLocale: targetLocale,
                profileID: fallbackProfileID,
                provenance: &provenance,
                visitedProfiles: visitedProfiles
            )
        }
    }
    throw BilingualPipelineError.stepFailed(.bilingualSubtitle)
}
```

The recursive helper must reject cycles:

```swift
guard !visitedProfiles.contains(profileID) else {
    throw BilingualPipelineError.profileCycle(profileID)
}
let nextVisitedProfiles = visitedProfiles.union([profileID])
```

Add the error case:

```swift
case profileCycle(String)
```

and description:

```swift
case .profileCycle(let id): return "Bilingual pipeline profile cycle detected at \(id)"
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter BilingualSubtitlePipelineOrchestratorTests`

Expected: all orchestrator tests pass.

- [ ] **Step 5: Commit**

Run:

```bash
git add Sources/MeetingAgentCore/BilingualSubtitlePipelineOrchestrator.swift Tests/MeetingAgentCoreTests/BilingualSubtitlePipelineOrchestratorTests.swift
git commit -m "Add direct bilingual pipeline fallback"
```

## Task 6: Whisper AudioTranscriptionProvider Adapter

**Files:**
- Create: `Sources/MeetingAgentCore/WhisperAudioTranscriptionProvider.swift`
- Test: `Tests/MeetingAgentCoreTests/WhisperAudioTranscriptionProviderTests.swift`

- [ ] **Step 1: Write failing adapter test**

Create `Tests/MeetingAgentCoreTests/WhisperAudioTranscriptionProviderTests.swift`:

```swift
import XCTest
@testable import MeetingAgentCore

final class WhisperAudioTranscriptionProviderTests: XCTestCase {
    func testDescriptorAdvertisesLocalAudioTranscription() {
        let provider = WhisperAudioTranscriptionProvider(speechProvider: StubSpeechTranscriptionProvider())

        XCTAssertEqual(provider.descriptor.id, "whisper-local")
        XCTAssertEqual(provider.descriptor.capability, .audioTranscription)
        XCTAssertEqual(provider.descriptor.executionMode, .local)
        XCTAssertFalse(provider.descriptor.requiresNetwork)
    }
}

private struct StubSpeechTranscriptionProvider: SpeechTranscriptionProvider {
    let provider: SpeechProvider = .whisper

    func start(transcriptURL: URL, localeIdentifier: String) async throws -> AudioFrameTranscriber {
        throw ProbeError.speechRecognition("not used")
    }

    func transcribeExistingAudio(context: SpeechTranscriptionContext) async throws {
        try "hello from whisper\n".write(to: context.transcriptURL, atomically: true, encoding: .utf8)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter WhisperAudioTranscriptionProviderTests`

Expected: build fails because `WhisperAudioTranscriptionProvider` does not exist.

- [ ] **Step 3: Implement the adapter**

Create `Sources/MeetingAgentCore/WhisperAudioTranscriptionProvider.swift`:

```swift
import Foundation

public struct WhisperAudioTranscriptionProvider: AudioTranscriptionProvider {
    public let descriptor = ProviderDescriptor(
        id: "whisper-local",
        displayName: "Whisper Local",
        capability: .audioTranscription,
        executionMode: .local,
        supportedSourceLocales: ["*"],
        supportedTargetLocales: [],
        requiresNetwork: false,
        requiresAPIKey: false
    )

    private let speechProvider: SpeechTranscriptionProvider
    private let fileManager: FileManager

    public init(
        speechProvider: SpeechTranscriptionProvider = WhisperSpeechTranscriptionProvider(),
        fileManager: FileManager = .default
    ) {
        self.speechProvider = speechProvider
        self.fileManager = fileManager
    }

    public func transcribe(audio: AudioInput, options: TranscriptionOptions) async throws -> TranscriptDocument {
        let transcriptURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        let context = SpeechTranscriptionContext(
            inputAudioURL: audio.wavURL,
            transcriptURL: transcriptURL,
            localeIdentifier: options.sourceLocale,
            meetingID: nil,
            previousTranscript: nil
        )
        try await speechProvider.transcribeExistingAudio(context: context)
        let rawText = try String(contentsOf: transcriptURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty else {
            return TranscriptDocument(segments: [])
        }
        return TranscriptDocument(segments: [
            TranscriptSegment(
                text: rawText,
                language: options.sourceLocale,
                sourceProvider: descriptor.id
            )
        ])
    }
}
```

- [ ] **Step 4: Add a test for transcribing an existing WAV URL**

Add to `WhisperAudioTranscriptionProviderTests`:

```swift
func testTranscribeExistingAudioReturnsTranscriptDocument() async throws {
    let provider = WhisperAudioTranscriptionProvider(speechProvider: StubSpeechTranscriptionProvider())

    let document = try await provider.transcribe(
        audio: AudioInput(wavURL: URL(fileURLWithPath: "/tmp/input.wav"), localeIdentifier: "en-US"),
        options: TranscriptionOptions(sourceLocale: "en-US")
    )

    XCTAssertEqual(document.segments.map(\.text), ["hello from whisper"])
    XCTAssertEqual(document.segments.first?.sourceProvider, "whisper-local")
}
```

- [ ] **Step 5: Run tests**

Run: `swift test --filter WhisperAudioTranscriptionProviderTests`

Expected: all adapter tests pass.

- [ ] **Step 6: Commit**

Run:

```bash
git add Sources/MeetingAgentCore/WhisperAudioTranscriptionProvider.swift Tests/MeetingAgentCoreTests/WhisperAudioTranscriptionProviderTests.swift
git commit -m "Adapt Whisper for bilingual transcription"
```

## Task 7: Bilingual Transcript Artifact Store

**Files:**
- Create: `Sources/MeetingAgentCore/BilingualTranscriptStore.swift`
- Test: `Tests/MeetingAgentCoreTests/BilingualTranscriptStoreTests.swift`

- [ ] **Step 1: Write failing store test**

Create `Tests/MeetingAgentCoreTests/BilingualTranscriptStoreTests.swift`:

```swift
import XCTest
@testable import MeetingAgentCore

final class BilingualTranscriptStoreTests: XCTestCase {
    func testWritesJSONAndTextArtifacts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = BilingualTranscriptStore(directoryURL: directory)
        let transcript = BilingualTranscript(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            segments: [
                BilingualSubtitleSegment(id: "segment-1", sourceText: "hello", targetText: "你好")
            ],
            provenance: PipelineProvenance(profileID: "profile")
        )

        let artifacts = try store.save(transcript)

        XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts.jsonURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts.textURL.path))
        XCTAssertEqual(try String(contentsOf: artifacts.textURL, encoding: .utf8), """
        User A:
        Source: hello
        Target: 你好
        """)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter BilingualTranscriptStoreTests`

Expected: build fails because `BilingualTranscriptStore` does not exist.

- [ ] **Step 3: Implement the store**

Create `Sources/MeetingAgentCore/BilingualTranscriptStore.swift`:

```swift
import Foundation

public struct BilingualTranscriptArtifacts: Equatable {
    public var jsonURL: URL
    public var textURL: URL
}

public struct BilingualTranscriptStore {
    private let directoryURL: URL
    private let fileManager: FileManager

    public init(directoryURL: URL, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
    }

    public func save(_ transcript: BilingualTranscript) throws -> BilingualTranscriptArtifacts {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let jsonURL = directoryURL.appendingPathComponent("bilingual-transcript.json")
        let textURL = directoryURL.appendingPathComponent("bilingual-transcript.txt")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(transcript).write(to: jsonURL, options: .atomic)
        try BilingualTranscriptFormatter.render(transcript).write(to: textURL, atomically: true, encoding: .utf8)

        return BilingualTranscriptArtifacts(jsonURL: jsonURL, textURL: textURL)
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter BilingualTranscriptStoreTests`

Expected: store tests pass.

- [ ] **Step 5: Commit**

Run:

```bash
git add Sources/MeetingAgentCore/BilingualTranscriptStore.swift Tests/MeetingAgentCoreTests/BilingualTranscriptStoreTests.swift
git commit -m "Add bilingual transcript artifact store"
```

## Task 8: Configuration And CLI Surface

**Files:**
- Modify: `Sources/MeetingAgentCore/SpeechTranscriptionConfiguration.swift`
- Modify: `Sources/MeetingAgentCore/ProbeOptions.swift`
- Modify: `Sources/CoreAudioTapProbe/ProbeMain.swift`
- Test: `Tests/MeetingAgentCoreTests/SpeechTranscriptionConfigurationTests.swift`
- Test: `Tests/MeetingAgentCoreTests/RecordingOutputTests.swift`

- [ ] **Step 1: Add failing configuration tests**

Add to `SpeechTranscriptionConfigurationTests`:

```swift
func testDefaultBilingualSettings() {
    let configuration = SpeechTranscriptionConfiguration.default

    XCTAssertEqual(configuration.targetLocaleIdentifier, "zh-CN")
    XCTAssertEqual(configuration.bilingualPipelineProfileID, "local-whisper-hosted-translation")
}
```

Add to `RecordingOutputTests`:

```swift
func testProbeOptionsAcceptBilingualTargetAndProfile() throws {
    let options = try ProbeOptions(arguments: [
        "--seconds", "5",
        "--wav",
        "--target-locale", "ja-JP",
        "--bilingual-profile", "local-whisper-local-translation"
    ])

    XCTAssertEqual(options.targetLocaleIdentifier, "ja-JP")
    XCTAssertEqual(options.bilingualPipelineProfileID, "local-whisper-local-translation")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SpeechTranscriptionConfigurationTests --filter RecordingOutputTests`

Expected: build or assertions fail because new configuration fields and CLI options do not exist.

- [ ] **Step 3: Add configuration fields**

Modify `SpeechTranscriptionConfiguration` to include:

```swift
public var targetLocaleIdentifier: String
public var bilingualPipelineProfileID: String
```

Default values:

```swift
targetLocaleIdentifier: "zh-CN",
bilingualPipelineProfileID: "local-whisper-hosted-translation"
```

Use existing normalization helpers for locale and profile strings:

```swift
self.targetLocaleIdentifier = Self.normalized(targetLocaleIdentifier, fallback: "zh-CN") ?? "zh-CN"
self.bilingualPipelineProfileID = Self.normalized(bilingualPipelineProfileID, fallback: "local-whisper-hosted-translation") ?? "local-whisper-hosted-translation"
```

- [ ] **Step 4: Add CLI parsing**

Modify `ProbeOptions` with:

```swift
public let targetLocaleIdentifier: String
public let bilingualPipelineProfileID: String
```

Parse:

```swift
case "--target-locale":
    targetLocaleIdentifier = try consumeValue(after: argument)
case "--bilingual-profile":
    bilingualPipelineProfileID = try consumeValue(after: argument)
```

Keep defaults:

```swift
var targetLocaleIdentifier = "zh-CN"
var bilingualPipelineProfileID = "local-whisper-hosted-translation"
```

Update `ProbeMain` usage text to include:

```text
[--target-locale zh-CN] [--bilingual-profile local-whisper-hosted-translation]
```

- [ ] **Step 5: Run focused tests**

Run: `swift test --filter SpeechTranscriptionConfigurationTests`

Expected: configuration tests pass.

Run: `swift test --filter RecordingOutputTests`

Expected: CLI option tests pass.

- [ ] **Step 6: Commit**

Run:

```bash
git add Sources/MeetingAgentCore/SpeechTranscriptionConfiguration.swift Sources/MeetingAgentCore/ProbeOptions.swift Sources/CoreAudioTapProbe/ProbeMain.swift Tests/MeetingAgentCoreTests/SpeechTranscriptionConfigurationTests.swift Tests/MeetingAgentCoreTests/RecordingOutputTests.swift
git commit -m "Add bilingual pipeline configuration"
```

## Task 9: Built-In Profiles And Pipeline Factory

**Files:**
- Create: `Sources/MeetingAgentCore/BilingualPipelineFactory.swift`
- Test: `Tests/MeetingAgentCoreTests/BilingualPipelineFactoryTests.swift`

- [ ] **Step 1: Write failing factory tests**

Create `Tests/MeetingAgentCoreTests/BilingualPipelineFactoryTests.swift`:

```swift
import XCTest
@testable import MeetingAgentCore

final class BilingualPipelineFactoryTests: XCTestCase {
    func testBuiltInProfilesIncludeInitialExperimentChains() {
        let profiles = BilingualPipelineFactory.builtInProfiles

        XCTAssertTrue(profiles.contains { $0.id == "local-whisper-hosted-translation" })
        XCTAssertTrue(profiles.contains { $0.id == "local-whisper-local-translation" })
        XCTAssertTrue(profiles.contains { $0.id == "hosted-transcribe-hosted-translation" })
    }

    func testBuiltInProviderDescriptorsIncludeWhisperAndTranslationPlaceholders() {
        let registry = BilingualPipelineFactory.builtInRegistry

        XCTAssertEqual(registry.descriptor(id: "whisper-local")?.capability, .audioTranscription)
        XCTAssertEqual(registry.descriptor(id: "openai-translation")?.capability, .textTranslation)
        XCTAssertEqual(registry.descriptor(id: "qwen-local-translation")?.capability, .textTranslation)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter BilingualPipelineFactoryTests`

Expected: build fails because `BilingualPipelineFactory` does not exist.

- [ ] **Step 3: Implement built-in descriptors and profiles**

Create `Sources/MeetingAgentCore/BilingualPipelineFactory.swift`:

```swift
import Foundation

public enum BilingualPipelineFactory {
    public static let builtInRegistry = ProviderRegistry(descriptors: builtInProviderDescriptors)

    public static let builtInProviderDescriptors: [ProviderDescriptor] = [
        ProviderDescriptor(id: "whisper-local", displayName: "Whisper Local", capability: .audioTranscription, executionMode: .local, supportedSourceLocales: ["*"], supportedTargetLocales: [], requiresNetwork: false, requiresAPIKey: false),
        ProviderDescriptor(id: "macos-speech-local", displayName: "macOS Speech", capability: .audioTranscription, executionMode: .local, supportedSourceLocales: ["*"], supportedTargetLocales: [], requiresNetwork: false, requiresAPIKey: false),
        ProviderDescriptor(id: "openai-transcribe", displayName: "OpenAI Transcribe", capability: .audioTranscription, executionMode: .hosted, supportedSourceLocales: ["*"], supportedTargetLocales: [], requiresNetwork: true, requiresAPIKey: true),
        ProviderDescriptor(id: "openai-translation", displayName: "OpenAI Translation", capability: .textTranslation, executionMode: .hosted, supportedSourceLocales: ["*"], supportedTargetLocales: ["*"], requiresNetwork: true, requiresAPIKey: true),
        ProviderDescriptor(id: "qwen-local-translation", displayName: "Qwen Local Translation", capability: .textTranslation, executionMode: .local, supportedSourceLocales: ["*"], supportedTargetLocales: ["*"], requiresNetwork: false, requiresAPIKey: false),
        ProviderDescriptor(id: "nllb-local", displayName: "NLLB Local", capability: .textTranslation, executionMode: .local, supportedSourceLocales: ["*"], supportedTargetLocales: ["*"], requiresNetwork: false, requiresAPIKey: false)
    ]

    public static let builtInProfiles: [BilingualPipelineProfile] = [
        BilingualPipelineProfile(id: "local-whisper-hosted-translation", displayName: "Local Whisper + Hosted Translation", steps: [
            PipelineStep(capability: .audioTranscription, primary: .provider("whisper-local"), fallbacks: [.provider("openai-transcribe")]),
            PipelineStep(capability: .textTranslation, primary: .provider("openai-translation"), fallbacks: [.provider("qwen-local-translation"), .provider("nllb-local")])
        ]),
        BilingualPipelineProfile(id: "local-whisper-local-translation", displayName: "Local Whisper + Local Translation", steps: [
            PipelineStep(capability: .audioTranscription, primary: .provider("whisper-local"), fallbacks: [.provider("macos-speech-local")]),
            PipelineStep(capability: .textTranslation, primary: .provider("qwen-local-translation"), fallbacks: [.provider("nllb-local")])
        ]),
        BilingualPipelineProfile(id: "hosted-transcribe-hosted-translation", displayName: "Hosted Transcribe + Hosted Translation", steps: [
            PipelineStep(capability: .audioTranscription, primary: .provider("openai-transcribe"), fallbacks: [.provider("whisper-local")]),
            PipelineStep(capability: .textTranslation, primary: .provider("openai-translation"))
        ])
    ]
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter BilingualPipelineFactoryTests`

Expected: factory tests pass.

- [ ] **Step 5: Commit**

Run:

```bash
git add Sources/MeetingAgentCore/BilingualPipelineFactory.swift Tests/MeetingAgentCoreTests/BilingualPipelineFactoryTests.swift
git commit -m "Add built-in bilingual pipeline profiles"
```

## Task 10: Final Verification

**Files:**
- No planned file edits.

- [ ] **Step 1: Run full test suite**

Run: `swift test`

Expected: all tests pass.

- [ ] **Step 2: Build app and CLI**

Run: `swift build --product MeetingAgentApp`

Expected: build succeeds.

Run: `swift build --product CoreAudioTapProbe`

Expected: build succeeds.

- [ ] **Step 3: Check worktree**

Run: `git status --short`

Expected: only intentional implementation changes are present, or the working tree is clean after task commits. Do not revert unrelated user-owned changes.

- [ ] **Step 4: Commit any missed implementation changes**

If `git status --short` shows intentional uncommitted files from this plan, commit them:

```bash
git add <intentional-files>
git commit -m "Complete bilingual subtitle pipeline foundation"
```

Do not add `.record/`, `.build/`, `.swiftpm/`, or unrelated files.

## Self-Review

- Spec coverage: the plan covers provider-neutral models, capability descriptors, registry, profiles, fallback orchestration, direct-provider profile fallback, Whisper adaptation, bilingual artifacts, configuration, built-in profiles, and tests.
- Scope control: the plan does not implement real hosted OpenAI, Qwen, or NLLB providers. It creates descriptors and chain slots for them, matching the spec's experimentation-first scope.
- Placeholder scan: no task depends on unspecified follow-up work or vague "add tests" instructions.
- Type consistency: provider capability names, profile IDs, and bilingual segment fields match across tasks.
