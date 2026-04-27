# Reliable MVP Primary Chain Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Phase 1 of the reliable MVP: a WAV-first primary chain with Deepgram Nova-3 as the default STT provider, OpenAI Realtime transcription as a selectable STT provider, Local Whisper as fallback, Keychain-backed API keys, and retryable translation/summary inputs.

**Architecture:** Keep `MeetingRecorder` responsible for capture and WAV persistence, but route transcription through a narrower provider abstraction that can emit the canonical `TranscriptDocument`. Store secrets outside `UserDefaults` through a Keychain-backed credential store, and leave live translation independent from the primary meeting record. Translation and summary will remain downstream consumers of transcript artifacts, with explicit invalidation/retry hooks added before deeper quality work.

**Tech Stack:** Swift 5.9, SwiftUI, XCTest, Foundation `URLSessionWebSocketTask`, macOS Security framework Keychain APIs, existing `MeetingAgentCore` models and file writers.

---

## Scope

This plan implements Phase 1 only. It does not implement speaker-label editing, transcript correction UI, SRT/VTT export, live translation session rollover, app signing/notarization, billing, or cloud sync.

## File Structure

- Create `Sources/MeetingAgentCore/CredentialStore.swift`
  - Keychain-backed storage for hosted provider API keys.
- Test `Tests/MeetingAgentCoreTests/CredentialStoreTests.swift`
  - In-memory and Keychain adapter tests.
- Modify `Sources/MeetingAgentCore/SpeechTranscriptionConfiguration.swift`
  - Remove secret persistence from the durable Codable config path by adding credential references and migration behavior.
- Modify `Sources/MeetingAgentApp/SettingsView.swift`
  - Save and load API keys through a credential callback instead of encoding them into `UserDefaults`.
- Modify `Sources/MeetingAgentCore/BilingualPipelineFactory.swift`
  - Make Deepgram Nova-3 the recommended/default hosted STT option.
- Create `Sources/MeetingAgentCore/OpenAIRealtimeTranscriptionProvider.swift`
  - Realtime transcription-only STT provider that emits `TranscriptSegment` into `TranscriptFileWriter`.
- Test `Tests/MeetingAgentCoreTests/OpenAIRealtimeTranscriptionProviderTests.swift`
  - Event decoding, ordering, configuration, provider start/finish, and transcript writing.
- Modify `Sources/MeetingAgentCore/SpeechTranscriptionProvider.swift`
  - Add provider factory branch for OpenAI Realtime transcription.
- Modify `Sources/MeetingAgentCore/MeetingRecorder.swift`
  - Preserve WAV-first behavior and make provider failure states explicit without stopping capture.
- Modify `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
  - Add retry-stage semantics and downstream invalidation when transcript changes.
- Test existing view-model/recorder test files and add focused tests where behavior changes.

---

### Task 1: Add Credential Store Boundary

**Files:**
- Create: `Sources/MeetingAgentCore/CredentialStore.swift`
- Create: `Tests/MeetingAgentCoreTests/CredentialStoreTests.swift`

- [ ] **Step 1: Write failing credential store tests**

Create `Tests/MeetingAgentCoreTests/CredentialStoreTests.swift`:

```swift
import XCTest
@testable import MeetingAgentCore

final class CredentialStoreTests: XCTestCase {
    func testMemoryCredentialStoreSavesLoadsAndDeletesValues() throws {
        let store = MemoryCredentialStore()

        try store.save("openai-key", for: .openAI)
        try store.save("deepgram-key", for: .deepgram)

        XCTAssertEqual(try store.load(.openAI), "openai-key")
        XCTAssertEqual(try store.load(.deepgram), "deepgram-key")

        try store.delete(.openAI)
        XCTAssertNil(try store.load(.openAI))
        XCTAssertEqual(try store.load(.deepgram), "deepgram-key")
    }

    func testBlankCredentialsAreDeleted() throws {
        let store = MemoryCredentialStore()
        try store.save("deepgram-key", for: .deepgram)

        try store.save("   ", for: .deepgram)

        XCTAssertNil(try store.load(.deepgram))
    }

    func testServiceAndAccountNamesAreStable() {
        XCTAssertEqual(CredentialKind.openAI.service, "MeetingAgent")
        XCTAssertEqual(CredentialKind.openAI.account, "openai-api-key")
        XCTAssertEqual(CredentialKind.deepgram.account, "deepgram-api-key")
        XCTAssertEqual(CredentialKind.openRouter.account, "openrouter-api-key")
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
swift test --filter CredentialStoreTests
```

Expected: FAIL because `CredentialKind`, `CredentialStoring`, and `MemoryCredentialStore` do not exist.

- [ ] **Step 3: Implement credential store types**

Create `Sources/MeetingAgentCore/CredentialStore.swift`:

```swift
import Foundation
import Security

public enum CredentialKind: String, CaseIterable, Codable, Equatable {
    case openAI
    case deepgram
    case openRouter

    public var service: String { "MeetingAgent" }

    public var account: String {
        switch self {
        case .openAI:
            return "openai-api-key"
        case .deepgram:
            return "deepgram-api-key"
        case .openRouter:
            return "openrouter-api-key"
        }
    }
}

public protocol CredentialStoring {
    func load(_ kind: CredentialKind) throws -> String?
    func save(_ value: String?, for kind: CredentialKind) throws
    func delete(_ kind: CredentialKind) throws
}

public enum CredentialStoreError: Error, Equatable, CustomStringConvertible {
    case unexpectedStatus(OSStatus)
    case invalidData

    public var description: String {
        switch self {
        case .unexpectedStatus(let status):
            return "Keychain returned status \(status)"
        case .invalidData:
            return "Keychain credential data was not valid UTF-8"
        }
    }
}

public final class MemoryCredentialStore: CredentialStoring {
    private var values: [CredentialKind: String] = [:]

    public init() {}

    public func load(_ kind: CredentialKind) throws -> String? {
        values[kind]
    }

    public func save(_ value: String?, for kind: CredentialKind) throws {
        guard let normalized = SpeechTranscriptionConfiguration.normalized(value) else {
            try delete(kind)
            return
        }
        values[kind] = normalized
    }

    public func delete(_ kind: CredentialKind) throws {
        values.removeValue(forKey: kind)
    }
}

public final class KeychainCredentialStore: CredentialStoring {
    public init() {}

    public func load(_ kind: CredentialKind) throws -> String? {
        var query = Self.baseQuery(for: kind)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw CredentialStoreError.unexpectedStatus(status)
        }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            throw CredentialStoreError.invalidData
        }
        return value
    }

