# OpenRouter Bilingual Providers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement OpenRouter-backed hosted transcription and hosted translation providers with step-level model configuration and cascading picker-only settings.

**Architecture:** Extract the existing OpenRouter chat-completions HTTP code into a reusable core client, then build `AudioTranscriptionProvider` and `TextTranslationProvider` implementations on top of it. Extend persisted speech configuration with local/hosted step settings while preserving old config decoding, and update `SettingsView` to expose dependent picker controls.

**Tech Stack:** Swift 5.9, SwiftUI, XCTest, Swift Package Manager, URLSession.

---

## File Map

- Create `Sources/MeetingAgentCore/OpenRouterChatClient.swift`: shared OpenRouter chat DTOs, configuration, protocol, and URLSession client.
- Create `Sources/MeetingAgentCore/OpenRouterBilingualProviders.swift`: `OpenRouterAudioTranscriptionProvider`, `OpenRouterTextTranslationProvider`, response payload DTOs, prompt builders.
- Modify `Sources/MeetingAgentCore/OpenRouterMeetingSummaryProvider.swift`: remove duplicate HTTP client code and use `OpenRouterChatClient`.
- Modify `Sources/MeetingAgentCore/SpeechTranscriptionConfiguration.swift`: add step-level provider/model fields, defaults, decoding compatibility, and hosted validation.
- Modify `Sources/MeetingAgentCore/BilingualPipelineFactory.swift`: replace hosted placeholder IDs with OpenRouter IDs and add model option descriptors.
- Modify `Sources/MeetingAgentCore/WhisperAudioTranscriptionProvider.swift`: allow configuration injection so local model path settings are reused.
- Modify `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`: persist new config fields and expose validation.
- Modify `Sources/MeetingAgentApp/SettingsView.swift`: replace flat STT/provider controls with cascading picker sections.
- Test `Tests/MeetingAgentCoreTests/OpenRouterBilingualProviderTests.swift`: new hosted provider tests.
- Modify `Tests/MeetingAgentCoreTests/MeetingSummaryProviderTests.swift`: summary provider still works with shared client.
- Modify `Tests/MeetingAgentCoreTests/SpeechTranscriptionConfigurationTests.swift`: new field round-trip and validation tests.
- Modify `Tests/MeetingAgentCoreTests/BilingualPipelineFactoryTests.swift`: OpenRouter descriptor/profile assertions.
- Modify `Tests/MeetingAgentCoreTests/SettingsViewLayoutTests.swift`: cascading picker assertions.

---

### Task 1: Extract Shared OpenRouter Chat Client

**Files:**
- Create: `Sources/MeetingAgentCore/OpenRouterChatClient.swift`
- Modify: `Sources/MeetingAgentCore/OpenRouterMeetingSummaryProvider.swift`
- Modify: `Tests/MeetingAgentCoreTests/MeetingSummaryProviderTests.swift`

- [ ] **Step 1: Write failing summary compatibility test**

In `Tests/MeetingAgentCoreTests/MeetingSummaryProviderTests.swift`, rename the fake client to conform to the new protocol:

```swift
private final class RecordingOpenRouterChatClient: OpenRouterChatClient {
    struct Request: Equatable {
        let apiKey: String
        let model: String
        let messages: [OpenRouterChatMessage]
        let responseFormat: OpenRouterResponseFormat?
    }

    private(set) var requests: [Request] = []
    private let responseContent: String

    init(responseContent: String) {
        self.responseContent = responseContent
    }

    func complete(configuration: OpenRouterChatConfiguration, messages: [OpenRouterChatMessage], responseFormat: OpenRouterResponseFormat?) async throws -> String {
        requests.append(Request(
            apiKey: configuration.apiKey,
            model: configuration.model,
            messages: messages,
            responseFormat: responseFormat
        ))
        return responseContent
    }
}
```

Update summary tests to initialize:

```swift
let client = RecordingOpenRouterChatClient(responseContent: """
...
""")
let provider = OpenRouterMeetingSummaryProvider(
    configuration: OpenRouterChatConfiguration(apiKey: "test-key", model: "openai/gpt-4.1-mini"),
    client: client
)
```

Assert:

```swift
XCTAssertEqual(client.requests.first?.apiKey, "test-key")
XCTAssertEqual(client.requests.first?.model, "openai/gpt-4.1-mini")
XCTAssertEqual(client.requests.first?.responseFormat?.type, "json_object")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MeetingSummaryProviderTests/testOpenRouterProviderBuildsRequestAndParsesSummary`

