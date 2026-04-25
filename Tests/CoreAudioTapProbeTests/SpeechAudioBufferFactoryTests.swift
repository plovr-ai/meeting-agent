import AVFoundation
import XCTest
@testable import CoreAudioTapProbe

final class SpeechAudioBufferFactoryTests: XCTestCase {
    func testCreatesInterleavedInt16PCMBufferFromAudioFrame() throws {
        let pcm = Data([0x01, 0x00, 0x02, 0x00, 0x03, 0x00, 0x04, 0x00])
        let frame = AudioFrame(pcm: pcm, sampleRate: 16_000, channelCount: 2, timestampNanos: 1)

        let buffer = try SpeechAudioBufferFactory.buffer(from: frame)

        XCTAssertEqual(buffer.format.sampleRate, 16_000)
        XCTAssertEqual(buffer.format.channelCount, 2)
        XCTAssertTrue(buffer.format.isInterleaved)
        XCTAssertEqual(buffer.frameLength, 2)

        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        XCTAssertEqual(Int(buffers[0].mDataByteSize), pcm.count)
        let data = Data(bytes: buffers[0].mData!, count: pcm.count)
        XCTAssertEqual(data, pcm)
    }
}
