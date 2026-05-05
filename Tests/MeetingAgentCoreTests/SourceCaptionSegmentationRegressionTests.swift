import XCTest
@testable import MeetingAgentCore

final class SourceCaptionSegmentationRegressionTests: XCTestCase {
    func testLatestWavFixtureDurationMatchesCapturedMeeting() throws {
        let wav = try latestSourceCaptionRegressionWav()

        XCTAssertEqual(wav.sampleRate, 48_000)
        XCTAssertEqual(wav.channelCount, 1)
        XCTAssertEqual(wav.bitsPerSample, 16)
        XCTAssertEqual(wav.durationSeconds, 58.58, accuracy: 0.1)
    }

    func testLatestWavProviderFinalChunksDoNotSealWithoutEndpointOrEndingPunctuation() {
        var assembler = CaptionTurnAssembler(sourceLocale: "en-US", targetLocale: "zh-CN")
        let events = latestWavProviderFinalChunksWithoutEndpoint().flatMap { segment in
            assembler.apply(segment)
        }

        XCTAssertFalse(events.contains { event in
            if case .sealed = event { return true }
            return false
        })
    }

    func testLatestWavOverlappingInterimAndFinalSegmentsDoNotDuplicateSourceText() {
        var accumulator = TranscriptSegmentAccumulator()
        for segment in latestWavOverlappingSegments() {
            _ = accumulator.apply(.upsert(segment))
        }

        let sourceText = accumulator.currentDocument.segments
            .map(\.text)
            .joined(separator: " ")
            .lowercased()

        XCTAssertFalse(sourceText.contains("to be able to take to be able to take"))
    }

    private func latestWavProviderFinalChunksWithoutEndpoint() -> [TranscriptSegment] {
        [
            TranscriptSegment(
                id: "deepgram-transcribe-stream-0.0",
                speaker: TranscriptSpeaker(identifier: "deepgram-speaker-0"),
                startTimeSeconds: 0,
                endTimeSeconds: 4.24,
                text: "This is our Microsoft Teams public preview page, and I'll drop the link in the",
                language: "en-US",
                sourceProvider: SpeechTranscriptionConfiguration.defaultDeepgramTranscriptionProviderID,
                isFinal: true,
                speechFinal: false
            ),
            TranscriptSegment(
                id: "deepgram-transcribe-stream-4.43",
                speaker: TranscriptSpeaker(identifier: "deepgram-speaker-0"),
                startTimeSeconds: 4.43,
                endTimeSeconds: 8.75,
                text: "description. But, basically, first off, it says note, features included in preview might not",
                language: "en-US",
                sourceProvider: SpeechTranscriptionConfiguration.defaultDeepgramTranscriptionProviderID,
                isFinal: true,
                speechFinal: false
            )
        ]
    }

    private func latestWavOverlappingSegments() -> [TranscriptSegment] {
        [
            TranscriptSegment(
                id: "deepgram-transcribe-stream-44.34",
                speaker: TranscriptSpeaker(identifier: "deepgram-speaker-0"),
                startTimeSeconds: 44.34,
                endTimeSeconds: 46.9,
                text: "inside Microsoft Teams, are outlined here,",
                language: "en-US",
                sourceProvider: SpeechTranscriptionConfiguration.defaultDeepgramTranscriptionProviderID,
                isFinal: true,
                speechFinal: false
            ),
            TranscriptSegment(
                id: "deepgram-transcribe-stream-44.5",
                speaker: TranscriptSpeaker(identifier: "deepgram-speaker-0"),
                startTimeSeconds: 44.5,
                endTimeSeconds: 48.42,
                text: "inside Microsoft Teams, which are outlined here, to be able to take",
                language: "en-US",
                sourceProvider: SpeechTranscriptionConfiguration.defaultDeepgramTranscriptionProviderID,
                isFinal: false,
                speechFinal: false
            ),
            TranscriptSegment(
                id: "deepgram-transcribe-stream-47.52",
                speaker: TranscriptSpeaker(identifier: "deepgram-speaker-0"),
                startTimeSeconds: 47.52,
                endTimeSeconds: 52.08,
                text: "to be able to take advantage of these public preview features. So inside the new Teams client,",
                language: "en-US",
                sourceProvider: SpeechTranscriptionConfiguration.defaultDeepgramTranscriptionProviderID,
                isFinal: true,
                speechFinal: false
            )
        ]
    }

    private func latestSourceCaptionRegressionWav() throws -> WavInfo {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Tests/MeetingAgentCoreTests/Fixtures/latest-source-caption-regression.wav")
        let data = try Data(contentsOf: url)
        return try WavInfo(data: data)
    }
}

private struct WavInfo {
    let sampleRate: Int
    let channelCount: Int
    let bitsPerSample: Int
    let durationSeconds: Double

    init(data: Data) throws {
        guard data.count >= 44,
              String(data: data[0..<4], encoding: .ascii) == "RIFF",
              String(data: data[8..<12], encoding: .ascii) == "WAVE" else {
            throw NSError(domain: "WavInfo", code: 1)
        }
        var offset = 12
        var sampleRate: Int?
        var channelCount: Int?
        var bitsPerSample: Int?
        var dataByteCount: Int?
        while offset + 8 <= data.count {
            let id = String(data: data[offset..<(offset + 4)], encoding: .ascii)
            let size = Int(Self.uint32(data, offset + 4))
            let payload = offset + 8
            guard payload + size <= data.count else { break }
            if id == "fmt " {
                channelCount = Int(Self.uint16(data, payload + 2))
                sampleRate = Int(Self.uint32(data, payload + 4))
                bitsPerSample = Int(Self.uint16(data, payload + 14))
            } else if id == "data" {
                dataByteCount = size
            }
            offset = payload + size + (size % 2)
        }
        guard let sampleRate,
              let channelCount,
              let bitsPerSample,
              let dataByteCount else {
            throw NSError(domain: "WavInfo", code: 2)
        }
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitsPerSample = bitsPerSample
        let bytesPerSecond = Double(sampleRate * channelCount * bitsPerSample / 8)
        self.durationSeconds = Double(dataByteCount) / bytesPerSecond
    }

    private static func uint16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
