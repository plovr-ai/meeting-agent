import XCTest
@testable import MeetingAgentCore

final class TranscriptionFailureIsolatorTests: XCTestCase {
    func testAppendSuccessKeepsTranscriberActiveAndFinishDisablesIt() {
        let transcriber = RecordingAppendTranscriber(failureReason: "pending")
        let isolator = TranscriptionFailureIsolator(transcriber: transcriber)
        let frame = AudioFrame(pcm: Data([0x01, 0x00]), sampleRate: 16_000, channelCount: 1, timestampNanos: 1)

        XCTAssertTrue(isolator.isActive)
        XCTAssertEqual(isolator.failureReason, "pending")
        XCTAssertNil(isolator.append(frame))
        XCTAssertEqual(transcriber.appendCount, 1)

        isolator.finish()
        isolator.finish()

        XCTAssertFalse(isolator.isActive)
        XCTAssertNil(isolator.failureReason)
        XCTAssertEqual(transcriber.finishCount, 1)
    }

    func testAppendFailurePublishesTranscriptFailureAndDisablesTranscriber() throws {
        let transcriber = FailingAppendTranscriber()
        let updateSink = RecordingFailureUpdateSink()
        let isolator = TranscriptionFailureIsolator(
            transcriber: transcriber,
            transcriptUpdateSink: updateSink
        )
        let frame = AudioFrame(
            pcm: Data([0x01, 0x00]),
            sampleRate: 16_000,
            channelCount: 1,
            timestampNanos: 1
        )

        let failureMessage = isolator.append(frame)
        let repeatedFailureMessage = isolator.append(frame)

        XCTAssertFalse(isolator.isActive)
        XCTAssertEqual(failureMessage, "Speech recognition failed: Speech recognition error: chunk failed")
        XCTAssertNil(repeatedFailureMessage)
        XCTAssertEqual(transcriber.appendCount, 1)
        XCTAssertEqual(transcriber.finishCount, 1)
        XCTAssertEqual(updateSink.updates.count, 1)
        guard case .replaceWithPlainText(let message) = updateSink.updates.first else {
            return XCTFail("Expected failure plain-text update")
        }
        XCTAssertEqual(message, "Speech recognition failed: Speech recognition error: chunk failed")
    }
}

private final class RecordingAppendTranscriber: AudioFrameTranscriber {
    let failureReason: String?
    private(set) var appendCount = 0
    private(set) var finishCount = 0

    init(failureReason: String?) {
        self.failureReason = failureReason
    }

    func append(_ frame: AudioFrame) throws {
        appendCount += 1
    }

    func finish() {
        finishCount += 1
    }
}

private final class FailingAppendTranscriber: AudioFrameTranscriber {
    private(set) var appendCount = 0
    private(set) var finishCount = 0

    func append(_ frame: AudioFrame) throws {
        appendCount += 1
        throw ProbeError.speechRecognition("chunk failed")
    }

    func finish() {
        finishCount += 1
    }
}

private final class RecordingFailureUpdateSink: TranscriptUpdateSink {
    private(set) var updates: [TranscriptSegmentUpdate] = []

    func receive(_ update: TranscriptSegmentUpdate) {
        updates.append(update)
    }
}
