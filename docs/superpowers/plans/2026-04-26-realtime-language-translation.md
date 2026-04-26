# Realtime Language Translation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an independent Live Translation chain that reuses active meeting capture frames, streams them to OpenAI `gpt-realtime` over WebSocket, plays translated target-language audio locally, and displays translated target-language text without affecting source-language STT.

**Architecture:** Add provider-neutral realtime translation state, a controller that fans captured frames into a realtime session, and an OpenAI WebSocket provider behind an injectable transport. `MeetingRecorder` remains the owner of capture, WAV writing, and source STT; realtime translation is an optional non-blocking consumer.

**Tech Stack:** Swift 5.9, Swift Concurrency, `URLSessionWebSocketTask`, AVFoundation for PCM playback, XCTest with fake WebSocket and playback sinks.

---

## File Structure

- Create `Sources/MeetingAgentCore/RealtimeTranslation.swift`: public status, configuration, event, live turn, store, provider/session protocols, playback sink protocol.
- Create `Sources/MeetingAgentCore/OpenAIRealtimeTranslationProvider.swift`: OpenAI Realtime WebSocket provider, event decoding, audio base64 encoding, injectable transport.
- Create `Sources/MeetingAgentCore/RealtimeTranslationController.swift`: lifecycle and frame queue for active translation session.
- Modify `Sources/MeetingAgentCore/MeetingRecorder.swift`: add optional realtime frame consumer and fan out drained frames without throwing.
- Modify `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`: expose realtime translation state and start/stop actions.
- Modify `Sources/MeetingAgentApp/MainWindowView.swift`: add Live Translation UI section in the meeting detail view.
- Create `Tests/MeetingAgentCoreTests/RealtimeTranslationStoreTests.swift`: delta/final text state tests.
- Create `Tests/MeetingAgentCoreTests/OpenAIRealtimeTranslationProviderTests.swift`: event decoding and outgoing message tests with fake transport.
- Create `Tests/MeetingAgentCoreTests/RealtimeTranslationControllerTests.swift`: start/append/stop/error isolation tests.
- Modify `Tests/MeetingAgentCoreTests/MeetingRecorderTests.swift`: fan-out consumer does not affect recorder state.
- Modify `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`: view model start/stop translation state.

---

### Task 1: Realtime Translation Core Types

**Files:**
- Create: `Sources/MeetingAgentCore/RealtimeTranslation.swift`
- Test: `Tests/MeetingAgentCoreTests/RealtimeTranslationStoreTests.swift`

- [ ] **Step 1: Write failing store tests**

Create `Tests/MeetingAgentCoreTests/RealtimeTranslationStoreTests.swift`:

```swift
import XCTest
@testable import MeetingAgentCore

final class RealtimeTranslationStoreTests: XCTestCase {
    func testStoreCoalescesDeltasIntoActiveTurn() {
        var store = LiveTranslationStore()

        store.appendDelta("你")
        store.appendDelta("好")

        XCTAssertEqual(store.turns.count, 1)
        XCTAssertEqual(store.turns[0].text, "你好")
        XCTAssertFalse(store.turns[0].isFinal)
    }

    func testStoreFinalizesActiveTurn() {
        var store = LiveTranslationStore()

        store.appendDelta("我们明天")
        store.finalize("我们明天确认。")

        XCTAssertEqual(store.turns.count, 1)
        XCTAssertEqual(store.turns[0].text, "我们明天确认。")
        XCTAssertTrue(store.turns[0].isFinal)
    }

    func testStoreCreatesNewTurnAfterFinal() {
        var store = LiveTranslationStore()

        store.appendDelta("第一句")
        store.finalize("第一句。")
        store.appendDelta("第二句")

        XCTAssertEqual(store.turns.map(\.text), ["第一句。", "第二句"])
        XCTAssertEqual(store.turns.map(\.isFinal), [true, false])
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
swift test --filter RealtimeTranslationStoreTests
```

Expected: compile fails because `LiveTranslationStore` and related realtime translation types do not exist.

- [ ] **Step 3: Add core realtime translation types**

Create `Sources/MeetingAgentCore/RealtimeTranslation.swift`:

```swift
import Foundation

public enum RealtimeTranslationStatus: Equatable {
    case idle
    case connecting
    case connected
    case degraded(String)
    case failed(String)
}

public struct RealtimeTranslationConfiguration: Equatable {
    public var apiKey: String?
    public var model: String
    public var targetLocale: String
    public var voice: String

    public init(
        apiKey: String? = ProcessInfo.processInfo.environment["MEETING_AGENT_OPENAI_API_KEY"],
        model: String = ProcessInfo.processInfo.environment["MEETING_AGENT_REALTIME_MODEL"] ?? "gpt-realtime",
        targetLocale: String = ProcessInfo.processInfo.environment["MEETING_AGENT_REALTIME_TARGET_LOCALE"] ?? "zh-CN",
        voice: String = ProcessInfo.processInfo.environment["MEETING_AGENT_REALTIME_VOICE"] ?? "marin"
    ) {
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "gpt-realtime" : model
        self.targetLocale = targetLocale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "zh-CN" : targetLocale
        self.voice = voice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "marin" : voice
    }

    public var validationError: String? {
        if apiKey?.isEmpty ?? true {
            return "MEETING_AGENT_OPENAI_API_KEY is not configured"
        }
        return nil
    }
}

public enum RealtimeTranslationEvent: Equatable {
    case connected
    case targetAudioDelta(Data)
    case targetTextDelta(String)
    case targetTextFinal(String)
    case rateLimitsUpdated
    case failed(String)
    case stopped
}

public struct LiveTranslationTurn: Identifiable, Equatable {
    public var id: String
    public var targetLocale: String
    public var text: String
    public var isFinal: Bool
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        targetLocale: String,
        text: String,
        isFinal: Bool,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.targetLocale = targetLocale
        self.text = text
        self.isFinal = isFinal
        self.createdAt = createdAt
    }
}

public struct LiveTranslationStore: Equatable {
    public private(set) var turns: [LiveTranslationTurn] = []
    public var targetLocale: String

    public init(targetLocale: String = "zh-CN") {
        self.targetLocale = targetLocale
    }

    public mutating func appendDelta(_ delta: String) {
        guard !delta.isEmpty else { return }
        if let index = turns.indices.last, turns[index].isFinal == false {
            turns[index].text += delta
        } else {
            turns.append(LiveTranslationTurn(
                targetLocale: targetLocale,
                text: delta,
                isFinal: false
            ))
        }
    }

    public mutating func finalize(_ text: String) {
        let finalText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalText.isEmpty else { return }
        if let index = turns.indices.last, turns[index].isFinal == false {
            turns[index].text = finalText
            turns[index].isFinal = true
        } else {
            turns.append(LiveTranslationTurn(
                targetLocale: targetLocale,
                text: finalText,
                isFinal: true
            ))
        }
    }

    public mutating func reset(targetLocale: String) {
        self.targetLocale = targetLocale
        turns.removeAll()
    }
}

public protocol RealtimeSpeechTranslationProvider {
    var descriptor: ProviderDescriptor { get }
    func start(configuration: RealtimeTranslationConfiguration) async throws -> RealtimeTranslationSession
}

public protocol RealtimeTranslationSession: AnyObject {
    var events: AsyncStream<RealtimeTranslationEvent> { get }
    func append(_ frames: [AudioFrame]) async throws
    func stop() async
}

public protocol AudioPlaybackSink: AnyObject {
    func play(_ pcmData: Data, sampleRate: Double, channelCount: Int) async throws
    func stop() async
}
```