Expected: FAIL because `OpenRouterChatClient`, `OpenRouterChatConfiguration`, and public `OpenRouterResponseFormat` do not exist.

- [ ] **Step 3: Add shared client**

Create `Sources/MeetingAgentCore/OpenRouterChatClient.swift`:

```swift
import Foundation

public struct OpenRouterChatMessage: Codable, Equatable {
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

public struct OpenRouterResponseFormat: Codable, Equatable {
    public let type: String

    public init(type: String) {
        self.type = type
    }
}

public enum OpenRouterChatConfiguration: Equatable {
    case available(apiKey: String, model: String)
    case unavailable(String)

    public var apiKey: String {
        if case .available(let apiKey, _) = self { return apiKey }
        return ""
    }

    public var model: String {
        if case .available(_, let model) = self { return model }
        return ""
    }

    public init(apiKey: String?, model: String?) {
        guard let apiKey = Self.normalized(apiKey) else {
            self = .unavailable("OpenRouter API key is not configured")
            return
        }
        guard let model = Self.normalized(model) else {
            self = .unavailable("OpenRouter model is not configured")
            return
        }
        self = .available(apiKey: apiKey, model: model)
    }

    public static func environment(
        model: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Self {
        OpenRouterChatConfiguration(
            apiKey: environment["MEETING_AGENT_OPENROUTER_API_KEY"],
            model: model
        )
    }

    static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.flatMap { $0.isEmpty ? nil : $0 }
    }
}

public protocol OpenRouterChatClient {
    func complete(
        configuration: OpenRouterChatConfiguration,
        messages: [OpenRouterChatMessage],
        responseFormat: OpenRouterResponseFormat?
    ) async throws -> String
}

public final class URLSessionOpenRouterChatClient: OpenRouterChatClient {
    private let endpointURL: URL
    private let session: URLSession

    public init(
        endpointURL: URL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
        session: URLSession = .shared
    ) {
        self.endpointURL = endpointURL
        self.session = session
    }

    public func complete(
        configuration: OpenRouterChatConfiguration,
        messages: [OpenRouterChatMessage],
        responseFormat: OpenRouterResponseFormat?
    ) async throws -> String {
        guard case .available(let apiKey, let model) = configuration else {
            throw OpenRouterChatError.unavailable("OpenRouter configuration is unavailable")
        }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder.meetingAgent.encode(OpenRouterChatCompletionRequest(
            model: model,
            messages: messages,
            temperature: 0.2,
            responseFormat: responseFormat
        ))

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenRouterChatError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw OpenRouterChatError.httpStatus(httpResponse.statusCode, String(data: data, encoding: .utf8))
        }
        let completion = try JSONDecoder.meetingAgent.decode(OpenRouterChatCompletionResponse.self, from: data)
        guard let content = completion.choices.first?.message.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw OpenRouterChatError.emptyContent
        }
        return content
    }
}

private struct OpenRouterChatCompletionRequest: Encodable {
    let model: String
    let messages: [OpenRouterChatMessage]
    let temperature: Double
    let responseFormat: OpenRouterResponseFormat?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case responseFormat = "response_format"
    }
}

private struct OpenRouterChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String
        }

        let message: Message
    }

    let choices: [Choice]
}

public enum OpenRouterChatError: Error, CustomStringConvertible {
    case unavailable(String)
    case invalidResponse
    case httpStatus(Int, String?)
    case emptyContent
    case invalidJSONContent

    public var description: String {
        switch self {
        case .unavailable(let reason):
            return reason
        case .invalidResponse:
            return "invalid HTTP response"
        case .httpStatus(let statusCode, let body):
            let detail = body?.trimmingCharacters(in: .whitespacesAndNewlines)
            return "HTTP \(statusCode)\(detail.map { ": \($0)" } ?? "")"
        case .emptyContent:
            return "response content was empty"
        case .invalidJSONContent:
            return "response content did not contain a JSON object"
        }
    }
}
```

- [ ] **Step 4: Migrate summary provider**

In `Sources/MeetingAgentCore/OpenRouterMeetingSummaryProvider.swift`, remove duplicate `OpenRouterChatMessage`, `OpenRouterSummaryConfiguration`, `OpenRouterSummaryClient`, `URLSessionOpenRouterSummaryClient`, response request DTOs, and summary-specific error enum. Change provider properties to:

```swift
private let configuration: OpenRouterChatConfiguration
private let client: OpenRouterChatClient
```

Change initializer:

