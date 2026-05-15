import XCTest
@testable import MeetingAgentCore

final class SpeechEventSpeakerAttributionTests: XCTestCase {
    func testMicrophoneAttributionRewritesHypothesisAndFinalSpeakerToMe() {
        let sink = RecordingSpeechEventSink()
        let attributed = MicrophoneSpeakerAttributionSink(downstream: sink)
        let payload = speechPayload(
            speaker: TranscriptSpeaker(identifier: "provider-speaker-7", label: "Speaker 7"),
            text: "I can take the launch follow-up"
        )

        attributed.receive(.hypothesis(payload))
        attributed.receive(.final(payload))

        XCTAssertEqual(sink.events.map { $0.payload?.speaker }, [
            TranscriptSpeaker(identifier: "local-user", label: "Me"),
            TranscriptSpeaker(identifier: "local-user", label: "Me")
        ])
    }

    func testMicrophoneAttributionPreservesPayloadFields() {
        let payload = speechPayload(
            speaker: TranscriptSpeaker(identifier: "provider-speaker-7", label: "Speaker 7"),
            text: "I can take the launch follow-up"
        )

        let attributed = MicrophoneSpeakerAttributionSink.attributed(.final(payload))

        XCTAssertEqual(attributed.payload?.providerID, payload.providerID)
        XCTAssertEqual(attributed.payload?.providerResultID, payload.providerResultID)
        XCTAssertEqual(attributed.payload?.providerUtteranceID, payload.providerUtteranceID)
        XCTAssertEqual(attributed.payload?.startTimeSeconds, payload.startTimeSeconds)
        XCTAssertEqual(attributed.payload?.endTimeSeconds, payload.endTimeSeconds)
        XCTAssertEqual(attributed.payload?.text, payload.text)
        XCTAssertEqual(attributed.payload?.language, payload.language)
        XCTAssertEqual(attributed.payload?.confidence, payload.confidence)
        XCTAssertEqual(attributed.payload?.boundary, payload.boundary)
    }

    func testMicrophoneAttributionLeavesProviderStatusUnchanged() {
        let sink = RecordingSpeechEventSink()
        let attributed = MicrophoneSpeakerAttributionSink(downstream: sink)
        let status = ProviderStatus(providerID: "deepgram-transcribe", message: "connected")

        attributed.receive(.providerStatus(status))

        XCTAssertEqual(sink.events, [.providerStatus(status)])
    }

    func testMicrophoneAttributionRewritesTranscriptSegmentUpdatesToMe() {
        let sink = RecordingTranscriptAndSpeechEventSink()
        let attributed = MicrophoneSpeakerAttributionSink(downstream: sink)
        let segment = TranscriptSegment(
            id: "segment-1",
            speaker: TranscriptSpeaker(identifier: "provider-speaker-7", label: "Speaker 7"),
            startTimeSeconds: 1,
            endTimeSeconds: 2,
            text: "I can take the launch follow-up",
            language: "en-US",
            sourceProvider: "whisper",
            isFinal: true
        )

        attributed.receive(.upsert(segment))
        attributed.receiveRealtime(.replaceAll([segment]))

        XCTAssertEqual(sink.receivedUpdates.first, .upsert(segment.withSpeaker(
            TranscriptSpeaker(identifier: "local-user", label: "Me")
        )))
        guard case .replaceAll(let realtimeSegments)? = sink.receivedRealtimeUpdates.first else {
            return XCTFail("Expected attributed replaceAll")
        }
        XCTAssertEqual(realtimeSegments.first?.speakerID, "local-user")
        XCTAssertEqual(realtimeSegments.first?.speakerLabel, "Me")
    }

    private func speechPayload(speaker: TranscriptSpeaker?, text: String) -> SpeechUtterancePayload {
        SpeechUtterancePayload(
            providerID: "deepgram-transcribe",
            providerResultID: "result-1",
            providerUtteranceID: "utt-1",
            speaker: speaker,
            startTimeSeconds: 1,
            endTimeSeconds: 2,
            text: text,
            language: "en-US",
            confidence: 0.91,
            boundary: SpeechBoundary(speechFinal: true)
        )
    }
}

private final class RecordingSpeechEventSink: SpeechRecognitionEventSink {
    private(set) var events: [SpeechRecognitionEvent] = []

    func receive(_ event: SpeechRecognitionEvent) {
        events.append(event)
    }
}

private final class RecordingTranscriptAndSpeechEventSink: TranscriptUpdateSink, SpeechRecognitionEventSink {
    private(set) var events: [SpeechRecognitionEvent] = []
    private(set) var receivedUpdates: [TranscriptSegmentUpdate] = []
    private(set) var receivedRealtimeUpdates: [TranscriptSegmentUpdate] = []
    private(set) var receivedFinalUpdates: [TranscriptSegmentUpdate] = []

    func receive(_ event: SpeechRecognitionEvent) {
        events.append(event)
    }

    func receive(_ update: TranscriptSegmentUpdate) {
        receivedUpdates.append(update)
    }

    func receiveRealtime(_ update: TranscriptSegmentUpdate) {
        receivedRealtimeUpdates.append(update)
    }

    func receiveFinal(_ update: TranscriptSegmentUpdate) {
        receivedFinalUpdates.append(update)
    }
}