- [ ] **Step 4: Run store tests**

Run:

```bash
swift test --filter RealtimeTranslationStoreTests
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingAgentCore/RealtimeTranslation.swift Tests/MeetingAgentCoreTests/RealtimeTranslationStoreTests.swift
git commit -m "Add realtime translation core types"
```

---

### Task 2: OpenAI Realtime WebSocket Provider Event Mapping

**Files:**
- Create: `Sources/MeetingAgentCore/OpenAIRealtimeTranslationProvider.swift`
- Test: `Tests/MeetingAgentCoreTests/OpenAIRealtimeTranslationProviderTests.swift`

- [ ] **Step 1: Write failing event decoding tests**

Create `Tests/MeetingAgentCoreTests/OpenAIRealtimeTranslationProviderTests.swift`:

```swift
import Foundation
import XCTest
@testable import MeetingAgentCore

final class OpenAIRealtimeTranslationProviderTests: XCTestCase {
    func testDecodesOutputAudioDelta() throws {
        let json = #"{"type":"response.output_audio.delta","delta":"AQID"}"#

        let event = try OpenAIRealtimeEventDecoder.decode(Data(json.utf8))

        XCTAssertEqual(event, .targetAudioDelta(Data([1, 2, 3])))
    }

    func testDecodesTranscriptDelta() throws {
        let json = #"{"type":"response.output_audio_transcript.delta","delta":"你好"}"#

        let event = try OpenAIRealtimeEventDecoder.decode(Data(json.utf8))

        XCTAssertEqual(event, .targetTextDelta("你好"))
    }

    func testDecodesTranscriptDone() throws {
        let json = #"{"type":"response.output_audio_transcript.done","transcript":"你好。"}"#

        let event = try OpenAIRealtimeEventDecoder.decode(Data(json.utf8))

        XCTAssertEqual(event, .targetTextFinal("你好。"))
    }

    func testDecodesError() throws {
        let json = #"{"type":"error","error":{"message":"bad request"}}"#

        let event = try OpenAIRealtimeEventDecoder.decode(Data(json.utf8))

        XCTAssertEqual(event, .failed("bad request"))
    }

    func testBuildsSessionUpdateMessage() throws {
        let config = RealtimeTranslationConfiguration(
            apiKey: "key",
            model: "gpt-realtime",
            targetLocale: "ja-JP",
            voice: "marin"
        )

        let data = try OpenAIRealtimeMessageFactory.sessionUpdate(configuration: config)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let session = object?["session"] as? [String: Any]

        XCTAssertEqual(object?["type"] as? String, "session.update")
        XCTAssertEqual(session?["type"] as? String, "realtime")
        XCTAssertEqual(session?["model"] as? String, "gpt-realtime")
        XCTAssertTrue((session?["instructions"] as? String)?.contains("ja-JP") == true)
    }

    func testBuildsAppendAudioMessage() throws {
        let data = try OpenAIRealtimeMessageFactory.appendAudio(Data([1, 2, 3]))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(object?["type"] as? String, "input_audio_buffer.append")
        XCTAssertEqual(object?["audio"] as? String, "AQID")
    }
}
```

- [ ] **Step 2: Run provider tests to verify they fail**

Run:

```bash
swift test --filter OpenAIRealtimeTranslationProviderTests
```

Expected: compile fails because `OpenAIRealtimeEventDecoder` and `OpenAIRealtimeMessageFactory` do not exist.

- [ ] **Step 3: Add decoder and message factory**

Create `Sources/MeetingAgentCore/OpenAIRealtimeTranslationProvider.swift` with this initial content:

