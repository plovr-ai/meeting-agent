import Foundation
import XCTest
@testable import MeetingAgentCore

final class AliyunRealtimeTranscriptionProviderTests: XCTestCase {
    func testDecoderMapsTaskEventsAndGeneratedResults() throws {
        let started = try AliyunRealtimeTranscriptionEventDecoder.decode(Data("""
        {"header":{"event":"task-started","task_id":"task-1"},"payload":{}}
        """.utf8))
        let generated = try AliyunRealtimeTranscriptionEventDecoder.decode(Data("""
        {"header":{"event":"result-generated","task_id":"task-1"},"payload":{"output":{"sentence":{"text":"大家好","begin_time":120,"end_time":950,"sentence_end":false}}}}
        """.utf8))
        let finished = try AliyunRealtimeTranscriptionEventDecoder.decode(Data("""
        {"header":{"event":"task-finished","task_id":"task-1"},"payload":{}}
        """.utf8))
        let failed = try AliyunRealtimeTranscriptionEventDecoder.decode(Data("""
        {"header":{"event":"task-failed","task_id":"task-1","error_message":"bad request"},"payload":{}}
        """.utf8))

        XCTAssertEqual(started, .started(taskID: "task-1"))
        XCTAssertEqual(generated, .result(
            taskID: "task-1",
            text: "大家好",
            beginTimeMilliseconds: 120,
            endTimeMilliseconds: 950,
            sentenceEnd: false
        ))
        XCTAssertEqual(finished, .finished(taskID: "task-1"))
        XCTAssertEqual(failed, .failed(taskID: "task-1", message: "bad request"))
    }

    func testProviderStartsTaskSendsBinaryAudioAndPublishesRealtimeSegments() async throws {
        let transport = FakeAliyunRealtimeTransport()
        let updateSink = RecordingAliyunTranscriptUpdateSink()
        let provider = AliyunRealtimeTranscriptionProvider(
            apiKey: "dashscope-key",
            model: "paraformer-realtime-v2",
            transportFactory: { _, _ in transport },
            taskIDFactory: { "task-1" }
        )

        let transcriber = try await provider.start(context: SpeechTranscriptionStreamContext(
            transcriptURL: temporaryURL("transcript.txt"),
            localeIdentifier: "zh-CN",
            sampleRate: 16_000,
            channelCount: 1,
            transcriptUpdateSink: updateSink
        ))

        XCTAssertTrue(transport.connected)
        XCTAssertEqual(transport.textMessages.count, 1)
        XCTAssertTrue(transport.textMessages[0].contains("\"action\":\"run-task\""))
        XCTAssertTrue(transport.textMessages[0].contains("\"model\":\"paraformer-realtime-v2\""))
        XCTAssertTrue(transport.textMessages[0].contains("\"language_hints\":[\"zh\"]"))

        transport.yield("""
        {"header":{"event":"task-started","task_id":"task-1"},"payload":{}}
        """)
        try await Task.sleep(nanoseconds: 50_000_000)

        let frame = AudioFrame(pcm: Data([1, 2, 3, 4]), sampleRate: 16_000, channelCount: 1, timestampNanos: 0)
        try transcriber.append(frame)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(transport.binaryMessages, [frame.pcm])

        transport.yield("""
        {"header":{"event":"result-generated","task_id":"task-1"},"payload":{"output":{"sentence":{"text":"大家好","begin_time":100,"end_time":800,"sentence_end":true}}}}
        """)
        try await Task.sleep(nanoseconds: 50_000_000)

        transcriber.finish()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(transport.textMessages.contains { $0.contains("\"action\":\"finish-task\"") })
        XCTAssertEqual(updateSink.updates.count, 1)
        guard case .upsert(let segment) = updateSink.updates[0] else {
            return XCTFail("Expected upsert update")
        }
        XCTAssertEqual(segment.text, "大家好")
        XCTAssertEqual(segment.language, "zh-CN")
        XCTAssertEqual(segment.sourceProvider, SpeechTranscriptionConfiguration.defaultAliyunRealtimeTranscriptionProviderID)
        XCTAssertEqual(segment.speakerID, "aliyun-paraformer-realtime-speaker-0")
        XCTAssertEqual(segment.startTimeSeconds, 0.1)
        XCTAssertEqual(segment.endTimeSeconds, 0.8)
        XCTAssertTrue(segment.isFinal)
    }

    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(name)
    }
}

private final class FakeAliyunRealtimeTransport: AliyunRealtimeWebSocketTransport {
    private var continuation: AsyncStream<Data>.Continuation!
    let incomingMessages: AsyncStream<Data>
    private(set) var connected = false
    private(set) var closed = false
    private(set) var textMessages: [String] = []
    private(set) var binaryMessages: [Data] = []

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

    func sendText(_ text: String) async throws {
        textMessages.append(text)
    }

    func sendBinary(_ data: Data) async throws {
        binaryMessages.append(data)
    }

    func close() async {
        closed = true
        continuation.finish()
    }

    func yield(_ text: String) {
        continuation.yield(Data(text.utf8))
    }
}

private final class RecordingAliyunTranscriptUpdateSink: TranscriptUpdateSink {
    private(set) var updates: [TranscriptSegmentUpdate] = []

    func receive(_ update: TranscriptSegmentUpdate) {
        updates.append(update)
    }
}
