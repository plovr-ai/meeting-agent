import XCTest
@testable import MeetingAgentCore

final class DeepgramTranscriptReconcilerTests: XCTestCase {
    func testInterimEmitsRealtimeOnly() {
        var reconciler = DeepgramTranscriptReconciler()

        let output = reconciler.apply(segment(
            id: "deepgram-transcribe-stream-0.0",
            start: 0.0,
            end: 0.8,
            text: "hello interim",
            isFinal: false,
            speechFinal: false
        ))

        XCTAssertEqual(output.realtimeUpdates.count, 1)
        XCTAssertEqual(output.finalUpdates, [])
        XCTAssertEqual(output.finalDocument.segments, [])
        XCTAssertEqual(output.realtimeUpdates.first?.source, .realtime)
    }

    func testFinalPersistsAndEmitsRealtime() {
        var reconciler = DeepgramTranscriptReconciler()

        let output = reconciler.apply(segment(
            id: "deepgram-transcribe-stream-0.0",
            start: 0.0,
            end: 0.8,
            text: "hello final",
            isFinal: true,
            speechFinal: true
        ))

        XCTAssertEqual(output.realtimeUpdates.count, 1)
        XCTAssertEqual(output.finalUpdates.count, 1)
        XCTAssertEqual(output.finalDocument.segments.map(\.text), ["hello final"])
        XCTAssertEqual(output.finalDocument.segments.map(\.speechFinal), [true])
        XCTAssertEqual(output.finalUpdates.first?.source, .final)
    }

    func testMultipleFinalSegmentsBeforeSpeechFinalAreAccumulated() {
        var reconciler = DeepgramTranscriptReconciler()

        _ = reconciler.apply(segment(
            id: "deepgram-transcribe-stream-0.0",
            start: 0.0,
            end: 1.0,
            text: "first final",
            isFinal: true,
            speechFinal: false
        ))
        let output = reconciler.apply(segment(
            id: "deepgram-transcribe-stream-1.0",
            start: 1.0,
            end: 2.0,
            text: "second final",
            isFinal: true,
            speechFinal: true
        ))

        XCTAssertEqual(output.finalDocument.segments.map(\.text), ["first final", "second final"])
        XCTAssertEqual(output.finalDocument.segments.map(\.speechFinal), [false, true])
    }

    func testOverlappingFinalTimingReplacesInsteadOfAppending() {
        var reconciler = DeepgramTranscriptReconciler()

        _ = reconciler.apply(segment(
            id: "deepgram-transcribe-stream-0.0",
            start: 0.0,
            end: 1.0,
            text: "old words",
            isFinal: true,
            speechFinal: false
        ))
        let output = reconciler.apply(segment(
            id: "deepgram-transcribe-stream-0.02",
            start: 0.02,
            end: 1.02,
            text: "corrected words",
            isFinal: true,
            speechFinal: false
        ))

        XCTAssertEqual(output.finalDocument.segments.map(\.text), ["corrected words"])
    }

    func testIdenticalTextWithNonOverlappingTimingIsPreserved() {
        var reconciler = DeepgramTranscriptReconciler()

        _ = reconciler.apply(segment(
            id: "deepgram-transcribe-stream-0.0",
            start: 0.0,
            end: 0.5,
            text: "yes",
            isFinal: true,
            speechFinal: false
        ))
        let output = reconciler.apply(segment(
            id: "deepgram-transcribe-stream-0.7",
            start: 0.7,
            end: 1.1,
            text: "yes",
            isFinal: true,
            speechFinal: true
        ))

        XCTAssertEqual(output.finalDocument.segments.map(\.text), ["yes", "yes"])
    }

    func testMissingTimingAppendsConservatively() {
        var reconciler = DeepgramTranscriptReconciler()

        _ = reconciler.apply(TranscriptSegment(
            id: "deepgram-transcribe-stream-active-0",
            text: "repeat",
            sourceProvider: "deepgram-transcribe",
            isFinal: true,
            timingSource: .unavailable
        ))
        let output = reconciler.apply(TranscriptSegment(
            id: "deepgram-transcribe-stream-active-1",
            text: "repeat",
            sourceProvider: "deepgram-transcribe",
            isFinal: true,
            timingSource: .unavailable
        ))

        XCTAssertEqual(output.finalDocument.segments.map(\.text), ["repeat", "repeat"])
    }

    private func segment(
        id: String,
        start: Double,
        end: Double,
        text: String,
        isFinal: Bool,
        speechFinal: Bool
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            speaker: TranscriptSpeaker(identifier: "deepgram-speaker-0"),
            startTimeSeconds: start,
            endTimeSeconds: end,
            text: text,
            sourceProvider: "deepgram-transcribe",
            isFinal: isFinal,
            speechFinal: speechFinal,
            timingSource: .precise
        )
    }
}