```swift
public init(
    configuration: OpenRouterChatConfiguration = .environment(
        model: ProcessInfo.processInfo.environment["MEETING_AGENT_OPENROUTER_MODEL"]
    ),
    client: OpenRouterChatClient = URLSessionOpenRouterChatClient()
) {
    self.configuration = configuration
    self.client = client
}
```

Change `generateSummary` call:

```swift
let content = try await client.complete(
    configuration: configuration,
    messages: Self.messages(for: input),
    responseFormat: OpenRouterResponseFormat(type: "json_object")
)
```

Change unavailable branch to:

```swift
case .unavailable(let reason):
    return failedSummary(input: input, sourceSegmentIDs: sourceSegmentIDs, reason: reason)
```

Change JSON extraction errors to throw `OpenRouterChatError.invalidJSONContent`.

- [ ] **Step 5: Run tests**

Run: `swift test --filter MeetingSummaryProviderTests`

Expected: PASS.

- [ ] **Step 6: Commit**

Run:

```bash
git add Sources/MeetingAgentCore/OpenRouterChatClient.swift Sources/MeetingAgentCore/OpenRouterMeetingSummaryProvider.swift Tests/MeetingAgentCoreTests/MeetingSummaryProviderTests.swift
git commit -m "Extract shared OpenRouter chat client"
```

---

### Task 2: Extend Speech Configuration for Cascading Step Settings

**Files:**
- Modify: `Sources/MeetingAgentCore/SpeechTranscriptionConfiguration.swift`
- Test: `Tests/MeetingAgentCoreTests/SpeechTranscriptionConfigurationTests.swift`

- [ ] **Step 1: Write failing configuration tests**

Add tests:

```swift
func testConfigurationRoundTripsStepLevelProviderAndModelSettings() throws {
    let store = SpeechTranscriptionConfigurationStore(userDefaults: isolatedUserDefaults())
    let configuration = SpeechTranscriptionConfiguration(
        provider: .whisper,
        localeIdentifier: "en-US",
        targetLocaleIdentifier: "zh-CN",
        bilingualPipelineProfileID: "hosted-transcribe-hosted-translation",
        whisperBinaryPath: "/opt/homebrew/bin/whisper-cli",
        whisperModelPath: "/Users/allan/models/ggml-small.bin",
        transcriptionExecutionMode: .hosted,
        translationExecutionMode: .hosted,
        localTranscriptionProviderID: "whisper-local",
        localTranslationProviderID: "qwen-local-translation",
        hostedTranscriptionProviderID: "openrouter-transcribe",
        hostedTranslationProviderID: "openrouter-translation",
        hostedTranscriptionModelID: "google/gemini-2.5-flash",
        hostedTranslationModelID: "openai/gpt-4.1-mini"
    )

    try store.save(configuration)

    XCTAssertEqual(try store.load(), configuration)
}

func testHostedValidationRequiresOpenRouterAPIKeyAndModels() {
    let missingKey = SpeechTranscriptionConfiguration(
        provider: .whisper,
        localeIdentifier: "en-US",
        whisperBinaryPath: nil,
        whisperModelPath: nil,
        transcriptionExecutionMode: .hosted,
        translationExecutionMode: .hosted,
        hostedTranscriptionModelID: "google/gemini-2.5-flash",
        hostedTranslationModelID: "openai/gpt-4.1-mini"
    )

    XCTAssertEqual(
        missingKey.validationStatus(environment: [:]),
        .unavailable("OpenRouter API key is not configured")
    )
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter SpeechTranscriptionConfigurationTests`

Expected: FAIL because new fields and `ProviderExecutionMode` configuration properties do not exist.

- [ ] **Step 3: Add configuration fields**

Update `SpeechTranscriptionConfiguration` fields:

```swift
public var transcriptionExecutionMode: ProviderExecutionMode
public var translationExecutionMode: ProviderExecutionMode
public var localTranscriptionProviderID: String
public var localTranslationProviderID: String
public var hostedTranscriptionProviderID: String
public var hostedTranslationProviderID: String
public var hostedTranscriptionModelID: String
public var hostedTranslationModelID: String
```

Add defaults:

```swift
transcriptionExecutionMode: .local,
translationExecutionMode: .hosted,
localTranscriptionProviderID: "whisper-local",
localTranslationProviderID: "qwen-local-translation",
hostedTranscriptionProviderID: "openrouter-transcribe",
hostedTranslationProviderID: "openrouter-translation",
hostedTranscriptionModelID: "google/gemini-2.5-flash",
hostedTranslationModelID: "openai/gpt-4.1-mini"
```

