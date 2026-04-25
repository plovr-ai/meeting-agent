import XCTest
@testable import CoreAudioTapProbe

final class AudioFrameRingBufferTests: XCTestCase {
    func testPushAndDrainPreservesOrder() {
        let buffer = AudioFrameRingBuffer(capacity: 3)
        let first = AudioFrame(pcm: Data([1]), sampleRate: 16_000, channelCount: 1, timestampNanos: 1)
        let second = AudioFrame(pcm: Data([2]), sampleRate: 16_000, channelCount: 1, timestampNanos: 2)

        buffer.push(first)
        buffer.push(second)

        XCTAssertEqual(buffer.drain(), [first, second])
        XCTAssertEqual(buffer.drain(), [])
    }

    func testCapacityDropsOldestFrames() {
        let buffer = AudioFrameRingBuffer(capacity: 2)

        buffer.push(AudioFrame(pcm: Data([1]), sampleRate: 16_000, channelCount: 1, timestampNanos: 1))
        buffer.push(AudioFrame(pcm: Data([2]), sampleRate: 16_000, channelCount: 1, timestampNanos: 2))
        buffer.push(AudioFrame(pcm: Data([3]), sampleRate: 16_000, channelCount: 1, timestampNanos: 3))

        XCTAssertEqual(buffer.drain().map(\.pcm), [Data([2]), Data([3])])
    }
}
