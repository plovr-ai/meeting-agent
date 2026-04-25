import AVFoundation
import XCTest
@testable import MeetingAgentCore

final class SpeechAudioBufferFactoryTests: XCTestCase {
    func testCreatesMonoFloat32PCMBufferFromAudioFrame() throws {
        let pcm = Data([
            0x00, 0x00, 0x00, 0x40,
            0x00, 0x40, 0x00, 0x00
        ])
        let frame = AudioFrame(pcm: pcm, sampleRate: 16_000, channelCount: 2, timestampNanos: 1)

        let buffer = try SpeechAudioBufferFactory.buffer(from: frame)

        XCTAssertEqual(buffer.format.sampleRate, 16_000)
        XCTAssertEqual(buffer.format.channelCount, 1)
        XCTAssertFalse(buffer.format.isInterleaved)
        XCTAssertEqual(buffer.format.commonFormat, .pcmFormatFloat32)
        XCTAssertEqual(buffer.frameLength, 2)

        let samples = try XCTUnwrap(buffer.floatChannelData)
        XCTAssertEqual(Double(samples[0][0]), 0.25, accuracy: 0.0001)
        XCTAssertEqual(Double(samples[0][1]), 0.25, accuracy: 0.0001)
    }
}