```swift
import Foundation

enum OpenAIRealtimeProviderError: Error, CustomStringConvertible, Equatable {
    case missingAPIKey
    case invalidEvent
    case invalidBase64Audio
    case transportClosed

    var description: String {
        switch self {
        case .missingAPIKey:
            return "MEETING_AGENT_OPENAI_API_KEY is not configured"
        case .invalidEvent:
            return "OpenAI Realtime event could not be decoded"
        case .invalidBase64Audio:
            return "OpenAI Realtime audio delta was not valid base64"
        case .transportClosed:
            return "OpenAI Realtime WebSocket transport is closed"
        }
    }
}

enum OpenAIRealtimeEventDecoder {
    static func decode(_ data: Data) throws -> RealtimeTranslationEvent? {
        let envelope = try JSONDecoder().decode(EventEnvelope.self, from: data)
        switch envelope.type {
        case "session.created", "session.updated":
            return .connected
        case "response.output_audio.delta":
            guard let delta = envelope.delta,
                  let audioData = Data(base64Encoded: delta)
            else { throw OpenAIRealtimeProviderError.invalidBase64Audio }
            return .targetAudioDelta(audioData)
        case "response.output_audio_transcript.delta":
            return .targetTextDelta(envelope.delta ?? "")
        case "response.output_audio_transcript.done":
            return .targetTextFinal(envelope.transcript ?? "")
        case "rate_limits.updated":
            return .rateLimitsUpdated
        case "error":
            return .failed(envelope.error?.message ?? "OpenAI Realtime error")
        case "response.done", "response.output_audio.done":
            return nil
        default:
            return nil
        }
    }

    private struct EventEnvelope: Decodable {
        var type: String
        var delta: String?
        var transcript: String?
        var error: ErrorEnvelope?
    }

    private struct ErrorEnvelope: Decodable {
        var message: String
    }
}

enum OpenAIRealtimeMessageFactory {
    static func sessionUpdate(configuration: RealtimeTranslationConfiguration) throws -> Data {
        let instructions = """
        You are a real-time meeting interpreter.
        Translate all incoming speech into \(configuration.targetLocale).
        Output only the translation.
        Preserve meaning, tone, intent, names, numbers, dates, and business context.
        Do not answer the speaker or add commentary.
        """
        let event = SessionUpdateEvent(
            session: Session(
                model: configuration.model,
                instructions: instructions,
                audio: Audio(
                    input: AudioInputConfig(turnDetection: TurnDetection(type: "server_vad")),
                    output: AudioOutputConfig(
                        voice: configuration.voice,
                        format: AudioFormat(type: "audio/pcm", rate: 24_000)
                    )
                )
            )
        )
        return try JSONEncoder().encode(event)
    }

    static func appendAudio(_ pcm16: Data) throws -> Data {
        try JSONEncoder().encode(AppendAudioEvent(audio: pcm16.base64EncodedString()))
    }

    private struct SessionUpdateEvent: Encodable {
        var type = "session.update"
        var session: Session
    }

    private struct Session: Encodable {
        var type = "realtime"
        var model: String
        var instructions: String
        var audio: Audio
    }

    private struct Audio: Encodable {
        var input: AudioInputConfig
        var output: AudioOutputConfig
    }

    private struct AudioInputConfig: Encodable {
        enum CodingKeys: String, CodingKey {
            case turnDetection = "turn_detection"
        }
        var turnDetection: TurnDetection
    }

    private struct TurnDetection: Encodable {
        var type: String
    }

    private struct AudioOutputConfig: Encodable {
        var voice: String
        var format: AudioFormat
    }

    private struct AudioFormat: Encodable {
        var type: String
        var rate: Int
    }

    private struct AppendAudioEvent: Encodable {
        var type = "input_audio_buffer.append"
        var audio: String
    }
}
```

- [ ] **Step 4: Run provider tests**

Run:

```bash
swift test --filter OpenAIRealtimeTranslationProviderTests
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingAgentCore/OpenAIRealtimeTranslationProvider.swift Tests/MeetingAgentCoreTests/OpenAIRealtimeTranslationProviderTests.swift
git commit -m "Add OpenAI realtime event mapping"
```

---

### Task 3: WebSocket Transport, Provider Session, and Audio Encoding

**Files:**
- Modify: `Sources/MeetingAgentCore/OpenAIRealtimeTranslationProvider.swift`
- Modify: `Tests/MeetingAgentCoreTests/OpenAIRealtimeTranslationProviderTests.swift`

- [ ] **Step 1: Add failing fake transport tests**

Append these tests to `OpenAIRealtimeTranslationProviderTests`:

```swift
    func testProviderSendsSessionUpdateOnStart() async throws {
        let transport = FakeRealtimeWebSocketTransport()
        let provider = OpenAIRealtimeSpeechTranslationProvider(
            transportFactory: { _, _ in transport }
        )
        let config = RealtimeTranslationConfiguration(
            apiKey: "key",
            model: "gpt-realtime",
            targetLocale: "zh-CN",
            voice: "marin"
        )

        _ = try await provider.start(configuration: config)

        XCTAssertEqual(transport.sentMessages.count, 1)
        let object = try JSONSerialization.jsonObject(with: transport.sentMessages[0]) as? [String: Any]
        XCTAssertEqual(object?["type"] as? String, "session.update")
    }

    func testSessionAppendSendsBase64PCM16() async throws {
        let transport = FakeRealtimeWebSocketTransport()
        let provider = OpenAIRealtimeSpeechTranslationProvider(
            transportFactory: { _, _ in transport }
        )
        let session = try await provider.start(configuration: RealtimeTranslationConfiguration(apiKey: "key"))
        let samples: [Int16] = [1, -2]
        let pcm = Data(samples.flatMap { sample -> [UInt8] in
            let value = sample.littleEndian
            return withUnsafeBytes(of: value) { Array($0) }
        })
        let frame = AudioFrame(pcm: pcm, sampleRate: 24_000, channelCount: 1, timestampNanos: 0)

        try await session.append([frame])

        XCTAssertEqual(transport.sentMessages.count, 2)
        let object = try JSONSerialization.jsonObject(with: transport.sentMessages[1]) as? [String: Any]
        XCTAssertEqual(object?["type"] as? String, "input_audio_buffer.append")
        XCTAssertEqual(object?["audio"] as? String, pcm.base64EncodedString())
    }

    func testSessionEmitsDecodedTransportEvents() async throws {
        let transport = FakeRealtimeWebSocketTransport()
        let provider = OpenAIRealtimeSpeechTranslationProvider(
            transportFactory: { _, _ in transport }
        )
        let session = try await provider.start(configuration: RealtimeTranslationConfiguration(apiKey: "key"))
        var iterator = session.events.makeAsyncIterator()

        transport.emit(Data(#"{"type":"response.output_audio_transcript.delta","delta":"你好"}"#.utf8))

        let event = await iterator.next()
        XCTAssertEqual(event, .targetTextDelta("你好"))
    }

    func testProviderRejectsMissingAPIKey() async {
        let provider = OpenAIRealtimeSpeechTranslationProvider(
            transportFactory: { _, _ in FakeRealtimeWebSocketTransport() }
        )

        do {
            _ = try await provider.start(configuration: RealtimeTranslationConfiguration(apiKey: " "))
            XCTFail("Expected missing API key error")
        } catch {
            XCTAssertTrue(String(describing: error).contains("MEETING_AGENT_OPENAI_API_KEY is not configured"))
        }
    }
}

private final class FakeRealtimeWebSocketTransport: RealtimeWebSocketTransport {
    var sentMessages: [Data] = []
    private var continuation: AsyncStream<Data>.Continuation?

    var incomingMessages: AsyncStream<Data> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func connect() async throws {}

    func send(_ data: Data) async throws {
        sentMessages.append(data)
    }

    func close() async {
        continuation?.finish()
    }

    func emit(_ data: Data) {
        continuation?.yield(data)
    }
}
```

