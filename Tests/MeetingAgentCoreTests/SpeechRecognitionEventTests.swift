import XCTest
@testable import MeetingAgentCore

final class SpeechRecognitionEventTests: XCTestCase {
    func testPayloadNormalizesBlankProviderUtteranceID() {
        let payload = SpeechUtterancePayload(
            providerID: " deepgram-transcribe ",
            providerResultID: " result-1 ",
            providerUtteranceID: " ",
            speaker: TranscriptSpeaker(identifier: " speaker-0 ", label: " Alice "),
            startTimeSeconds: 1,
            endTimeSeconds: 2,
            text: " hello ",
            language: " zh-CN ",
            confidence: 0.9,
            boundary: SpeechBoundary(speechFinal: false, punctuationFinal: false, pauseDurationSeconds: nil)
        )

        XCTAssertEqual(payload.providerID, "deepgram-transcribe")
        XCTAssertEqual(payload.providerResultID, "result-1")
        XCTAssertNil(payload.providerUtteranceID)
        XCTAssertEqual(payload.speaker, TranscriptSpeaker(identifier: "speaker-0", label: "Alice"))
        XCTAssertEqual(payload.text, "hello")
        XCTAssertEqual(payload.language, "zh-CN")
        XCTAssertEqual(payload.fallbackKey.providerID, "deepgram-transcribe")
        XCTAssertEqual(payload.fallbackKey.speakerID, "speaker-0")
    }

    func testPunctuationBoundaryDetectsChineseSentenceEnd() {
        XCTAssertTrue(SpeechBoundary.detectsPunctuationFinal(in: "我们确认负责人。"))
        XCTAssertTrue(SpeechBoundary.detectsPunctuationFinal(in: "可以吗？"))
        XCTAssertTrue(SpeechBoundary.detectsPunctuationFinal(in: "好的! "))
        XCTAssertFalse(SpeechBoundary.detectsPunctuationFinal(in: "我们确认负责人"))
    }

    func testRecognitionEventExposesPayloadState() {
        let payload = SpeechUtterancePayload(
            providerID: "deepgram-transcribe",
            providerResultID: "result-1",
            providerUtteranceID: "utt-1",
            speaker: nil,
            startTimeSeconds: nil,
            endTimeSeconds: nil,
            text: "实时修正",
            language: nil,
            confidence: nil,
            boundary: SpeechBoundary()
        )

        XCTAssertEqual(SpeechRecognitionEvent.hypothesis(payload).payload, payload)
        XCTAssertFalse(SpeechRecognitionEvent.hypothesis(payload).isFinal)
        XCTAssertTrue(SpeechRecognitionEvent.final(payload).isFinal)
        XCTAssertNil(SpeechRecognitionEvent.providerStatus(ProviderStatus(providerID: "deepgram", message: "ready")).payload)
    }

    func testProviderStatusAndBoundaryHelpersNormalizeInputs() {
        let status = ProviderStatus(providerID: " ", message: " ready ")

        XCTAssertEqual(status.providerID, "unknown")
        XCTAssertEqual(status.message, "ready")
        XCTAssertFalse(SpeechBoundary().endsTurn)
        XCTAssertTrue(SpeechBoundary(speechFinal: true).endsTurn)
        XCTAssertTrue(SpeechBoundary(punctuationFinal: true).endsTurn)
        XCTAssertTrue(SpeechBoundary(pauseDurationSeconds: 0.7).endsTurn)
        XCTAssertEqual(
            SpeechUtteranceKey(providerID: " ", speakerID: " speaker-1 ", startTimeSeconds: 1.2),
            SpeechUtteranceKey(providerID: "unknown", speakerID: "speaker-1", startTimeSeconds: 1.2)
        )
    }
}
