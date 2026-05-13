import XCTest
@testable import MeetingAgentCore

final class SpeakerAudioEvidenceStoreTests: XCTestCase {
    func testWritesClipFromTranscriptSegmentTimeRange() throws {
        let store = SpeakerAudioEvidenceStore(retentionDurationSeconds: 10)
        store.append([
            frame(byte: 1, timestampNanos: 1),
            frame(byte: 2, timestampNanos: 2),
            frame(byte: 3, timestampNanos: 3)
        ])
        let destination = temporaryDirectory().appendingPathComponent("speaker.wav")

        let clip = try store.writeClip(
            for: [
                TranscriptSegment(
                    speaker: TranscriptSpeaker(identifier: "speaker-a"),
                    startTimeSeconds: 1,
                    endTimeSeconds: 2,
                    text: "hello",
                    isFinal: true
                )
            ],
            to: destination,
            minimumDurationSeconds: 1
        )

        let unwrappedClip = try XCTUnwrap(clip)
        XCTAssertEqual(unwrappedClip.durationSeconds, 1, accuracy: 0.0001)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        let data = try Data(contentsOf: destination)
        XCTAssertGreaterThan(data.count, 44)
        XCTAssertEqual(Array(data.suffix(4)), [2, 2, 2, 2])
    }

    func testReturnsNilWhenUsableDurationIsTooShort() throws {
        let store = SpeakerAudioEvidenceStore(retentionDurationSeconds: 10)
        store.append([frame(byte: 1, timestampNanos: 1)])

        let clip = try store.writeClip(
            for: [
                TranscriptSegment(startTimeSeconds: 0, endTimeSeconds: 1, text: "short", isFinal: true)
            ],
            to: temporaryDirectory().appendingPathComponent("short.wav"),
            minimumDurationSeconds: 2
        )

        XCTAssertNil(clip)
    }

    func testPrunesFramesOutsideRetentionWindow() throws {
        let store = SpeakerAudioEvidenceStore(retentionDurationSeconds: 2)
        store.append([
            frame(byte: 1, timestampNanos: 1),
            frame(byte: 2, timestampNanos: 2),
            frame(byte: 3, timestampNanos: 3),
            frame(byte: 4, timestampNanos: 4)
        ])

        let clip = try store.writeClip(
            for: [
                TranscriptSegment(startTimeSeconds: 0, endTimeSeconds: 1, text: "old", isFinal: true)
            ],
            to: temporaryDirectory().appendingPathComponent("old.wav"),
            minimumDurationSeconds: 1
        )

        XCTAssertNil(clip)
    }

    func testResetClearsBufferedEvidence() throws {
        let store = SpeakerAudioEvidenceStore(retentionDurationSeconds: 10)
        store.append([frame(byte: 1, timestampNanos: 1)])
        store.reset()

        let clip = try store.writeClip(
            for: [
                TranscriptSegment(startTimeSeconds: 0, endTimeSeconds: 1, text: "gone", isFinal: true)
            ],
            to: temporaryDirectory().appendingPathComponent("reset.wav"),
            minimumDurationSeconds: 1
        )

        XCTAssertNil(clip)
    }

    private func frame(byte: UInt8, timestampNanos: UInt64) -> AudioFrame {
        AudioFrame(
            pcm: Data(repeating: byte, count: 4),
            sampleRate: 2,
            channelCount: 1,
            timestampNanos: timestampNanos
        )
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakerAudioEvidenceStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