Extend initializer with defaulted parameters for the new fields and normalize string IDs with safe fallbacks.

Extend `CodingKeys` and decoder using `decodeIfPresent`, falling back to the defaults above.

- [ ] **Step 4: Update validation**

In `validationStatus`, before local Whisper validation, add hosted checks:

```swift
if transcriptionExecutionMode == .hosted || translationExecutionMode == .hosted {
    guard SpeechTranscriptionConfiguration.normalized(environment["MEETING_AGENT_OPENROUTER_API_KEY"]) != nil else {
        return .unavailable("OpenRouter API key is not configured")
    }
}
if transcriptionExecutionMode == .hosted,
   SpeechTranscriptionConfiguration.normalized(hostedTranscriptionModelID) == nil {
    return .unavailable("Hosted transcription model is not configured")
}
if translationExecutionMode == .hosted,
   SpeechTranscriptionConfiguration.normalized(hostedTranslationModelID) == nil {
    return .unavailable("Hosted translation model is not configured")
}
```

Keep Whisper path validation only when `provider == .whisper && transcriptionExecutionMode == .local && localTranscriptionProviderID == "whisper-local"`.

- [ ] **Step 5: Run tests**

Run: `swift test --filter SpeechTranscriptionConfigurationTests`

Expected: PASS.

- [ ] **Step 6: Commit**

Run:

```bash
git add Sources/MeetingAgentCore/SpeechTranscriptionConfiguration.swift Tests/MeetingAgentCoreTests/SpeechTranscriptionConfigurationTests.swift
git commit -m "Add step-level speech configuration"
```

---

### Task 3: Add OpenRouter Hosted Bilingual Providers

**Files:**
- Create: `Sources/MeetingAgentCore/OpenRouterBilingualProviders.swift`
- Test: `Tests/MeetingAgentCoreTests/OpenRouterBilingualProviderTests.swift`

- [ ] **Step 1: Write failing provider tests**

Create `Tests/MeetingAgentCoreTests/OpenRouterBilingualProviderTests.swift`:

```swift
import XCTest
@testable import MeetingAgentCore

final class OpenRouterBilingualProviderTests: XCTestCase {
    func testTranslationProviderUsesConfiguredModelAndMapsSegments() async throws {
        let client = RecordingOpenRouterChatClient(responseContent: """
        {
          "segments": [
            { "id": "segment-1", "targetText": "你好" }
          ]
        }
        """)
        let provider = OpenRouterTextTranslationProvider(
            configuration: OpenRouterChatConfiguration(apiKey: "key", model: "openai/gpt-4.1-mini"),
            client: client
        )
        let transcript = TranscriptDocument(segments: [
            TranscriptSegment(id: "segment-1", startTimeSeconds: 1, endTimeSeconds: 2, text: "hello", language: "en-US", sourceProvider: "whisper-local")
        ])

        let output = try await provider.translate(
            transcript: transcript,
            options: TranslationOptions(sourceLocale: "en-US", targetLocale: "zh-CN")
        )

        XCTAssertEqual(client.requests.first?.model, "openai/gpt-4.1-mini")
        XCTAssertEqual(output.segments.first?.id, "segment-1")
        XCTAssertEqual(output.segments.first?.sourceText, "hello")
        XCTAssertEqual(output.segments.first?.targetText, "你好")
        XCTAssertEqual(output.segments.first?.providerChain, ["openrouter-translation"])
    }

    func testTranscriptionProviderUsesConfiguredModelAndMapsSegments() async throws {
        let client = RecordingOpenRouterChatClient(responseContent: """
        {
          "segments": [
            { "id": "segment-1", "text": "hello", "language": "en-US", "startTimeSeconds": 0.0, "endTimeSeconds": 1.2 }
          ]
        }
        """)
        let provider = OpenRouterAudioTranscriptionProvider(
            configuration: OpenRouterChatConfiguration(apiKey: "key", model: "google/gemini-2.5-flash"),
            client: client
        )
        let wavURL = URL(fileURLWithPath: "/tmp/capture.wav")

        let output = try await provider.transcribe(
            audio: AudioInput(wavURL: wavURL, localeIdentifier: "en-US"),
            options: TranscriptionOptions(sourceLocale: "en-US")
        )

        XCTAssertEqual(client.requests.first?.model, "google/gemini-2.5-flash")
        XCTAssertEqual(output.segments.first?.id, "segment-1")
        XCTAssertEqual(output.segments.first?.text, "hello")
        XCTAssertEqual(output.segments.first?.sourceProvider, "openrouter-transcribe")
    }
}

private final class RecordingOpenRouterChatClient: OpenRouterChatClient {
    struct Request: Equatable {
        let model: String
        let messages: [OpenRouterChatMessage]
    }

    private(set) var requests: [Request] = []
    private let responseContent: String

    init(responseContent: String) {
        self.responseContent = responseContent
    }

    func complete(configuration: OpenRouterChatConfiguration, messages: [OpenRouterChatMessage], responseFormat: OpenRouterResponseFormat?) async throws -> String {
        requests.append(Request(model: configuration.model, messages: messages))
        return responseContent
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter OpenRouterBilingualProviderTests`

