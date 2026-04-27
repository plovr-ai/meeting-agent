import XCTest
@testable import MeetingAgentCore

final class DeepgramStreamingTranscriptionProviderTests: XCTestCase {
    func testStreamingProviderSendsAudioFramesAndWritesIncomingTranscriptSegments() async throws {
        let transcriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("deepgram-stream-\(UUID().uuidString)")
            .appendingPathExtension("txt")
        defer {
            try? FileManager.default.removeItem(at: transcriptURL)
            try? FileManager.default.removeItem(at: transcriptURL.deletingPathExtension().appendingPathExtension("json"))
        }
        let session = FakeDeepgramStreamingSession()
        let client = FakeDeepgramStreamingClient(session: session)
        let provider = DeepgramStreamingSpeechTranscriptionProvider(
            configuration: DeepgramTranscriptionConfiguration(apiKey: "key", model: "nova-3"),
            client: client
        )

        let transcriber = try await provider.start(context: SpeechTranscriptionStreamContext(
            transcriptURL: transcriptURL,
            localeIdentifier: "en-US",
            sampleRate: 48_000,
            channelCount: 1
        ))
        let frame = AudioFrame(pcm: Data([1, 2, 3, 4]), sampleRate: 48_000, channelCount: 1, timestampNanos: 10)

        try transcriber.append(frame)
        session.yield(TranscriptSegment(
            id: "dg-1",
            startTimeSeconds: 0.1,
            endTimeSeconds: 0.5,
            text: "hello live",
            language: "en-US",
            sourceProvider: "deepgram-transcribe",
            confidence: 0.92,
            timingSource: .precise
        ))
        try await Task.sleep(nanoseconds: 30_000_000)
        transcriber.finish()

        XCTAssertEqual(client.requests.first?.apiKey, "key")
        XCTAssertEqual(client.requests.first?.model, "nova-3")
        XCTAssertEqual(client.requests.first?.sampleRate, 48_000)
        XCTAssertEqual(client.requests.first?.channelCount, 1)
        XCTAssertEqual(client.requests.first?.localeIdentifier, "en-US")
        XCTAssertEqual(session.sentFrames, [frame])
        let document = try TranscriptFileWriter.readDocument(
            from: transcriptURL.deletingPathExtension().appendingPathExtension("json")
        )
        XCTAssertEqual(document.segments.first?.text, "hello live")
        XCTAssertEqual(document.segments.first?.sourceProvider, "deepgram-transcribe")
    }
}

private final class FakeDeepgramStreamingClient: DeepgramStreamingTranscriptionClient {
    struct Request: Equatable {
        let apiKey: String
        let model: String
        let sampleRate: Double
        let channelCount: Int
        let localeIdentifier: String
    }

    private(set) var requests: [Request] = []
    private let session: FakeDeepgramStreamingSession

    init(session: FakeDeepgramStreamingSession) {
        self.session = session
    }

    func connect(
        configuration: DeepgramTranscriptionConfiguration,
        sampleRate: Double,
        channelCount: Int,
        localeIdentifier: String
    ) async throws -> DeepgramStreamingTranscriptionSession {
        requests.append(Request(
            apiKey: configuration.apiKey,
            model: configuration.model,
            sampleRate: sampleRate,
            channelCount: channelCount,
            localeIdentifier: localeIdentifier
        ))
        return session
    }
}

private final class FakeDeepgramStreamingSession: DeepgramStreamingTranscriptionSession {
    private var continuation: AsyncStream<TranscriptSegment>.Continuation?
    private(set) var sentFrames: [AudioFrame] = []
    let segments: AsyncStream<TranscriptSegment>

    init() {
        var streamContinuation: AsyncStream<TranscriptSegment>.Continuation!
        self.segments = AsyncStream { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation
    }

    func send(_ frame: AudioFrame) async throws {
        sentFrames.append(frame)
    }

    func close() async {
        continuation?.finish()
    }

    func yield(_ segment: TranscriptSegment) {
        continuation?.yield(segment)
    }
}