If the file already has a closing brace for the test class, move that brace to after these new test methods, then put the fake transport after the class.

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
swift test --filter OpenAIRealtimeTranslationProviderTests
```

Expected: compile fails because `OpenAIRealtimeSpeechTranslationProvider` and `RealtimeWebSocketTransport` do not exist.

- [ ] **Step 3: Add transport and provider session**

Append this implementation to `Sources/MeetingAgentCore/OpenAIRealtimeTranslationProvider.swift`:

```swift
protocol RealtimeWebSocketTransport: AnyObject {
    var incomingMessages: AsyncStream<Data> { get }
    func connect() async throws
    func send(_ data: Data) async throws
    func close() async
}

final class URLSessionRealtimeWebSocketTransport: NSObject, RealtimeWebSocketTransport, URLSessionWebSocketDelegate {
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
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
    }

    func send(_ data: Data) async throws {
        guard let task else { throw OpenAIRealtimeProviderError.transportClosed }
        let text = String(decoding: data, as: UTF8.self)
        try await task.send(.string(text))
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

public final class OpenAIRealtimeSpeechTranslationProvider: RealtimeSpeechTranslationProvider {
    public let descriptor = ProviderDescriptor(
        id: "openai-gpt-realtime",
        displayName: "OpenAI GPT Realtime",
        capability: .speechTranslation,
        executionMode: .hosted,
        supportedSourceLocales: ["*"],
        supportedTargetLocales: ["*"],
        requiresNetwork: true,
        requiresAPIKey: true
    )

    private let transportFactory: (URL, String) -> RealtimeWebSocketTransport

    init(transportFactory: @escaping (URL, String) -> RealtimeWebSocketTransport) {
        self.transportFactory = transportFactory
    }

    public convenience init() {
        self.init { url, apiKey in
            URLSessionRealtimeWebSocketTransport(url: url, apiKey: apiKey)
        }
    }

    public func start(configuration: RealtimeTranslationConfiguration) async throws -> RealtimeTranslationSession {
        if let error = configuration.validationError {
            throw ProbeError.invalidArguments(error)
        }
        guard let apiKey = configuration.apiKey else {
            throw OpenAIRealtimeProviderError.missingAPIKey
        }
        guard let url = URL(string: "wss://api.openai.com/v1/realtime?model=\(configuration.model)") else {
            throw ProbeError.invalidArguments("Invalid OpenAI Realtime URL")
        }
        let transport = transportFactory(url, apiKey)
        try await transport.connect()
        try await transport.send(try OpenAIRealtimeMessageFactory.sessionUpdate(configuration: configuration))
        return OpenAIRealtimeTranslationSession(transport: transport)
    }
}

final class OpenAIRealtimeTranslationSession: RealtimeTranslationSession {
    private let transport: RealtimeWebSocketTransport
    private let continuation: AsyncStream<RealtimeTranslationEvent>.Continuation
    let events: AsyncStream<RealtimeTranslationEvent>
    private var receiveTask: Task<Void, Never>?

    init(transport: RealtimeWebSocketTransport) {
        self.transport = transport
        var streamContinuation: AsyncStream<RealtimeTranslationEvent>.Continuation!
        self.events = AsyncStream { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation
        self.receiveTask = Task { [transport, continuation] in
            for await data in transport.incomingMessages {
                do {
                    if let event = try OpenAIRealtimeEventDecoder.decode(data) {
                        continuation.yield(event)
                    }
                } catch {
                    continuation.yield(.failed(String(describing: error)))
                }
            }
            continuation.yield(.stopped)
            continuation.finish()
        }
    }

    func append(_ frames: [AudioFrame]) async throws {
        guard !frames.isEmpty else { return }
        for frame in frames {
            try await transport.send(try OpenAIRealtimeMessageFactory.appendAudio(frame.pcm))
        }
    }

    func stop() async {
        receiveTask?.cancel()
        await transport.close()
        continuation.yield(.stopped)
        continuation.finish()
    }
}
```

- [ ] **Step 4: Run provider tests**

Run:

```bash
swift test --filter OpenAIRealtimeTranslationProviderTests
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingAgentCore/OpenAIRealtimeTranslationProvider.swift Tests/MeetingAgentCoreTests/OpenAIRealtimeTranslationProviderTests.swift
git commit -m "Add OpenAI realtime WebSocket provider"
```

---

### Task 4: Translation Controller and Recorder Fan-Out

**Files:**
- Create: `Sources/MeetingAgentCore/RealtimeTranslationController.swift`
- Modify: `Sources/MeetingAgentCore/MeetingRecorder.swift`
- Test: `Tests/MeetingAgentCoreTests/RealtimeTranslationControllerTests.swift`
- Modify: `Tests/MeetingAgentCoreTests/MeetingRecorderTests.swift`

- [ ] **Step 1: Write failing controller tests**

Create `Tests/MeetingAgentCoreTests/RealtimeTranslationControllerTests.swift`:

```swift
import XCTest
@testable import MeetingAgentCore

final class RealtimeTranslationControllerTests: XCTestCase {
    func testStartFailsWithoutAPIKey() async {
        let controller = RealtimeTranslationController(
            provider: FakeRealtimeSpeechTranslationProvider()
        )

        await controller.start(configuration: RealtimeTranslationConfiguration(apiKey: nil))

        XCTAssertEqual(controller.status, .failed("MEETING_AGENT_OPENAI_API_KEY is not configured"))
    }

    func testAppendFramesForwardsToSession() async {
        let provider = FakeRealtimeSpeechTranslationProvider()
        let controller = RealtimeTranslationController(provider: provider)
        await controller.start(configuration: RealtimeTranslationConfiguration(apiKey: "key"))
        let frame = AudioFrame(pcm: Data([1]), sampleRate: 24_000, channelCount: 1, timestampNanos: 0)

        await controller.append([frame])

        XCTAssertEqual(provider.session.appendedFrames, [frame])
    }

    func testEventsUpdateStoreAndPlayback() async throws {
        let provider = FakeRealtimeSpeechTranslationProvider()
        let playback = FakeAudioPlaybackSink()
        let controller = RealtimeTranslationController(provider: provider, playbackSink: playback)
        await controller.start(configuration: RealtimeTranslationConfiguration(apiKey: "key", targetLocale: "zh-CN"))

        provider.session.emit(.targetTextDelta("你"))
        provider.session.emit(.targetTextFinal("你好。"))
        provider.session.emit(.targetAudioDelta(Data([1, 2, 3])))
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(controller.liveTranslationTurns.map(\.text), ["你好。"])
        XCTAssertEqual(controller.liveTranslationTurns.map(\.isFinal), [true])
        XCTAssertEqual(playback.playedAudio, [Data([1, 2, 3])])
    }

    func testStopStopsSessionAndPlayback() async {
        let provider = FakeRealtimeSpeechTranslationProvider()
        let playback = FakeAudioPlaybackSink()
        let controller = RealtimeTranslationController(provider: provider, playbackSink: playback)
        await controller.start(configuration: RealtimeTranslationConfiguration(apiKey: "key"))

        await controller.stop()

        XCTAssertTrue(provider.session.didStop)
        XCTAssertTrue(playback.didStop)
        XCTAssertEqual(controller.status, .idle)
    }
}

private final class FakeRealtimeSpeechTranslationProvider: RealtimeSpeechTranslationProvider {
    let descriptor = ProviderDescriptor(
        id: "fake-realtime",
        displayName: "Fake Realtime",
        capability: .speechTranslation,
        executionMode: .hosted,
        supportedSourceLocales: ["*"],
        supportedTargetLocales: ["*"],
        requiresNetwork: false,
        requiresAPIKey: false
    )
    let session = FakeRealtimeTranslationSession()

    func start(configuration: RealtimeTranslationConfiguration) async throws -> RealtimeTranslationSession {
        if let error = configuration.validationError {
            throw ProbeError.invalidArguments(error)
        }
        return session
    }
}

private final class FakeRealtimeTranslationSession: RealtimeTranslationSession {
    var appendedFrames: [AudioFrame] = []
    var didStop = false
    private var continuation: AsyncStream<RealtimeTranslationEvent>.Continuation?

    var events: AsyncStream<RealtimeTranslationEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func append(_ frames: [AudioFrame]) async throws {
        appendedFrames.append(contentsOf: frames)
    }

    func stop() async {
        didStop = true
        continuation?.finish()
    }

    func emit(_ event: RealtimeTranslationEvent) {
        continuation?.yield(event)
    }
}

private final class FakeAudioPlaybackSink: AudioPlaybackSink {
    var playedAudio: [Data] = []
    var didStop = false

    func play(_ pcmData: Data, sampleRate: Double, channelCount: Int) async throws {
        playedAudio.append(pcmData)
    }

    func stop() async {
        didStop = true
    }
}
```

- [ ] **Step 2: Add failing recorder fan-out test**

Append this test to `Tests/MeetingAgentCoreTests/MeetingRecorderTests.swift`:

```swift
    func testRecorderCanFanOutFramesToRealtimeConsumerWithoutThrowing() throws {
        let storeRoot = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-recorder-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storeRoot) }
        let store = MeetingStore(baseDirectory: storeRoot)
        let recorder = MeetingRecorder(store: store)
        let consumer = CapturingRealtimeFrameConsumer()

        recorder.realtimeFrameConsumer = consumer
        let frame = AudioFrame(pcm: Data([1, 2, 3]), sampleRate: 24_000, channelCount: 1, timestampNanos: 0)

        recorder.deliverFramesToRealtimeConsumerForTesting([frame])

        XCTAssertEqual(consumer.receivedFrames, [frame])
    }
}