    public func save(_ value: String?, for kind: CredentialKind) throws {
        guard let normalized = SpeechTranscriptionConfiguration.normalized(value) else {
            try delete(kind)
            return
        }

        let data = Data(normalized.utf8)
        var query = Self.baseQuery(for: kind)
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            throw CredentialStoreError.unexpectedStatus(updateStatus)
        }

        query[kSecValueData as String] = data
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CredentialStoreError.unexpectedStatus(addStatus)
        }
    }

    public func delete(_ kind: CredentialKind) throws {
        let status = SecItemDelete(Self.baseQuery(for: kind) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.unexpectedStatus(status)
        }
    }

    private static func baseQuery(for kind: CredentialKind) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: kind.service,
            kSecAttrAccount as String: kind.account
        ]
    }
}
```

- [ ] **Step 4: Run focused tests**

Run:

```bash
swift test --filter CredentialStoreTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingAgentCore/CredentialStore.swift Tests/MeetingAgentCoreTests/CredentialStoreTests.swift
git commit -m "Add credential store boundary"
```

---

### Task 2: Stop Persisting API Keys In UserDefaults

**Files:**
- Modify: `Sources/MeetingAgentCore/SpeechTranscriptionConfiguration.swift`
- Test: `Tests/MeetingAgentCoreTests/SpeechTranscriptionConfigurationTests.swift`

- [ ] **Step 1: Add failing tests for secret-stripped persistence**

Append to `SpeechTranscriptionConfigurationTests`:

```swift
func testConfigurationStoreDoesNotPersistAPIKeys() throws {
    let defaults = UserDefaults(suiteName: "MeetingAgentTests-\(UUID().uuidString)")!
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
    let store = SpeechTranscriptionConfigurationStore(userDefaults: defaults)
    let configuration = SpeechTranscriptionConfiguration(
        provider: .whisper,
        localeIdentifier: "en-US",
        whisperBinaryPath: nil,
        whisperModelPath: nil,
        openRouterAPIKey: "openrouter-secret",
        openAIRealtimeAPIKey: "openai-secret",
        deepgramAPIKey: "deepgram-secret"
    )

    try store.save(configuration)
    let loaded = try store.load()

    XCTAssertNil(loaded.openRouterAPIKey)
    XCTAssertNil(loaded.openAIRealtimeAPIKey)
    XCTAssertNil(loaded.deepgramAPIKey)
}

