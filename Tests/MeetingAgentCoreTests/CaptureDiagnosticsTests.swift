import XCTest
@testable import MeetingAgentCore

final class CaptureDiagnosticsTests: XCTestCase {
    func testDiagnosticsSummarizeAudibleFrames() throws {
        let tracker = CaptureDiagnosticsTracker(
            target: AudioCaptureTarget(
                processID: 42,
                displayName: "Google Chrome",
                bundleIdentifier: "com.google.Chrome"
            )
        )
        let frame = AudioFrame(
            pcm: int16PCM([-16_384, 0, 16_384]),
            sampleRate: 48_000,
            channelCount: 1,
            timestampNanos: 1_000_000_000
        )

        tracker.record(frames: [frame], bufferBacklog: 3, droppedFrameCount: 2)
        tracker.finish(endedReason: .saved)

        let diagnostics = tracker.snapshot()
        XCTAssertEqual(diagnostics.framesCaptured, 3)
        XCTAssertEqual(diagnostics.durationSeconds, 3.0 / 48_000.0, accuracy: 0.000001)
        XCTAssertEqual(diagnostics.lastFrameAt, Date(timeIntervalSince1970: 1))
        XCTAssertEqual(diagnostics.sampleRate, 48_000)
        XCTAssertEqual(diagnostics.channelCount, 1)
        XCTAssertEqual(diagnostics.averageLevel, 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(diagnostics.peakLevel, 0.5, accuracy: 0.0001)
        XCTAssertEqual(diagnostics.silentDurationSeconds, 0)
        XCTAssertEqual(diagnostics.bufferBacklog, 3)
        XCTAssertEqual(diagnostics.droppedFrameCount, 2)
        XCTAssertEqual(diagnostics.startupReplayFrameCount, 0)
        XCTAssertEqual(diagnostics.startupReplayDurationSeconds, 0)
        XCTAssertEqual(diagnostics.startupReplayDroppedFrameCount, 0)
        XCTAssertEqual(diagnostics.targetProcessID, 42)
        XCTAssertEqual(diagnostics.targetDisplayName, "Google Chrome")
        XCTAssertEqual(diagnostics.endedReason, .saved)
        XCTAssertEqual(diagnostics.status, .recordingSaved)
    }

    func testDiagnosticsTrackStartupReplayFrames() {
        let tracker = CaptureDiagnosticsTracker(
            target: AudioCaptureTarget(
                processID: 42,
                displayName: "Google Chrome",
                bundleIdentifier: "com.google.Chrome"
            )
        )
        let frame = AudioFrame(
            pcm: int16PCM([1, 2, 3, 4]),
            sampleRate: 8_000,
            channelCount: 2,
            timestampNanos: 1
        )

        tracker.recordStartupReplay(frames: [frame])
        tracker.recordDroppedStartupReplayFrames(3)

        let diagnostics = tracker.snapshot()
        XCTAssertEqual(diagnostics.startupReplayFrameCount, 1)
        XCTAssertEqual(diagnostics.startupReplayDurationSeconds, 2.0 / 8_000.0, accuracy: 0.000001)
        XCTAssertEqual(diagnostics.startupReplayDroppedFrameCount, 3)
    }

    func testDiagnosticsMarkSilentCapturedAudio() {
        let tracker = CaptureDiagnosticsTracker(
            target: AudioCaptureTarget(
                processID: 10,
                displayName: "zoom.us",
                bundleIdentifier: "us.zoom.xos"
            )
        )
        let frame = AudioFrame(
            pcm: int16PCM([0, 0, 0, 0]),
            sampleRate: 8_000,
            channelCount: 1,
            timestampNanos: 2_000_000_000
        )

        tracker.record(frames: [frame])
        tracker.finish(endedReason: .saved)

        let diagnostics = tracker.snapshot()
        XCTAssertEqual(diagnostics.framesCaptured, 4)
        XCTAssertEqual(diagnostics.averageLevel, 0)
        XCTAssertEqual(diagnostics.peakLevel, 0)
        XCTAssertEqual(diagnostics.silentDurationSeconds, 4.0 / 8_000.0, accuracy: 0.000001)
        XCTAssertEqual(diagnostics.status, .recordingSilentAudio)
    }

    func testDiagnosticsCountSampleFramesForStereoAudio() {
        let tracker = CaptureDiagnosticsTracker(
            target: AudioCaptureTarget(
                processID: 12,
                displayName: "FaceTime",
                bundleIdentifier: "com.apple.FaceTime"
            )
        )
        let frame = AudioFrame(
            pcm: int16PCM([1_000, -1_000, 1_000, -1_000]),
            sampleRate: 8_000,
            channelCount: 2,
            timestampNanos: 3_000_000_000
        )

        tracker.record(frames: [frame])

        let diagnostics = tracker.snapshot()
        XCTAssertEqual(diagnostics.framesCaptured, 2)
        XCTAssertEqual(diagnostics.durationSeconds, 2.0 / 8_000.0, accuracy: 0.000001)
    }


    func testDiagnosticsMarkNoAudioDetectedWhenNoFramesArrive() {
        let tracker = CaptureDiagnosticsTracker(
            target: AudioCaptureTarget(
                processID: 11,
                displayName: "Microsoft Teams",
                bundleIdentifier: "com.microsoft.teams2"
            )
        )

        tracker.finish(endedReason: .saved)

        let diagnostics = tracker.snapshot()
        XCTAssertEqual(diagnostics.framesCaptured, 0)
        XCTAssertEqual(diagnostics.durationSeconds, 0)
        XCTAssertNil(diagnostics.lastFrameAt)
        XCTAssertEqual(diagnostics.status, .recordingNoAudioDetected)
    }

    func testDiagnosticsCanBeSavedAsJSON() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostics-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let diagnostics = CaptureDiagnostics(
            framesCaptured: 10,
            durationSeconds: 0.1,
            lastFrameAt: Date(timeIntervalSince1970: 3),
            sampleRate: 48_000,
            channelCount: 2,
            averageLevel: 0.2,
            peakLevel: 0.8,
            silentDurationSeconds: 0,
            bufferBacklog: 1,
            droppedFrameCount: 0,
            targetProcessID: 99,
            targetDisplayName: "Google Chrome",
            endedReason: .saved,
            status: .recordingSaved
        )

        try diagnostics.write(to: url)

        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder.meetingAgent.decode(CaptureDiagnostics.self, from: data)
        XCTAssertEqual(decoded, diagnostics)
    }

    func testDiagnosticsDecodesLegacyJSONWithoutStartupReplayFields() throws {
        let data = Data("""
        {
          "framesCaptured": 10,
          "durationSeconds": 0.1,
          "sampleRate": 48000,
          "channelCount": 1,
          "averageLevel": 0.2,
          "peakLevel": 0.8,
          "silentDurationSeconds": 0,
          "bufferBacklog": 0,
          "droppedFrameCount": 0,
          "targetProcessID": 99,
          "targetDisplayName": "Google Chrome",
          "endedReason": "saved",
          "status": "recordingSaved"
        }
        """.utf8)

        let decoded = try JSONDecoder.meetingAgent.decode(CaptureDiagnostics.self, from: data)

        XCTAssertEqual(decoded.startupReplayFrameCount, 0)
        XCTAssertEqual(decoded.startupReplayDurationSeconds, 0)
        XCTAssertEqual(decoded.startupReplayDroppedFrameCount, 0)
    }

    private func int16PCM(_ samples: [Int16]) -> Data {
        var data = Data()
        for sample in samples {
            var littleEndian = sample.littleEndian
            data.append(Data(bytes: &littleEndian, count: MemoryLayout<Int16>.size))
        }
        return data
    }
}
