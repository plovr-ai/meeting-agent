import XCTest
@testable import CoreAudioTapProbe

final class AudioSampleConverterTests: XCTestCase {
    func testConvertsFloat32SamplesToLittleEndianInt16PCM() {
        let samples: [Float32] = [-1.0, -0.5, 0.0, 0.5, 1.0, 2.0, -2.0]
        let input = samples.withUnsafeBytes { Data($0) }

        let output = AudioSampleConverter.float32ToInt16PCM(input)

        XCTAssertEqual(Array(output), [
            0x00, 0x80,
            0x00, 0xC0,
            0x00, 0x00,
            0x00, 0x40,
            0xFF, 0x7F,
            0xFF, 0x7F,
            0x00, 0x80
        ])
    }
}