private func defaultsSuiteName(_ defaults: UserDefaults) -> String {
    defaults.volatileDomainNames.first { $0.hasPrefix("MeetingAgentTests-") } ?? ""
}
```

If the helper is awkward with existing test style, use an explicit local `suiteName` variable in the test:

```swift
let suiteName = "MeetingAgentTests-\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suiteName)!
defer { defaults.removePersistentDomain(forName: suiteName) }
```

- [ ] **Step 2: Run test to verify failure**

Run:

```bash
swift test --filter SpeechTranscriptionConfigurationTests/testConfigurationStoreDoesNotPersistAPIKeys
```

Expected: FAIL because saved configuration still includes API key fields.

- [ ] **Step 3: Strip secrets before encoding**

Modify `SpeechTranscriptionConfigurationStore.save(_:)`:

```swift
public func save(_ configuration: SpeechTranscriptionConfiguration) throws {
    var persisted = configuration
    persisted.openRouterAPIKey = nil
    persisted.openAIRealtimeAPIKey = nil
    persisted.deepgramAPIKey = nil
    let data = try JSONEncoder.meetingAgent.encode(persisted)
    userDefaults.set(data, forKey: key)
}
```

- [ ] **Step 4: Run configuration tests**

Run:

```bash
swift test --filter SpeechTranscriptionConfigurationTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingAgentCore/SpeechTranscriptionConfiguration.swift Tests/MeetingAgentCoreTests/SpeechTranscriptionConfigurationTests.swift
git commit -m "Stop persisting provider API keys"
```

---

### Task 3: Make Deepgram Nova-3 The Recommended STT Default

**Files:**
- Modify: `Sources/MeetingAgentCore/SpeechTranscriptionConfiguration.swift`
- Modify: `Sources/MeetingAgentCore/BilingualPipelineFactory.swift`
- Test: `Tests/MeetingAgentCoreTests/SpeechTranscriptionConfigurationTests.swift`
- Test: `Tests/MeetingAgentCoreTests/BilingualPipelineFactoryTests.swift`

- [ ] **Step 1: Write failing default tests**

Add to `SpeechTranscriptionConfigurationTests`:

```swift
func testReliableMVPDefaultsUseDeepgramHostedTranscription() {
    let configuration = SpeechTranscriptionConfiguration.default

    XCTAssertEqual(configuration.transcriptionExecutionMode, .hosted)
    XCTAssertEqual(configuration.hostedTranscriptionProviderID, SpeechTranscriptionConfiguration.defaultDeepgramTranscriptionProviderID)
    XCTAssertEqual(configuration.deepgramModelID, "nova-3")
    XCTAssertEqual(configuration.translationExecutionMode, .hosted)
}
```

Add to `BilingualPipelineFactoryTests`:

```swift
func testReliableMVPRecommendedProfileStartsWithDeepgram() throws {
    let profile = try XCTUnwrap(BilingualPipelineFactory.builtInProfiles.first {
        $0.id == SpeechTranscriptionConfiguration.defaultBilingualPipelineProfileID
    })

    XCTAssertEqual(profile.steps.first?.primary, .provider("deepgram-transcribe"))
}
```

- [ ] **Step 2: Run focused tests to verify failure**

Run:

```bash
swift test --filter SpeechTranscriptionConfigurationTests/testReliableMVPDefaultsUseDeepgramHostedTranscription
swift test --filter BilingualPipelineFactoryTests/testReliableMVPRecommendedProfileStartsWithDeepgram
```

Expected: FAIL because defaults currently point at local Whisper or OpenRouter paths.

- [ ] **Step 3: Update defaults and profile**

In `SpeechTranscriptionConfiguration`, set:

```swift
public static let defaultBilingualPipelineProfileID = "deepgram-stt-hosted-translation"
```

In `.default`, set:

```swift
provider: .whisper,
localeIdentifier: "en-US",
targetLocaleIdentifier: "zh-CN",
bilingualPipelineProfileID: defaultBilingualPipelineProfileID,
whisperBinaryPath: nil,
whisperModelPath: nil,
transcriptionExecutionMode: .hosted,
translationExecutionMode: .hosted,
localTranscriptionProviderID: defaultLocalTranscriptionProviderID,
localTranslationProviderID: defaultLocalTranslationProviderID,
hostedTranscriptionProviderID: defaultDeepgramTranscriptionProviderID,
hostedTranslationProviderID: defaultHostedTranslationProviderID,
hostedTranscriptionModelID: defaultHostedTranscriptionModelID,
hostedTranslationModelID: defaultHostedTranslationModelID,
openRouterAPIKey: nil,
openAIRealtimeAPIKey: nil,
deepgramAPIKey: nil,
deepgramModelID: defaultDeepgramModelID
```

In `BilingualPipelineFactory.builtInProfiles`, add the recommended profile before existing profiles:

```swift
BilingualPipelineProfile(id: "deepgram-stt-hosted-translation", displayName: "Deepgram Nova-3 + Hosted Translation", steps: [
    PipelineStep(capability: .audioTranscription, primary: .provider("deepgram-transcribe"), fallbacks: [.provider("whisper-local")]),
    PipelineStep(capability: .textTranslation, primary: .provider("openrouter-translation"))
])
```

- [ ] **Step 4: Update expected tests that assume old defaults**

Search:

```bash
rg -n "local-whisper-hosted-translation|defaultBilingualSettings|transcriptionExecutionMode|hostedTranscriptionProviderID" Tests/MeetingAgentCoreTests
```

Adjust only tests that describe defaults. Do not change tests for legacy profile availability.

- [ ] **Step 5: Run related tests**

Run:

```bash
swift test --filter SpeechTranscriptionConfigurationTests
swift test --filter BilingualPipelineFactoryTests
swift test --filter BilingualPipelineProfileTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/MeetingAgentCore/SpeechTranscriptionConfiguration.swift Sources/MeetingAgentCore/BilingualPipelineFactory.swift Tests/MeetingAgentCoreTests/SpeechTranscriptionConfigurationTests.swift Tests/MeetingAgentCoreTests/BilingualPipelineFactoryTests.swift
git commit -m "Default primary chain to Deepgram Nova-3"
```

---

### Task 4: Add OpenAI Realtime Transcription Event Decoder

**Files:**
- Create: `Sources/MeetingAgentCore/OpenAIRealtimeTranscriptionProvider.swift`
- Create: `Tests/MeetingAgentCoreTests/OpenAIRealtimeTranscriptionProviderTests.swift`

- [ ] **Step 1: Write failing decoder tests**

Create `Tests/MeetingAgentCoreTests/OpenAIRealtimeTranscriptionProviderTests.swift`:

```swift
import Foundation
import XCTest
@testable import MeetingAgentCore

final class OpenAIRealtimeTranscriptionProviderTests: XCTestCase {
    func testDecoderMapsDeltaCompletedAndFailureEvents() throws {
        let delta = try OpenAIRealtimeTranscriptionEventDecoder.decode(Data("""
        {"type":"conversation.item.input_audio_transcription.delta","item_id":"item-1","delta":"Hello"}
        """.utf8))
        let completed = try OpenAIRealtimeTranscriptionEventDecoder.decode(Data("""
        {"type":"conversation.item.input_audio_transcription.completed","item_id":"item-1","transcript":"Hello world"}
        """.utf8))
        let error = try OpenAIRealtimeTranscriptionEventDecoder.decode(Data("""
        {"type":"error","error":{"message":"bad key"}}
        """.utf8))

        XCTAssertEqual(delta, .delta(itemID: "item-1", text: "Hello"))
        XCTAssertEqual(completed, .completed(itemID: "item-1", transcript: "Hello world"))
        XCTAssertEqual(error, .failed("bad key"))
    }

