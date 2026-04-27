import XCTest
@testable import MeetingAgentCore

final class LocalAudioPlaybackSinkTests: XCTestCase {
    func testSinkAcceptsEmptyAudioWithoutStartingPlayback() async throws {
        let client = FakeLocalAudioPlaybackClient()
        let sink = LocalAudioPlaybackSink(client: client)

        try await sink.play(Data(), sampleRate: 24_000, channelCount: 1)
        await sink.stop()

        XCTAssertTrue(client.scheduledBuffers.isEmpty)
        XCTAssertEqual(client.stopCallCount, 1)
    }

    func testSinkStartsEngineAndSchedulesDeinterleavedPCMBuffer() async throws {
        let client = FakeLocalAudioPlaybackClient()
        let sink = LocalAudioPlaybackSink(client: client)
        let pcm = Data([
            0x01, 0x00, 0x02, 0x00,
            0x03, 0x00, 0x04, 0x00
        ])

        try await sink.play(pcm, sampleRate: 24_000, channelCount: 2)

        XCTAssertEqual(client.attachedFormats.map(\.sampleRate), [24_000])
        XCTAssertEqual(client.attachedFormats.map(\.channelCount), [2])
        XCTAssertEqual(client.startCallCount, 1)
        XCTAssertEqual(client.playCallCount, 1)
        XCTAssertEqual(client.scheduledBuffers.count, 1)
        XCTAssertEqual(client.scheduledBuffers.first?.sampleRate, 24_000)
        XCTAssertEqual(client.scheduledBuffers.first?.channelCount, 2)
        XCTAssertEqual(client.scheduledBuffers.first?.samplesByChannel, [[1, 3], [2, 4]])
    }

    func testSinkReusesExistingFormatAndDoesNotRestartRunningPlayback() async throws {
        let client = FakeLocalAudioPlaybackClient()
        let sink = LocalAudioPlaybackSink(client: client)

        try await sink.play(Data([1, 0]), sampleRate: 24_000, channelCount: 1)
        try await sink.play(Data([2, 0]), sampleRate: 24_000, channelCount: 1)

        XCTAssertEqual(client.attachedFormats.count, 1)
        XCTAssertEqual(client.startCallCount, 1)
        XCTAssertEqual(client.playCallCount, 1)
        XCTAssertEqual(client.scheduledBuffers.map(\.samplesByChannel), [[[1]], [[2]]])
    }

    func testPlayRejectsMisalignedPCMDataBeforeStartingPlayback() async {
        let client = FakeLocalAudioPlaybackClient()
        let sink = LocalAudioPlaybackSink(client: client)

        await XCTAssertThrowsErrorAsync(
            try await sink.play(Data([1, 2, 3]), sampleRate: 24_000, channelCount: 2)
        ) { error in
            XCTAssertEqual(String(describing: error), "Invalid arguments: Playback PCM data is not aligned to 16-bit samples")
        }

        XCTAssertTrue(client.attachedFormats.isEmpty)
        XCTAssertTrue(client.scheduledBuffers.isEmpty)
    }

    func testAVFoundationClientRejectsUnsupportedPlaybackFormats() async {
        let client = AVFoundationLocalAudioPlaybackClient()

        XCTAssertThrowsError(try client.attachIfNeeded(format: LocalAudioPlaybackFormat(sampleRate: 0, channelCount: 0)))
        await XCTAssertThrowsErrorAsync(
            try await client.schedule(LocalAudioPlaybackBuffer(
                format: LocalAudioPlaybackFormat(sampleRate: 0, channelCount: 0),
                samplesByChannel: []
            ))
        )
        client.stop()
    }

}

private final class FakeLocalAudioPlaybackClient: LocalAudioPlaybackClient {
    var isAttached = false
    var isEngineRunning = false
    var isPlayerPlaying = false
    var attachedFormats: [LocalAudioPlaybackFormat] = []
    var scheduledBuffers: [LocalAudioPlaybackBuffer] = []
    var startCallCount = 0
    var playCallCount = 0
    var stopCallCount = 0

    func attachIfNeeded(format: LocalAudioPlaybackFormat) {
        guard !isAttached else { return }
        isAttached = true
        attachedFormats.append(format)
    }

    func startEngineIfNeeded() throws {
        guard !isEngineRunning else { return }
        isEngineRunning = true
        startCallCount += 1
    }

    func playIfNeeded() {
        guard !isPlayerPlaying else { return }
        isPlayerPlaying = true
        playCallCount += 1
    }

    func schedule(_ buffer: LocalAudioPlaybackBuffer) async {
        scheduledBuffers.append(buffer)
    }

    func stop() {
        stopCallCount += 1
        isEngineRunning = false
        isPlayerPlaying = false
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> some Any,
    _ verify: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error to be thrown", file: file, line: line)
    } catch {
        verify(error)
    }
}
