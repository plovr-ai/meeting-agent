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

    func testProviderStartsSessionSendsConfigurationAndWritesCompletedSegments() async throws {
        let transport = FakeRealtimeTranscriptionTransport()
        let transcriptURL = temporaryURL("transcript.txt")
        try FileManager.default.createDirectory(
            at: transcriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
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
        try await Task.sleep(nanoseconds: 50_000_000)

        let document = try TranscriptFileWriter.readDocument(
            from: transcriptURL.deletingPathExtension().appendingPathExtension("json")
        )
        XCTAssertEqual(document.segments.map(\.text), ["Hello world"])
        XCTAssertEqual(document.segments.first?.sourceProvider, "openai-realtime-transcribe")
        XCTAssertTrue(transport.sentMessages.contains {
            String(decoding: $0, as: UTF8.self).contains("\"type\":\"session.update\"")
        })
    }

    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(name)
    }
}

private final class FakeRealtimeTranscriptionTransport: RealtimeTranscriptionWebSocketTransport {
    private var continuation: AsyncStream<Data>.Continuation!
    let incomingMessages: AsyncStream<Data>
    private(set) var sentMessages: [Data] = []
    private(set) var connected = false
    private(set) var closed = false

    init() {
        var streamContinuation: AsyncStream<Data>.Continuation!
        incomingMessages = AsyncStream { continuation in
            streamContinuation = continuation
        }
        continuation = streamContinuation
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