    func testDecoderIgnoresUnrelatedEvents() throws {
        let event = try OpenAIRealtimeTranscriptionEventDecoder.decode(Data("""
        {"type":"session.updated"}
        """.utf8))

        XCTAssertNil(event)
    }
}
```

- [ ] **Step 2: Run test to verify failure**

Run:

```bash
swift test --filter OpenAIRealtimeTranscriptionProviderTests/testDecoderMapsDeltaCompletedAndFailureEvents
```

Expected: FAIL because decoder does not exist.

- [ ] **Step 3: Implement event types and decoder**

Create the beginning of `Sources/MeetingAgentCore/OpenAIRealtimeTranscriptionProvider.swift`:

```swift
import Foundation

enum OpenAIRealtimeTranscriptionProviderError: Error, CustomStringConvertible, Equatable {
    case missingAPIKey
    case invalidEvent
    case transportClosed

    var description: String {
        switch self {
        case .missingAPIKey:
            return "OpenAI API key is not configured"
        case .invalidEvent:
            return "OpenAI Realtime transcription event could not be decoded"
        case .transportClosed:
            return "OpenAI Realtime transcription transport is closed"
        }
    }
}

enum OpenAIRealtimeTranscriptionEvent: Equatable {
    case connected
    case delta(itemID: String, text: String)
    case completed(itemID: String, transcript: String)
    case failed(String)
}

enum OpenAIRealtimeTranscriptionEventDecoder {
    static func decode(_ data: Data) throws -> OpenAIRealtimeTranscriptionEvent? {
        let envelope = try JSONDecoder().decode(EventEnvelope.self, from: data)
        switch envelope.type {
        case "session.created", "session.updated":
            return .connected
        case "conversation.item.input_audio_transcription.delta":
            return .delta(itemID: envelope.itemID ?? "", text: envelope.delta ?? "")
        case "conversation.item.input_audio_transcription.completed":
            return .completed(itemID: envelope.itemID ?? "", transcript: envelope.transcript ?? "")
        case "error":
            return .failed(envelope.error?.message ?? "OpenAI Realtime transcription error")
        default:
            return nil
        }
    }

    private struct EventEnvelope: Decodable {
        let type: String
        let itemID: String?
        let delta: String?
        let transcript: String?
        let error: ErrorEnvelope?

        enum CodingKeys: String, CodingKey {
            case type
            case itemID = "item_id"
            case delta
            case transcript
            case error
        }
    }

    private struct ErrorEnvelope: Decodable {
        let message: String
    }
}
```

- [ ] **Step 4: Run decoder tests**

Run:

```bash
swift test --filter OpenAIRealtimeTranscriptionProviderTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingAgentCore/OpenAIRealtimeTranscriptionProvider.swift Tests/MeetingAgentCoreTests/OpenAIRealtimeTranscriptionProviderTests.swift
git commit -m "Decode OpenAI realtime transcription events"
```

---

### Task 5: Implement OpenAI Realtime Transcription Provider

**Files:**
- Modify: `Sources/MeetingAgentCore/OpenAIRealtimeTranscriptionProvider.swift`
- Test: `Tests/MeetingAgentCoreTests/OpenAIRealtimeTranscriptionProviderTests.swift`

- [ ] **Step 1: Add failing provider tests with fake transport**

Append to `OpenAIRealtimeTranscriptionProviderTests`:

```swift
func testProviderStartsSessionSendsConfigurationAndWritesCompletedSegments() async throws {
    let transport = FakeRealtimeTranscriptionTransport()
    let transcriptURL = temporaryURL("transcript.txt")
    let provider = OpenAIRealtimeTranscriptionProvider(
        apiKey: "openai-key",
        transportFactory: { _, _ in transport }
    )

    let transcriber = try await provider.start(context: SpeechTranscriptionStreamContext(
        transcriptURL: transcriptURL,
        localeIdentifier: "en-US",
        sampleRate: 24_000,
        channelCount: 1
    ))

    transport.yield("""
    {"type":"conversation.item.input_audio_transcription.completed","item_id":"item-1","transcript":"Hello world"}
    """)
    try await Task.sleep(nanoseconds: 50_000_000)
    transcriber.finish()

    let document = try TranscriptFileWriter.readDocument(from: transcriptURL.deletingPathExtension().appendingPathExtension("json"))
    XCTAssertEqual(document.segments.map(\\.text), ["Hello world"])
    XCTAssertEqual(document.segments.first?.sourceProvider, "openai-realtime-transcribe")
    XCTAssertTrue(transport.sentMessages.contains { String(decoding: $0, as: UTF8.self).contains("\"type\":\"session.update\"") })
}

private func temporaryURL(_ name: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent(name)
}

private final class FakeRealtimeTranscriptionTransport: RealtimeTranscriptionWebSocketTransport {
    private var continuation: AsyncStream<Data>.Continuation!
    private(set) var sentMessages: [Data] = []
    private(set) var connected = false
    private(set) var closed = false

    lazy var incomingMessages: AsyncStream<Data> = AsyncStream { continuation in
        self.continuation = continuation
    }

    func connect() async throws {
        connected = true
    }

    func send(_ data: Data) async throws {
        sentMessages.append(data)
    }

    func close() async {
        closed = true
        continuation.finish()
    }

