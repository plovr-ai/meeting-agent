import XCTest
@testable import MeetingAgentCore

final class AudioFrameRingBufferTests: XCTestCase {
    func testPushWakesAsyncBatchConsumer() async throws {
        let buffer = AudioFrameRingBuffer(capacity: 4)
        let frame = AudioFrame(pcm: Data([1]), sampleRate: 16_000, channelCount: 1, timestampNanos: 1)
        var iterator = buffer.batches.makeAsyncIterator()

        buffer.push(frame)

        let batch = await iterator.next()
        XCTAssertEqual(batch, [frame])
    }

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

    func testReportsBacklogAndDroppedFrameCount() {
        let buffer = AudioFrameRingBuffer(capacity: 2)

        buffer.push(AudioFrame(pcm: Data([1]), sampleRate: 16_000, channelCount: 1, timestampNanos: 1))
        buffer.push(AudioFrame(pcm: Data([2]), sampleRate: 16_000, channelCount: 1, timestampNanos: 2))
        buffer.push(AudioFrame(pcm: Data([3]), sampleRate: 16_000, channelCount: 1, timestampNanos: 3))

        XCTAssertEqual(buffer.count, 2)
        XCTAssertEqual(buffer.droppedFrameCount, 1)
        _ = buffer.drain()
        XCTAssertEqual(buffer.count, 0)
        XCTAssertEqual(buffer.droppedFrameCount, 1)
    }

    func testAsyncBatchConsumerDrainsAllAvailableFramesTogether() async throws {
        let buffer = AudioFrameRingBuffer(capacity: 4)
        let first = AudioFrame(pcm: Data([1]), sampleRate: 16_000, channelCount: 1, timestampNanos: 1)
        let second = AudioFrame(pcm: Data([2]), sampleRate: 16_000, channelCount: 1, timestampNanos: 2)
        var iterator = buffer.batches.makeAsyncIterator()

        buffer.push(first)
        buffer.push(second)

        let batch = await iterator.next()
        XCTAssertEqual(batch, [first, second])
        XCTAssertEqual(buffer.count, 0)
    }

    func testAsyncBatchConsumerReceivesNewestFramesAfterOverflow() async throws {
        let buffer = AudioFrameRingBuffer(capacity: 2)
        let first = AudioFrame(pcm: Data([1]), sampleRate: 16_000, channelCount: 1, timestampNanos: 1)
        let second = AudioFrame(pcm: Data([2]), sampleRate: 16_000, channelCount: 1, timestampNanos: 2)
        let third = AudioFrame(pcm: Data([3]), sampleRate: 16_000, channelCount: 1, timestampNanos: 3)
        var iterator = buffer.batches.makeAsyncIterator()

        buffer.push(first)
        buffer.push(second)
        buffer.push(third)

        let batch = await iterator.next()
        XCTAssertEqual(batch, [second, third])
        XCTAssertEqual(buffer.droppedFrameCount, 1)
    }

    func testFinishEndsAsyncBatchConsumer() async throws {
        let buffer = AudioFrameRingBuffer(capacity: 2)
        var iterator = buffer.batches.makeAsyncIterator()

        buffer.finish()

        let batch = await iterator.next()
        XCTAssertNil(batch)
    }
}