private final class CapturingRealtimeFrameConsumer: RealtimeFrameConsumer {
    var receivedFrames: [AudioFrame] = []

    func consumeRealtimeFrames(_ frames: [AudioFrame]) {
        receivedFrames.append(contentsOf: frames)
    }
}
```

If `MeetingRecorderTests` already ends with a closing brace, move that brace after the new test method and put `CapturingRealtimeFrameConsumer` after the class.

- [ ] **Step 3: Run tests to verify they fail**

Run:

```bash
swift test --filter RealtimeTranslationControllerTests
swift test --filter MeetingRecorderTests/testRecorderCanFanOutFramesToRealtimeConsumerWithoutThrowing
```

Expected: compile fails because `RealtimeTranslationController`, `RealtimeFrameConsumer`, and recorder fan-out hooks do not exist.

- [ ] **Step 4: Add controller**

Create `Sources/MeetingAgentCore/RealtimeTranslationController.swift`:

```swift
import Foundation

public protocol RealtimeFrameConsumer: AnyObject {
    func consumeRealtimeFrames(_ frames: [AudioFrame])
}

public final class RealtimeTranslationController: RealtimeFrameConsumer {
    private let provider: RealtimeSpeechTranslationProvider
    private let playbackSink: AudioPlaybackSink?
    private var session: RealtimeTranslationSession?
    private var eventTask: Task<Void, Never>?
    private var store = LiveTranslationStore()