    func yield(_ text: String) {
        continuation.yield(Data(text.utf8))
    }
}
```

If `temporaryURL(_:)` creates a nested directory, add:

```swift
try FileManager.default.createDirectory(at: transcriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
```

before starting the provider.

- [ ] **Step 2: Run test to verify failure**

Run:

```bash
swift test --filter OpenAIRealtimeTranscriptionProviderTests/testProviderStartsSessionSendsConfigurationAndWritesCompletedSegments
```

Expected: FAIL because provider, transport protocol, and transcriber do not exist.

- [ ] **Step 3: Implement transport protocol and provider**

Append to `OpenAIRealtimeTranscriptionProvider.swift`:

```swift
protocol RealtimeTranscriptionWebSocketTransport: AnyObject {
    var incomingMessages: AsyncStream<Data> { get }
    func connect() async throws
    func send(_ data: Data) async throws
    func close() async
}

public struct OpenAIRealtimeTranscriptionProvider {
    private let apiKey: String?
    private let model: String
    private let transportFactory: (URL, String) -> RealtimeTranscriptionWebSocketTransport

    public init(
        apiKey: String?,
        model: String = "gpt-4o-transcribe",
        transportFactory: @escaping (URL, String) -> RealtimeTranscriptionWebSocketTransport
    ) {
        self.apiKey = SpeechTranscriptionConfiguration.normalized(apiKey)
        self.model = model
        self.transportFactory = transportFactory
    }

    public func start(context: SpeechTranscriptionStreamContext) async throws -> AudioFrameTranscriber {
        guard let apiKey else {
            throw OpenAIRealtimeTranscriptionProviderError.missingAPIKey
        }
        guard let url = URL(string: "wss://api.openai.com/v1/realtime?model=gpt-realtime") else {
            throw ProbeError.invalidArguments("Invalid OpenAI Realtime transcription URL")
        }
        let transport = transportFactory(url, apiKey)
        try await transport.connect()
        try await transport.send(try sessionUpdate(
            model: model,
            localeIdentifier: context.localeIdentifier,
            sampleRate: context.sampleRate
        ))
        let writer = try TranscriptFileWriter(url: context.transcriptURL)
        return OpenAIRealtimeTranscriptionTranscriber(
            transport: transport,
            writer: writer,
            localeIdentifier: context.localeIdentifier
        )
    }

    private func sessionUpdate(model: String, localeIdentifier: String, sampleRate: Double) throws -> Data {
        let language = localeIdentifier.split(separator: "-").first.map(String.init) ?? localeIdentifier
        let event = SessionUpdateEvent(session: Session(
            audio: Audio(input: AudioInput(
                format: AudioFormat(type: "audio/pcm", rate: 24_000),
                transcription: Transcription(model: model, language: language),
                turnDetection: TurnDetection(type: "server_vad")
            ))
        ))
        return try JSONEncoder().encode(event)
    }

    private struct SessionUpdateEvent: Encodable {
        var type = "session.update"
        var session: Session
    }

    private struct Session: Encodable {
        var type = "transcription"
        var audio: Audio
    }

    private struct Audio: Encodable {
        var input: AudioInput
    }

    private struct AudioInput: Encodable {
        var format: AudioFormat
        var transcription: Transcription
        var turnDetection: TurnDetection

        enum CodingKeys: String, CodingKey {
            case format
            case transcription
            case turnDetection = "turn_detection"
        }
    }

    private struct AudioFormat: Encodable {
        var type: String
        var rate: Int
    }

    private struct Transcription: Encodable {
        var model: String
        var language: String
    }

    private struct TurnDetection: Encodable {
        var type: String
    }
}

final class OpenAIRealtimeTranscriptionTranscriber: AudioFrameTranscriber {
    private let transport: RealtimeTranscriptionWebSocketTransport
    private let writer: TranscriptFileWriter
    private let localeIdentifier: String
    private var receiveTask: Task<Void, Never>?
    private var segmentIndex = 0
    private(set) var failureReason: String?

    init(
        transport: RealtimeTranscriptionWebSocketTransport,
        writer: TranscriptFileWriter,
        localeIdentifier: String
    ) {
        self.transport = transport
        self.writer = writer
        self.localeIdentifier = localeIdentifier
        self.receiveTask = Task { [transport, writer, localeIdentifier] in
            var localSegmentIndex = 0
            for await data in transport.incomingMessages {
                do {
                    guard let event = try OpenAIRealtimeTranscriptionEventDecoder.decode(data) else { continue }
                    switch event {
                    case .completed(let itemID, let transcript):
                        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { continue }
                        try writer.append(TranscriptSegment(
                            id: itemID.isEmpty ? "openai-realtime-\(localSegmentIndex)" : itemID,
                            text: text,
                            language: localeIdentifier,
                            sourceProvider: "openai-realtime-transcribe",
                            isFinal: true,
                            timingSource: .unavailable
                        ))
                        localSegmentIndex += 1
                    case .failed(let message):
                        try writer.replace(with: "OpenAI Realtime transcription failed: \(message)")
                    case .connected, .delta:
                        break
                    }
                } catch {
                    try? writer.replace(with: "OpenAI Realtime transcription failed: \(error)")
                }
            }
        }
    }

    func append(_ frame: AudioFrame) throws {
        Task { [transport] in
            do {
                try await transport.send(try Self.appendAudio(frame.pcm))
            } catch {
                self.failureReason = "OpenAI Realtime transcription failed: \(error)"
            }
        }
    }

    func finish() {
        receiveTask?.cancel()
        Task { [transport, writer] in
            await transport.close()
            try? writer.close()
        }
    }

    private static func appendAudio(_ pcm16: Data) throws -> Data {
        let event = AppendAudioEvent(audio: pcm16.base64EncodedString())
        return try JSONEncoder().encode(event)
    }

    private struct AppendAudioEvent: Encodable {
        var type = "input_audio_buffer.append"
        var audio: String
    }
}
```

- [ ] **Step 4: Add URLSession transport**

Append:

```swift
final class URLSessionRealtimeTranscriptionWebSocketTransport: NSObject, RealtimeTranscriptionWebSocketTransport {
    private let url: URL
    private let apiKey: String
    private var task: URLSessionWebSocketTask?
    private var continuation: AsyncStream<Data>.Continuation?

    init(url: URL, apiKey: String) {
        self.url = url
        self.apiKey = apiKey
    }

    var incomingMessages: AsyncStream<Data> {
        AsyncStream { continuation in
            self.continuation = continuation
            self.receiveNext()
        }
    }

    func connect() async throws {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        task = URLSession.shared.webSocketTask(with: request)
        task?.resume()
        receiveNext()
    }

    func send(_ data: Data) async throws {
        guard let task else { throw OpenAIRealtimeTranscriptionProviderError.transportClosed }
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    func close() async {
        task?.cancel(with: .goingAway, reason: nil)
        continuation?.finish()
        task = nil
    }

    private func receiveNext() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.data(let data)):
                self.continuation?.yield(data)
                self.receiveNext()
            case .success(.string(let text)):
                self.continuation?.yield(Data(text.utf8))
                self.receiveNext()
            case .failure:
                self.continuation?.finish()
            @unknown default:
                self.continuation?.finish()
            }
        }
    }
}
```

- [ ] **Step 5: Run provider tests**

Run:

```bash
swift test --filter OpenAIRealtimeTranscriptionProviderTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/MeetingAgentCore/OpenAIRealtimeTranscriptionProvider.swift Tests/MeetingAgentCoreTests/OpenAIRealtimeTranscriptionProviderTests.swift
git commit -m "Add OpenAI realtime transcription provider"
```

---

### Task 6: Wire Realtime Transcription Into Provider Factory

**Files:**
- Modify: `Sources/MeetingAgentCore/SpeechTranscriptionConfiguration.swift`
- Modify: `Sources/MeetingAgentCore/SpeechTranscriptionProvider.swift`
- Modify: `Sources/MeetingAgentCore/BilingualPipelineFactory.swift`
- Test: `Tests/MeetingAgentCoreTests/SpeechTranscriptionProviderTests.swift`
- Test: `Tests/MeetingAgentCoreTests/BilingualProviderRegistryTests.swift`

- [ ] **Step 1: Add failing factory tests**

Add to `SpeechTranscriptionProviderTests`:

```swift
func testStreamingFactoryReturnsOpenAIRealtimeTranscriptionProvider() async throws {
    var configuration = SpeechTranscriptionConfiguration.default
    configuration.hostedTranscriptionProviderID = SpeechTranscriptionConfiguration.defaultOpenAIRealtimeTranscriptionProviderID
    configuration.transcriptionExecutionMode = .hosted
    configuration.openAIRealtimeAPIKey = "openai-key"

    let provider = try await StreamingSpeechTranscriberFactory.startTranscriber(
        configuration: configuration,
        transcriptURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("txt"),
        sampleRate: 24_000,
        channelCount: 1
    )

    XCTAssertNotNil(provider)
}
```

If this test would open a real socket, refactor the factory first to allow an injected `openAIRealtimeTranscriptionProviderFactory`; then assert the injected factory was called.

- [ ] **Step 2: Add provider descriptor test**

Add to `BilingualProviderRegistryTests`:

```swift
func testBuiltInRegistryIncludesOpenAIRealtimeTranscriptionDescriptor() {
    let descriptor = BilingualPipelineFactory.builtInRegistry.descriptor(id: "openai-realtime-transcribe")

    XCTAssertEqual(descriptor?.capability, .audioTranscription)
    XCTAssertEqual(descriptor?.executionMode, .hosted)
    XCTAssertEqual(descriptor?.requiresAPIKey, true)
}
```

- [ ] **Step 3: Run tests to verify failure**

Run:

```bash
swift test --filter BilingualProviderRegistryTests/testBuiltInRegistryIncludesOpenAIRealtimeTranscriptionDescriptor
```

Expected: FAIL because descriptor does not exist.

- [ ] **Step 4: Add provider ID and descriptor**

In `SpeechTranscriptionConfiguration` add:

```swift
public static let defaultOpenAIRealtimeTranscriptionProviderID = "openai-realtime-transcribe"
public static let defaultOpenAIRealtimeTranscriptionModelID = "gpt-4o-transcribe"
```

In `BilingualPipelineFactory.builtInProviderDescriptors`, add:

```swift
ProviderDescriptor(
    id: "openai-realtime-transcribe",
    displayName: "OpenAI Realtime Transcription",
    capability: .audioTranscription,
    executionMode: .hosted,
    supportedSourceLocales: ["*"],
    supportedTargetLocales: [],
    requiresNetwork: true,
    requiresAPIKey: true
)
```

- [ ] **Step 5: Wire factory branch without opening a real socket in tests**

In `SpeechTranscriptionProvider.swift`, update `StreamingSpeechTranscriberFactory.startTranscriber(...)` so hosted transcription handles:

```swift
if configuration.hostedTranscriptionProviderID == SpeechTranscriptionConfiguration.defaultOpenAIRealtimeTranscriptionProviderID {
    let provider = OpenAIRealtimeTranscriptionProvider(
        apiKey: configuration.openAIRealtimeAPIKey ?? ProcessInfo.processInfo.environment["MEETING_AGENT_OPENAI_API_KEY"],
        model: SpeechTranscriptionConfiguration.defaultOpenAIRealtimeTranscriptionModelID,
        transportFactory: { url, apiKey in
            URLSessionRealtimeTranscriptionWebSocketTransport(url: url, apiKey: apiKey)
        }
    )
    return try await provider.start(context: SpeechTranscriptionStreamContext(
        transcriptURL: transcriptURL,
        localeIdentifier: configuration.localeIdentifier,
        sampleRate: sampleRate,
        channelCount: channelCount
    ))
}
```

If the existing factory is not easily testable, split construction into:

```swift
static func providerDescriptorID(for configuration: SpeechTranscriptionConfiguration) -> String {
    configuration.effectiveTranscriptionProviderID
}
```

and unit-test descriptor selection separately before adding live socket construction.

- [ ] **Step 6: Run related tests**

Run:

```bash
swift test --filter SpeechTranscriptionProviderTests
swift test --filter BilingualProviderRegistryTests
swift test --filter BilingualPipelineFactoryTests
```

Expected: PASS without network access.

- [ ] **Step 7: Commit**

```bash
git add Sources/MeetingAgentCore/SpeechTranscriptionConfiguration.swift Sources/MeetingAgentCore/SpeechTranscriptionProvider.swift Sources/MeetingAgentCore/BilingualPipelineFactory.swift Tests/MeetingAgentCoreTests/SpeechTranscriptionProviderTests.swift Tests/MeetingAgentCoreTests/BilingualProviderRegistryTests.swift
git commit -m "Wire OpenAI realtime transcription provider"
```

---

### Task 7: Add Transcript Downstream Invalidation

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingRecord.swift`
- Modify: `Sources/MeetingAgentCore/MeetingStore.swift`
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] **Step 1: Add failing invalidation test**