Expected: FAIL because provider types do not exist.

- [ ] **Step 3: Implement hosted providers**

Create `Sources/MeetingAgentCore/OpenRouterBilingualProviders.swift`:

```swift
import Foundation

public struct OpenRouterAudioTranscriptionProvider: AudioTranscriptionProvider {
    public let descriptor = ProviderDescriptor(
        id: "openrouter-transcribe",
        displayName: "OpenRouter Transcribe",
        capability: .audioTranscription,
        executionMode: .hosted,
        supportedSourceLocales: ["*"],
        supportedTargetLocales: [],
        requiresNetwork: true,
        requiresAPIKey: true
    )

    private let configuration: OpenRouterChatConfiguration
    private let client: OpenRouterChatClient

    public init(configuration: OpenRouterChatConfiguration, client: OpenRouterChatClient = URLSessionOpenRouterChatClient()) {
        self.configuration = configuration
        self.client = client
    }

    public func transcribe(audio: AudioInput, options: TranscriptionOptions) async throws -> TranscriptDocument {
        guard let wavURL = audio.wavURL else {
            throw OpenRouterChatError.unavailable("OpenRouter transcription requires a WAV file URL")
        }
        let content = try await client.complete(
            configuration: configuration,
            messages: Self.messages(wavURL: wavURL, sourceLocale: options.sourceLocale),
            responseFormat: OpenRouterResponseFormat(type: "json_object")
        )
        let payload = try Self.decodePayload(from: content)
        return TranscriptDocument(segments: payload.segments.map {
            TranscriptSegment(
                id: SpeechTranscriptionConfiguration.normalized($0.id) ?? UUID().uuidString,
                speaker: TranscriptSpeaker(identifier: $0.speakerID, label: $0.speakerLabel),
                startTimeSeconds: $0.startTimeSeconds,
                endTimeSeconds: $0.endTimeSeconds,
                text: $0.text,
                language: SpeechTranscriptionConfiguration.normalized($0.language) ?? options.sourceLocale,
                sourceProvider: descriptor.id,
                confidence: $0.confidence,
                timingSource: ($0.startTimeSeconds == nil && $0.endTimeSeconds == nil) ? .unavailable : .approximate
            )
        })
    }

    private static func messages(wavURL: URL, sourceLocale: String) -> [OpenRouterChatMessage] {
        [
            OpenRouterChatMessage(role: "system", content: "Transcribe meeting audio. Return only JSON with a segments array. Preserve timing, speaker, language, and confidence when available."),
            OpenRouterChatMessage(role: "user", content: "Audio file URL: \(wavURL.path)\nSource locale: \(sourceLocale)")
        ]
    }

    private static func decodePayload(from content: String) throws -> OpenRouterTranscriptionPayload {
        let json = try extractJSONObject(from: content)
        return try JSONDecoder.meetingAgent.decode(OpenRouterTranscriptionPayload.self, from: Data(json.utf8))
    }
}

public struct OpenRouterTextTranslationProvider: TextTranslationProvider {
    public let descriptor = ProviderDescriptor(
        id: "openrouter-translation",
        displayName: "OpenRouter Translation",
        capability: .textTranslation,
        executionMode: .hosted,
        supportedSourceLocales: ["*"],
        supportedTargetLocales: ["*"],
        requiresNetwork: true,
        requiresAPIKey: true
    )

    private let configuration: OpenRouterChatConfiguration
    private let client: OpenRouterChatClient

    public init(configuration: OpenRouterChatConfiguration, client: OpenRouterChatClient = URLSessionOpenRouterChatClient()) {
        self.configuration = configuration
        self.client = client
    }

    public func translate(transcript: TranscriptDocument, options: TranslationOptions) async throws -> TranslatedTranscript {
        let content = try await client.complete(
            configuration: configuration,
            messages: Self.messages(transcript: transcript, options: options),
            responseFormat: OpenRouterResponseFormat(type: "json_object")
        )
        let payload = try Self.decodePayload(from: content)
        let translationsByID = Dictionary(uniqueKeysWithValues: payload.segments.map { ($0.id, $0.targetText) })
        let segments = transcript.segments.map { segment -> BilingualSubtitleSegment in
            let target = translationsByID[segment.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return BilingualSubtitleSegment(
                id: segment.id,
                startTimeSeconds: segment.startTimeSeconds,
                endTimeSeconds: segment.endTimeSeconds,
                speaker: segment.speaker,
                sourceText: segment.text,
                targetText: target,
                confidence: segment.confidence,
                status: target.isEmpty ? .sourceOnly : .complete,
                errorMessage: target.isEmpty ? "OpenRouter response did not include a translation for segment \(segment.id)" : nil,
                providerChain: [descriptor.id]
            )
        }
        return TranslatedTranscript(
            sourceLocale: options.sourceLocale,
            targetLocale: options.targetLocale,
            segments: segments,
            provenance: PipelineProvenance(profileID: descriptor.id, successfulProviders: [descriptor.id])
        )
    }

    private static func messages(transcript: TranscriptDocument, options: TranslationOptions) -> [OpenRouterChatMessage] {
        let payload = transcript.segments.map { segment in
            "- id: \(segment.id)\n  text: \(segment.text)"
        }.joined(separator: "\n")
        return [
            OpenRouterChatMessage(role: "system", content: "Translate meeting transcript segments. Return only JSON with segments: [{id, targetText}]. Preserve IDs exactly."),
            OpenRouterChatMessage(role: "user", content: "Source locale: \(options.sourceLocale)\nTarget locale: \(options.targetLocale)\nSegments:\n\(payload)")
        ]
    }

    private static func decodePayload(from content: String) throws -> OpenRouterTranslationPayload {
        let json = try extractJSONObject(from: content)
        return try JSONDecoder.meetingAgent.decode(OpenRouterTranslationPayload.self, from: Data(json.utf8))
    }
}

private struct OpenRouterTranscriptionPayload: Decodable {
    let segments: [Segment]

    struct Segment: Decodable {
        let id: String?
        let startTimeSeconds: Double?
        let endTimeSeconds: Double?
        let speakerID: String?
        let speakerLabel: String?
        let text: String
        let language: String?
        let confidence: Double?
    }
}

private struct OpenRouterTranslationPayload: Decodable {
    let segments: [Segment]

    struct Segment: Decodable {
        let id: String
        let targetText: String
    }
}

private func extractJSONObject(from content: String) throws -> String {
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let start = trimmed.firstIndex(of: "{"),
          let end = trimmed.lastIndex(of: "}"),
          start <= end
    else {
        throw OpenRouterChatError.invalidJSONContent
    }
    return String(trimmed[start...end])
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter OpenRouterBilingualProviderTests`

