import XCTest
@testable import MeetingAgentCore

final class AudioSilenceDetectorTests: XCTestCase {
    func testDetectsZeroPCMAsSilent() {
        let detector = AudioSilenceDetector()
        let frame = AudioFrame(pcm: pcm([0, 0, 0]), sampleRate: 16_000, channelCount: 1, timestampNanos: 1)

        XCTAssertTrue(detector.isSilent(frame))
    }

    func testDetectsLowAmplitudePCMAsSilent() {
        let detector = AudioSilenceDetector(amplitudeThreshold: 4)
        let frame = AudioFrame(pcm: pcm([-4, 0, 4]), sampleRate: 16_000, channelCount: 1, timestampNanos: 1)

        XCTAssertTrue(detector.isSilent(frame))
    }

    func testDetectsVoicedPCMAsNonSilent() {
        let detector = AudioSilenceDetector(amplitudeThreshold: 4)
        let frame = AudioFrame(pcm: pcm([0, 5]), sampleRate: 16_000, channelCount: 1, timestampNanos: 1)

        XCTAssertFalse(detector.isSilent(frame))
    }

    func testTreatsEmptyOrMalformedPCMAsNonSilent() {
        let detector = AudioSilenceDetector()

        XCTAssertFalse(detector.isSilent(AudioFrame(pcm: Data(), sampleRate: 16_000, channelCount: 1, timestampNanos: 1)))
        XCTAssertFalse(detector.isSilent(AudioFrame(pcm: Data([0]), sampleRate: 16_000, channelCount: 1, timestampNanos: 1)))
    }
}

private func pcm(_ samples: [Int16]) -> Data {
    var data = Data()
    for sample in samples {
        var littleEndian = sample.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
    return data
}