    public private(set) var status: RealtimeTranslationStatus = .idle

    public var liveTranslationTurns: [LiveTranslationTurn] {
        store.turns
    }

    public init(
        provider: RealtimeSpeechTranslationProvider = OpenAIRealtimeSpeechTranslationProvider(),
        playbackSink: AudioPlaybackSink? = nil
    ) {
        self.provider = provider
        self.playbackSink = playbackSink
    }

    public func start(configuration: RealtimeTranslationConfiguration) async {
        await stop()
        store.reset(targetLocale: configuration.targetLocale)
        status = .connecting
        do {
            let startedSession = try await provider.start(configuration: configuration)
            session = startedSession
            status = .connected
            eventTask = Task { [weak self, startedSession] in
                for await event in startedSession.events {
                    await self?.handle(event)
                }
            }
        } catch {
            status = .failed(Self.errorMessage(error))
        }
    }

    public func append(_ frames: [AudioFrame]) async {
        guard let session, !frames.isEmpty else { return }
        do {
            try await session.append(frames)
        } catch {
            status = .degraded(Self.errorMessage(error))
        }
    }

    public func consumeRealtimeFrames(_ frames: [AudioFrame]) {
        Task { [weak self] in
            await self?.append(frames)
        }
    }

    public func stop() async {
        eventTask?.cancel()
        eventTask = nil
        await session?.stop()
        session = nil
        await playbackSink?.stop()
        status = .idle
    }

    private func handle(_ event: RealtimeTranslationEvent) async {
        switch event {
        case .connected:
            status = .connected
        case .targetAudioDelta(let data):
            do {
                try await playbackSink?.play(data, sampleRate: 24_000, channelCount: 1)
            } catch {
                status = .degraded("Live translation playback failed: \(Self.errorMessage(error))")
            }
        case .targetTextDelta(let delta):
            store.appendDelta(delta)
        case .targetTextFinal(let text):
            store.finalize(text)
        case .rateLimitsUpdated:
            break
        case .failed(let message):
            status = .failed(message)
        case .stopped:
            if status != .idle {
                status = .idle
            }
        }
    }

    private static func errorMessage(_ error: Error) -> String {
        if let probeError = error as? ProbeError {
            return probeError.description.replacingOccurrences(of: "Invalid arguments: ", with: "")
        }
        return String(describing: error)
    }
}
```

- [ ] **Step 5: Add recorder fan-out hook**

Modify `Sources/MeetingAgentCore/MeetingRecorder.swift`:

Add this property near other private state:

```swift
public weak var realtimeFrameConsumer: RealtimeFrameConsumer?
```

In `drainFrames()`, after the `for frame in frames { ... }` loop, add:

```swift
        deliverFramesToRealtimeConsumerForTesting(frames)
```

Add this method before the private methods:

```swift
    public func deliverFramesToRealtimeConsumerForTesting(_ frames: [AudioFrame]) {
        guard !frames.isEmpty else { return }
        realtimeFrameConsumer?.consumeRealtimeFrames(frames)
    }
```

- [ ] **Step 6: Run controller and recorder tests**

Run:

```bash
swift test --filter RealtimeTranslationControllerTests
swift test --filter MeetingRecorderTests/testRecorderCanFanOutFramesToRealtimeConsumerWithoutThrowing
```

Expected: pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/MeetingAgentCore/RealtimeTranslationController.swift Sources/MeetingAgentCore/MeetingRecorder.swift Tests/MeetingAgentCoreTests/RealtimeTranslationControllerTests.swift Tests/MeetingAgentCoreTests/MeetingRecorderTests.swift
git commit -m "Add realtime translation controller"
```

---

### Task 5: View Model Integration

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Modify: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] **Step 1: Write failing view model tests**

Append these tests to `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`:

```swift
    func testStartRealtimeTranslationRequiresRecording() async {
        let viewModel = MeetingAgentViewModel()

        await viewModel.startRealtimeTranslation(targetLocale: "zh-CN")

        XCTAssertEqual(viewModel.realtimeTranslationStatus, .failed("Start recording before live translation"))
    }

    func testStopRealtimeTranslationResetsState() async {
        let controller = RealtimeTranslationController(provider: ViewModelFakeRealtimeProvider())
        let viewModel = MeetingAgentViewModel(realtimeTranslationController: controller)

        await viewModel.stopRealtimeTranslation()

        XCTAssertEqual(viewModel.realtimeTranslationStatus, .idle)
    }
```

Add this fake provider after the test class:

```swift
private final class ViewModelFakeRealtimeProvider: RealtimeSpeechTranslationProvider {
    let descriptor = ProviderDescriptor(
        id: "fake-view-model-realtime",
        displayName: "Fake View Model Realtime",
        capability: .speechTranslation,
        executionMode: .hosted,
        supportedSourceLocales: ["*"],
        supportedTargetLocales: ["*"],
        requiresNetwork: false,
        requiresAPIKey: false
    )

    func start(configuration: RealtimeTranslationConfiguration) async throws -> RealtimeTranslationSession {
        ViewModelFakeRealtimeSession()
    }
}

private final class ViewModelFakeRealtimeSession: RealtimeTranslationSession {
    var events: AsyncStream<RealtimeTranslationEvent> {
        AsyncStream { _ in }
    }

    func append(_ frames: [AudioFrame]) async throws {}

    func stop() async {}
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testStartRealtimeTranslationRequiresRecording
swift test --filter MeetingAgentViewModelTests/testStopRealtimeTranslationResetsState
```