Expected: PASS.

- [ ] **Step 5: Commit**

Run:

```bash
git add Sources/MeetingAgentCore/OpenRouterBilingualProviders.swift Tests/MeetingAgentCoreTests/OpenRouterBilingualProviderTests.swift
git commit -m "Add OpenRouter bilingual providers"
```

---

### Task 4: Update Pipeline Factory and Provider Construction Hooks

**Files:**
- Modify: `Sources/MeetingAgentCore/BilingualPipelineFactory.swift`
- Modify: `Sources/MeetingAgentCore/WhisperAudioTranscriptionProvider.swift`
- Test: `Tests/MeetingAgentCoreTests/BilingualPipelineFactoryTests.swift`

- [ ] **Step 1: Write failing factory tests**

Add assertions:

```swift
func testBuiltInProfilesUseOpenRouterHostedProviderIDs() {
    let ids = BilingualPipelineFactory.builtInProviderDescriptors.map(\.id)

    XCTAssertTrue(ids.contains("openrouter-transcribe"))
    XCTAssertTrue(ids.contains("openrouter-translation"))
    XCTAssertFalse(ids.contains("openai-transcribe"))
    XCTAssertFalse(ids.contains("openai-translation"))
}

func testBuiltInModelOptionsContainSeparateHostedTranscriptionAndTranslationModels() {
    XCTAssertTrue(BilingualPipelineFactory.hostedTranscriptionModelOptions.contains { $0.id == "google/gemini-2.5-flash" })
    XCTAssertTrue(BilingualPipelineFactory.hostedTranslationModelOptions.contains { $0.id == "openai/gpt-4.1-mini" })
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter BilingualPipelineFactoryTests`