Add to `MeetingAgentViewModelTests`:

```swift
func testRetryTranscriptionClearsDownstreamTranslationAndSummaryArtifacts() async throws {
    let store = MeetingStore(baseDirectory: temporaryDirectory())
    let record = try store.createMeeting(name: "Demo", startedAt: Date()).record
    try "audio".write(to: record.audioURL!, atomically: true, encoding: .utf8)
    try TranscriptFileWriter(url: record.transcriptURL!).replace(with: [
        TranscriptSegment(text: "old", language: "en-US", sourceProvider: "test")
    ])
    try MeetingSummaryWriter.write(MeetingSummary(
        overview: "old summary",
        keyTopics: [],
        decisions: [],
        actionItems: [],
        openQuestions: [],
        risks: [],
        followUps: [],
        language: "en-US",
        sourceSegmentIDs: [],
        generatedAt: Date(),
        provider: "test",
        status: .succeeded,
        failureReason: nil
    ), jsonURL: record.summaryJSONURL!, markdownURL: record.summaryMarkdownURL!)

    let viewModel = MeetingAgentViewModel(store: store)
    try viewModel.loadMeetings()

    await viewModel.invalidateDownstreamArtifactsAfterTranscriptChange(for: record.id)

    XCTAssertFalse(FileManager.default.fileExists(atPath: record.summaryJSONURL!.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: record.summaryMarkdownURL!.path))
}
```