Expected: compile fails because `MeetingAgentViewModel` has no realtime translation initializer or methods.

- [ ] **Step 3: Add view model state and actions**

Modify `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`:

Add published state near existing `@Published` properties:

```swift
    @Published public private(set) var realtimeTranslationStatus: RealtimeTranslationStatus = .idle
    @Published public private(set) var liveTranslationTurns: [LiveTranslationTurn] = []
```

Add a property:

```swift
    private let realtimeTranslationController: RealtimeTranslationController
```

Add an initializer parameter:

```swift
        realtimeTranslationController: RealtimeTranslationController = RealtimeTranslationController(),
```

Inside the initializer body, assign it:

```swift
        self.realtimeTranslationController = realtimeTranslationController
        self.recorder.realtimeFrameConsumer = realtimeTranslationController
```

Add methods near recording methods:

```swift
    public func startRealtimeTranslation(targetLocale: String) async {
        guard isRecording else {
            realtimeTranslationStatus = .failed("Start recording before live translation")
            return
        }
        let configuration = RealtimeTranslationConfiguration(
            targetLocale: targetLocale
        )
        await realtimeTranslationController.start(configuration: configuration)
        syncRealtimeTranslationState()
    }

    public func stopRealtimeTranslation() async {
        await realtimeTranslationController.stop()
        syncRealtimeTranslationState()
    }

    public func syncRealtimeTranslationState() {
        realtimeTranslationStatus = realtimeTranslationController.status
        liveTranslationTurns = realtimeTranslationController.liveTranslationTurns
    }
```

In `drainRecordingFrames(endedAt:)`, after `updateRecordingStatus()`, add:

```swift
        syncRealtimeTranslationState()
```

In `stopRecording(at:)`, before `activeTarget = nil`, add:

```swift
        Task { await stopRealtimeTranslation() }
```

In `stopRecordingAndGenerateSummary`, before `activeTarget = nil`, add:

```swift
        await stopRealtimeTranslation()
```

- [ ] **Step 4: Run view model tests**

Run:

```bash
swift test --filter MeetingAgentViewModelTests/testStartRealtimeTranslationRequiresRecording
swift test --filter MeetingAgentViewModelTests/testStopRealtimeTranslationResetsState
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingAgentCore/MeetingAgentViewModel.swift Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift
git commit -m "Connect realtime translation to view model"
```

---

### Task 6: Local Audio Playback Sink

**Files:**
- Create: `Sources/MeetingAgentCore/LocalAudioPlaybackSink.swift`
- Test: `Tests/MeetingAgentCoreTests/LocalAudioPlaybackSinkTests.swift`

- [ ] **Step 1: Write failing construction test**

Create `Tests/MeetingAgentCoreTests/LocalAudioPlaybackSinkTests.swift`:

```swift
import XCTest
@testable import MeetingAgentCore

final class LocalAudioPlaybackSinkTests: XCTestCase {
    func testSinkAcceptsEmptyAudioWithoutStartingPlayback() async throws {
        let sink = LocalAudioPlaybackSink()

        try await sink.play(Data(), sampleRate: 24_000, channelCount: 1)
        await sink.stop()
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
swift test --filter LocalAudioPlaybackSinkTests
```

Expected: compile fails because `LocalAudioPlaybackSink` does not exist.

- [ ] **Step 3: Add AVFoundation playback sink**

Create `Sources/MeetingAgentCore/LocalAudioPlaybackSink.swift`:

```swift
import AVFoundation
import Foundation

public final class LocalAudioPlaybackSink: AudioPlaybackSink {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var currentFormat: AVAudioFormat?

    public init() {}

    public func play(_ pcmData: Data, sampleRate: Double, channelCount: Int) async throws {
        guard !pcmData.isEmpty else { return }
        let format = try playbackFormat(sampleRate: sampleRate, channelCount: channelCount)
        if engine.attachedNodes.contains(player) == false {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
        }
        if engine.isRunning == false {
            try engine.start()
        }
        if player.isPlaying == false {
            player.play()
        }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(pcmData.count / MemoryLayout<Int16>.size / max(1, channelCount))
        ) else {
            throw ProbeError.invalidArguments("Could not allocate playback buffer")
        }
        buffer.frameLength = buffer.frameCapacity
        pcmData.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            let source = baseAddress.assumingMemoryBound(to: Int16.self)
            let frameCount = Int(buffer.frameLength)
            for channel in 0..<channelCount {
                guard let destination = buffer.int16ChannelData?[channel] else { continue }
                for frame in 0..<frameCount {
                    destination[frame] = source[frame * channelCount + channel]
                }
            }
        }
        player.scheduleBuffer(buffer)
    }

    public func stop() async {
        player.stop()
        engine.stop()
    }

    private func playbackFormat(sampleRate: Double, channelCount: Int) throws -> AVAudioFormat {
        if let currentFormat,
           currentFormat.sampleRate == sampleRate,
           Int(currentFormat.channelCount) == channelCount {
            return currentFormat
        }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channelCount),
            interleaved: false
        ) else {
            throw ProbeError.invalidArguments("Unsupported playback format")
        }
        currentFormat = format
        return format
    }
}
```

- [ ] **Step 4: Run playback sink test**

Run:

```bash
swift test --filter LocalAudioPlaybackSinkTests
```

Expected: pass.

- [ ] **Step 5: Wire playback sink into default view model controller**

Modify the default `MeetingAgentViewModel` initializer parameter from:

```swift
        realtimeTranslationController: RealtimeTranslationController = RealtimeTranslationController(),
```