Expected: FAIL because IDs and model options are not updated.

- [ ] **Step 3: Update factory descriptors and profiles**

In `BilingualPipelineFactory`, replace `openai-transcribe` with `openrouter-transcribe` and `openai-translation` with `openrouter-translation`.

Add:

```swift
public struct ModelOption: Codable, Equatable, Identifiable {
    public var id: String
    public var displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

public static let hostedTranscriptionModelOptions: [ModelOption] = [
    ModelOption(id: "google/gemini-2.5-flash", displayName: "Gemini 2.5 Flash"),
    ModelOption(id: "openai/gpt-4o-mini-transcribe", displayName: "GPT-4o Mini Transcribe")
]

public static let hostedTranslationModelOptions: [ModelOption] = [
    ModelOption(id: "openai/gpt-4.1-mini", displayName: "GPT-4.1 Mini"),
    ModelOption(id: "google/gemini-2.5-flash", displayName: "Gemini 2.5 Flash")
]
```

- [ ] **Step 4: Allow Whisper audio provider to reuse config**

Change `WhisperAudioTranscriptionProvider` init default:

```swift
public init(
    configuration: SpeechTranscriptionConfiguration = .default,
    speechProvider: SpeechTranscriptionProvider? = nil,
    fileManager: FileManager = .default
) {
    self.speechProvider = speechProvider ?? SpeechTranscriptionProviderFactory.provider(for: .whisper, configuration: configuration)
    self.fileManager = fileManager
}
```

- [ ] **Step 5: Run tests**

Run: `swift test --filter BilingualPipelineFactoryTests`

Expected: PASS.

- [ ] **Step 6: Commit**

Run:

```bash
git add Sources/MeetingAgentCore/BilingualPipelineFactory.swift Sources/MeetingAgentCore/WhisperAudioTranscriptionProvider.swift Tests/MeetingAgentCoreTests/BilingualPipelineFactoryTests.swift
git commit -m "Register OpenRouter bilingual pipeline options"
```

---

### Task 5: Update Settings UI to Cascading Pickers

**Files:**
- Modify: `Sources/MeetingAgentApp/SettingsView.swift`
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Test: `Tests/MeetingAgentCoreTests/SettingsViewLayoutTests.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] **Step 1: Write failing SettingsView tests**

Update `testSettingsViewUsesPickersForAllEditableFields` to assert:

```swift
XCTAssertTrue(source.contains("Picker(\"Transcription Mode\""))
XCTAssertTrue(source.contains("Picker(\"Local Transcription Provider\""))
XCTAssertTrue(source.contains("Picker(\"Hosted Transcription Provider\""))
XCTAssertTrue(source.contains("Picker(\"Hosted Transcription Model\""))
XCTAssertTrue(source.contains("Picker(\"Translation Mode\""))
XCTAssertTrue(source.contains("Picker(\"Local Translation Provider\""))
XCTAssertTrue(source.contains("Picker(\"Hosted Translation Provider\""))
XCTAssertTrue(source.contains("Picker(\"Hosted Translation Model\""))
XCTAssertFalse(source.contains("TextField("))
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter SettingsViewLayoutTests`

Expected: FAIL because cascading picker labels do not exist.

- [ ] **Step 3: Update view model save path**

In `MeetingAgentViewModel.saveSpeechConfiguration`, pass all new fields through:

```swift
speechConfiguration = SpeechTranscriptionConfiguration(
    provider: configuration.provider,
    localeIdentifier: configuration.localeIdentifier,
    targetLocaleIdentifier: configuration.targetLocaleIdentifier,
    bilingualPipelineProfileID: configuration.bilingualPipelineProfileID,
    whisperBinaryPath: configuration.whisperBinaryPath,
    whisperModelPath: configuration.whisperModelPath,
    transcriptionExecutionMode: configuration.transcriptionExecutionMode,
    translationExecutionMode: configuration.translationExecutionMode,
    localTranscriptionProviderID: configuration.localTranscriptionProviderID,
    localTranslationProviderID: configuration.localTranslationProviderID,
    hostedTranscriptionProviderID: configuration.hostedTranscriptionProviderID,
    hostedTranslationProviderID: configuration.hostedTranslationProviderID,
    hostedTranscriptionModelID: configuration.hostedTranscriptionModelID,
    hostedTranslationModelID: configuration.hostedTranslationModelID
)
```

- [ ] **Step 4: Update SettingsView sections**

Replace flat `STT Provider` and `Whisper` sections with:

```swift
Section("Speech") {
    Picker("Source Locale", selection: $draft.localeIdentifier) { ... }
    Picker("Target Locale", selection: $draft.targetLocaleIdentifier) { ... }
}

