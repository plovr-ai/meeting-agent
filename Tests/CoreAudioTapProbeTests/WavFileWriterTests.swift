import XCTest
@testable import CoreAudioTapProbe

final class WavFileWriterTests: XCTestCase {
    func testWritesRiffHeaderAndPayload() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("probe-wav-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try WavFileWriter(url: url, sampleRate: 16_000, channelCount: 1)
        try writer.append(AudioFrame(pcm: Data([0x01, 0x00, 0x02, 0x00]), sampleRate: 16_000, channelCount: 1, timestampNanos: 1))
        try writer.close()

        let data = try Data(contentsOf: url)
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data.dropFirst(8).prefix(4), encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: data.dropFirst(36).prefix(4), encoding: .ascii), "data")
        XCTAssertEqual(data.suffix(4), Data([0x01, 0x00, 0x02, 0x00]))
    }
}