If `temporaryDirectory()` does not exist in the test file, add:

```swift
private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
```

- [ ] **Step 2: Run test to verify failure**

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testRetryTranscriptionClearsDownstreamTranslationAndSummaryArtifacts
```

Expected: FAIL because invalidation method does not exist.

- [ ] **Step 3: Implement invalidation method**

In `MeetingAgentViewModel`, add:

```swift
public func invalidateDownstreamArtifactsAfterTranscriptChange(for meetingID: UUID) async {
    guard let meeting = meetings.first(where: { $0.id == meetingID }) else { return }
    let urls = [
        meeting.summaryURL,
        meeting.summaryJSONURL,
        meeting.summaryMarkdownURL
    ].compactMap { $0 }
    for url in urls {
        try? FileManager.default.removeItem(at: url)
    }
    statusText = "Transcript updated; summary needs regeneration"
    objectWillChange.send()
}
```

In `retryTranscription(for:)`, after successful transcript replacement and before saving final status, call:

```swift
await invalidateDownstreamArtifactsAfterTranscriptChange(for: meetingID)
```

- [ ] **Step 4: Run view-model tests**

Run:

```bash
swift test --filter MeetingAgentViewModelTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingAgentCore/MeetingAgentViewModel.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift
git commit -m "Invalidate downstream artifacts after transcript changes"
```

---

### Task 8: Add Primary Chain Preflight Status

**Files:**
- Create: `Sources/MeetingAgentCore/PrimaryChainPreflight.swift`
- Test: `Tests/MeetingAgentCoreTests/PrimaryChainPreflightTests.swift`
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift`

- [ ] **Step 1: Write failing preflight tests**

Create `Tests/MeetingAgentCoreTests/PrimaryChainPreflightTests.swift`:

```swift
import XCTest
@testable import MeetingAgentCore

final class PrimaryChainPreflightTests: XCTestCase {
    func testDeepgramModeRequiresDeepgramAndOpenAIKeys() {
        var configuration = SpeechTranscriptionConfiguration.default
        configuration.hostedTranscriptionProviderID = SpeechTranscriptionConfiguration.defaultDeepgramTranscriptionProviderID
        let result = PrimaryChainPreflight.evaluate(
            configuration: configuration,
            credentials: [:],
            fileManager: .default
        )

        XCTAssertEqual(result.status, .unavailable)
        XCTAssertTrue(result.messages.contains("Deepgram API key is not configured"))
        XCTAssertTrue(result.messages.contains("OpenAI API key is not configured"))
    }

    func testOpenAIRealtimeModeRequiresOnlyOpenAIForHostedWork() {
        var configuration = SpeechTranscriptionConfiguration.default
        configuration.hostedTranscriptionProviderID = SpeechTranscriptionConfiguration.defaultOpenAIRealtimeTranscriptionProviderID
        let result = PrimaryChainPreflight.evaluate(
            configuration: configuration,
            credentials: [.openAI: "openai-key"],
            fileManager: .default
        )

        XCTAssertEqual(result.status, .available)
        XCTAssertEqual(result.messages, [])
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
swift test --filter PrimaryChainPreflightTests
```