Section("Transcription Chain") {
    Picker("Transcription Mode", selection: $draft.transcriptionExecutionMode) {
        Text("Local").tag(ProviderExecutionMode.local)
        Text("Hosted").tag(ProviderExecutionMode.hosted)
    }

    if draft.transcriptionExecutionMode == .local {
        Picker("Local Transcription Provider", selection: $draft.localTranscriptionProviderID) {
            Text("Whisper Local").tag("whisper-local")
            Text("macOS Speech").tag("macos-speech-local")
        }
        if draft.localTranscriptionProviderID == "whisper-local" {
            Picker("Whisper Binary Path", selection: whisperBinaryPathBinding) { ... }
            Picker("Whisper Model Path", selection: whisperModelPathBinding) { ... }
        }
    } else {
        Picker("Hosted Transcription Provider", selection: $draft.hostedTranscriptionProviderID) {
            Text("OpenRouter").tag("openrouter-transcribe")
        }
        Picker("Hosted Transcription Model", selection: $draft.hostedTranscriptionModelID) {
            ForEach(BilingualPipelineFactory.hostedTranscriptionModelOptions) { model in
                Text(model.displayName).tag(model.id)
            }
        }
    }
}

Section("Translation Chain") {
    Picker("Translation Mode", selection: $draft.translationExecutionMode) {
        Text("Local").tag(ProviderExecutionMode.local)
        Text("Hosted").tag(ProviderExecutionMode.hosted)
    }

    if draft.translationExecutionMode == .local {
        Picker("Local Translation Provider", selection: $draft.localTranslationProviderID) {
            Text("Qwen Local Translation").tag("qwen-local-translation")
            Text("NLLB Local").tag("nllb-local")
        }
    } else {
        Picker("Hosted Translation Provider", selection: $draft.hostedTranslationProviderID) {
            Text("OpenRouter").tag("openrouter-translation")
        }
        Picker("Hosted Translation Model", selection: $draft.hostedTranslationModelID) {
            ForEach(BilingualPipelineFactory.hostedTranslationModelOptions) { model in
                Text(model.displayName).tag(model.id)
            }
        }
    }
}
```

Keep `Bilingual Pipeline Profile` section for now.

- [ ] **Step 5: Keep legacy provider coherent**

Add an `.onChange(of: draft.localTranscriptionProviderID)` block:

```swift
.onChange(of: draft.localTranscriptionProviderID) { _, providerID in
    draft.provider = providerID == "macos-speech-local" ? .local : .whisper
}
```

Add `.onChange` handlers for execution mode to select default provider/model when hosted is selected.

- [ ] **Step 6: Run tests**

Run:

```bash
swift test --filter SettingsViewLayoutTests
swift test --filter MeetingAgentViewModelTests/testSaveSpeechConfigurationPersistsBilingualSettings
```

Expected: PASS.

- [ ] **Step 7: Commit**

Run:

```bash
git add Sources/MeetingAgentApp/SettingsView.swift Sources/MeetingAgentCore/MeetingAgentViewModel.swift Tests/MeetingAgentCoreTests/SettingsViewLayoutTests.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift
git commit -m "Add cascading bilingual settings controls"
```

---

### Task 6: Final Integration Verification

**Files:**
- All modified files from prior tasks.

- [ ] **Step 1: Run focused tests**

Run:

```bash
swift test --filter OpenRouterBilingualProviderTests
swift test --filter SpeechTranscriptionConfigurationTests
swift test --filter SettingsViewLayoutTests
swift test --filter BilingualPipelineFactoryTests
swift test --filter MeetingSummaryProviderTests
```

Expected: all PASS.

- [ ] **Step 2: Run app build**

Run: `swift build --product MeetingAgentApp`

Expected: build completes successfully.

- [ ] **Step 3: Run full test suite**

Run: `swift test`

Expected: all tests PASS.

- [ ] **Step 4: Check git status**

Run: `git status --short`

Expected: only known unrelated untracked `.roadmap/` remains.

- [ ] **Step 5: Final commit if verification required changes**

If any verification fixes were needed:

```bash
git add <fixed files>
git commit -m "Stabilize OpenRouter bilingual providers"
```

If no fixes were needed, do not create an empty commit.