to:

```swift
        realtimeTranslationController: RealtimeTranslationController = RealtimeTranslationController(
            playbackSink: LocalAudioPlaybackSink()
        ),
```

- [ ] **Step 6: Run focused tests**

Run:

```bash
swift test --filter LocalAudioPlaybackSinkTests
swift test --filter RealtimeTranslationControllerTests
swift test --filter MeetingAgentViewModelTests/testStopRealtimeTranslationResetsState
```

Expected: pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/MeetingAgentCore/LocalAudioPlaybackSink.swift Sources/MeetingAgentCore/MeetingAgentViewModel.swift Tests/MeetingAgentCoreTests/LocalAudioPlaybackSinkTests.swift
git commit -m "Add local realtime translation playback"
```

---

### Task 7: Live Translation UI

**Files:**
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift`
- Test: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`

- [ ] **Step 1: Add failing layout test**

Append this assertion to the existing static layout test in `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift`, or add a new test if the file uses source scanning:

```swift
    func testMainWindowContainsLiveTranslationControls() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MeetingAgentApp/MainWindowView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("Live Translation"))
        XCTAssertTrue(source.contains("Start Live Translation"))
        XCTAssertTrue(source.contains("Stop Live Translation"))
    }
```

If the relative path does not resolve in the existing test file, use the same source path helper pattern already present in `MainWindowViewLayoutTests.swift`.

- [ ] **Step 2: Run layout test to verify it fails**

Run:

```bash
swift test --filter MainWindowViewLayoutTests/testMainWindowContainsLiveTranslationControls
```

Expected: fail because the UI does not contain live translation controls.

- [ ] **Step 3: Add UI parameters and controls**

Modify `MeetingDetailView` in `Sources/MeetingAgentApp/MainWindowView.swift`:

Add properties:

```swift
    let realtimeTranslationStatus: RealtimeTranslationStatus
    let liveTranslationTurns: [LiveTranslationTurn]
    let startRealtimeTranslation: (String) -> Void
    let stopRealtimeTranslation: () -> Void
    @State private var targetLocale = "zh-CN"
```

Pass them from `MainWindowView`:

```swift
                    realtimeTranslationStatus: viewModel.realtimeTranslationStatus,
                    liveTranslationTurns: viewModel.liveTranslationTurns,
                    startRealtimeTranslation: { locale in
                        Task { await viewModel.startRealtimeTranslation(targetLocale: locale) }
                    },
                    stopRealtimeTranslation: {
                        Task { await viewModel.stopRealtimeTranslation() }
                    },
```

Add this section inside the meeting detail `VStack`, after the recording controls and before exports:

```swift
                    Divider()
                    Text("Live Translation")
                        .font(.headline)
                    HStack {
                        Picker("Target", selection: $targetLocale) {
                            ForEach(MeetingAgentViewModel.supportedLocaleIdentifiers, id: \.self) { locale in
                                Text(locale).tag(locale)
                            }
                        }
                        .frame(maxWidth: 180)

                        Button("Start Live Translation") {
                            startRealtimeTranslation(targetLocale)
                        }
                        .disabled(!isRecording || realtimeTranslationStatus == .connecting || realtimeTranslationStatus == .connected)

                        Button("Stop Live Translation") {
                            stopRealtimeTranslation()
                        }
                        .disabled(!liveTranslationCanStop(realtimeTranslationStatus))
                    }
                    Text(liveTranslationStatusText(realtimeTranslationStatus))
                        .font(.caption)
                        .foregroundStyle(liveTranslationStatusColor(realtimeTranslationStatus))
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(liveTranslationTurns.suffix(5)) { turn in
                            Text(turn.text)
                                .textSelection(.enabled)
                                .foregroundStyle(turn.isFinal ? .primary : .secondary)
                        }
                    }
```

Add helpers inside `MeetingDetailView`:

```swift
    private func liveTranslationCanStop(_ status: RealtimeTranslationStatus) -> Bool {
        switch status {
        case .connecting, .connected, .degraded:
            return true
        case .idle, .failed:
            return false
        }
    }

    private func liveTranslationStatusText(_ status: RealtimeTranslationStatus) -> String {
        switch status {
        case .idle:
            return "Live translation idle"
        case .connecting:
            return "Connecting live translation"
        case .connected:
            return "Live translation connected"
        case .degraded(let message):
            return "Live translation degraded: \(message)"
        case .failed(let message):
            return "Live translation failed: \(message)"
        }
    }

    private func liveTranslationStatusColor(_ status: RealtimeTranslationStatus) -> Color {
        switch status {
        case .failed:
            return .red
        case .degraded:
            return .orange
        default:
            return .secondary
        }
    }
```

- [ ] **Step 4: Run layout test and build app**

Run:

```bash
swift test --filter MainWindowViewLayoutTests/testMainWindowContainsLiveTranslationControls
swift build --product MeetingAgentApp
```

Expected: both pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingAgentApp/MainWindowView.swift Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift
git commit -m "Add live translation controls"
```

---

### Task 8: Full Verification

**Files:**
- Verify all modified files.

- [ ] **Step 1: Run full test suite**

Run:

```bash
swift test
```

Expected: all tests pass.

- [ ] **Step 2: Build app and CLI**

Run:

```bash
swift build --product MeetingAgentApp
swift build --product CoreAudioTapProbe
```

Expected: both builds complete successfully.

- [ ] **Step 3: Check git status**

Run:

```bash
git status --short
```

Expected: only intentional changes are present. The existing untracked `.roadmap/` may still appear and should not be added.

- [ ] **Step 4: Commit any verification-only fixes**

If verification required code fixes, commit only those changed files:

```bash
git add Sources/MeetingAgentCore Sources/MeetingAgentApp Tests/MeetingAgentCoreTests
git commit -m "Stabilize realtime translation integration"
```

If no fixes were needed, do not create an empty commit.