Expected: FAIL because `PrimaryChainPreflight` does not exist.

- [ ] **Step 3: Implement preflight evaluator**

Create `Sources/MeetingAgentCore/PrimaryChainPreflight.swift`:

```swift
import Foundation

public enum PrimaryChainPreflightStatus: Equatable {
    case available
    case unavailable
}

public struct PrimaryChainPreflightResult: Equatable {
    public var status: PrimaryChainPreflightStatus
    public var messages: [String]
}

public enum PrimaryChainPreflight {
    public static func evaluate(
        configuration: SpeechTranscriptionConfiguration,
        credentials: [CredentialKind: String],
        fileManager: FileManager = .default
    ) -> PrimaryChainPreflightResult {
        var messages: [String] = []

        if configuration.usesDeepgram,
           SpeechTranscriptionConfiguration.normalized(credentials[.deepgram]) == nil {
            messages.append("Deepgram API key is not configured")
        }

        if configuration.hostedTranscriptionProviderID == SpeechTranscriptionConfiguration.defaultOpenAIRealtimeTranscriptionProviderID,
           SpeechTranscriptionConfiguration.normalized(credentials[.openAI]) == nil {
            messages.append("OpenAI API key is not configured")
        }

        if configuration.translationExecutionMode == .hosted,
           SpeechTranscriptionConfiguration.normalized(credentials[.openAI]) == nil {
            messages.append("OpenAI API key is not configured")
        }

        return PrimaryChainPreflightResult(
            status: messages.isEmpty ? .available : .unavailable,
            messages: Array(Set(messages)).sorted()
        )
    }
}
```

- [ ] **Step 4: Expose preflight from view model**

In `MeetingAgentViewModel`, add a credential store dependency:

```swift
private let credentialStore: CredentialStoring
```

Default it in init:

```swift
credentialStore: CredentialStoring = KeychainCredentialStore(),
```

Assign:

```swift
self.credentialStore = credentialStore
```

Add:

```swift
public var primaryChainPreflightResult: PrimaryChainPreflightResult {
    let credentials: [CredentialKind: String] = Dictionary(uniqueKeysWithValues: CredentialKind.allCases.compactMap { kind in
        guard let value = try? credentialStore.load(kind) else { return nil }
        return (kind, value)
    })
    return PrimaryChainPreflight.evaluate(configuration: speechConfiguration, credentials: credentials)
}
```

- [ ] **Step 5: Show preflight status in UI**

In `MeetingDetailView`, add a `primaryChainPreflightResult` parameter and render it near Current Pipeline:

```swift
if primaryChainPreflightResult.status == .unavailable {
    VStack(alignment: .leading, spacing: 4) {
        Text("Primary chain unavailable")
            .foregroundStyle(.red)
        ForEach(primaryChainPreflightResult.messages, id: \.self) { message in
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}
```

Pass `viewModel.primaryChainPreflightResult` from `MainWindowView`.

- [ ] **Step 6: Run related tests**

Run:

```bash
swift test --filter PrimaryChainPreflightTests
swift test --filter MeetingAgentViewModelTests
swift test --filter MainWindowViewLayoutTests
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/MeetingAgentCore/PrimaryChainPreflight.swift Sources/MeetingAgentCore/MeetingAgentViewModel.swift Sources/MeetingAgentApp/MainWindowView.swift Tests/MeetingAgentCoreTests/PrimaryChainPreflightTests.swift
git commit -m "Add primary chain preflight status"
```

---

### Task 9: Final Verification And Cleanup

**Files:**
- Modify only files required by failing tests or compile errors from prior tasks.

- [ ] **Step 1: Run full test suite**

Run:

```bash
make test
```

Expected:

```text
Test Suite 'All tests' passed
Coverage gate passed.
```

- [ ] **Step 2: Build app**

Run:

```bash
swift build --product MeetingAgentApp
```

Expected: build succeeds.

- [ ] **Step 3: Inspect git status**

Run:

```bash
git status --short
```

Expected: only intentional tracked changes are present. The pre-existing untracked file `docs/superpowers/plans/2026-04-27-live-translation-settings-key.md` may still appear and should not be added unless the user explicitly asks.

- [ ] **Step 4: Commit final fixes if any**

If Step 1 or Step 2 required compile/test fixes:

```bash
git add <fixed files>
git commit -m "Stabilize reliable MVP primary chain"
```

If no fixes were required, do not create an empty commit.

---

## Self-Review Notes

- Spec coverage: This plan covers Phase 1 primary-chain hardening, including Deepgram default STT, OpenAI Realtime transcription as selectable STT, Local Whisper fallback positioning, Keychain credentials, WAV-first retryability, preflight, and downstream invalidation. Later spec phases intentionally need separate plans.
- Placeholder scan: No task depends on placeholder markers or unspecified edge handling. Each task includes concrete files, test names, commands, and expected outcomes.
- Type consistency: New credential types use `CredentialKind` and `CredentialStoring`; new Realtime transcription types use the `OpenAIRealtimeTranscription` prefix and emit existing `TranscriptSegment` values.
