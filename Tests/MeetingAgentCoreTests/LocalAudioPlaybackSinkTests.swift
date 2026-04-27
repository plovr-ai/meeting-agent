import XCTest
@testable import MeetingAgentCore

final class LocalAudioPlaybackSinkTests: XCTestCase {
    func testSinkAcceptsEmptyAudioWithoutStartingPlayback() async throws {
        let sink = LocalAudioPlaybackSink()

        try await sink.play(Data(), sampleRate: 24_000, channelCount: 1)
        await sink.stop()
    }
}
