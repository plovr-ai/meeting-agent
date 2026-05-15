import XCTest
@testable import MeetingAgentCore

final class WhisperAudioTranscriptionProviderTests: XCTestCase {
    func testDescriptorAdvertisesLocalAudioTranscription() {
        let provider = WhisperAudioTranscriptionProvider(speechProvider: StubSpeechTranscriptionProvider())

        XCTAssertEqual(provider.descriptor.id, "whisper-local")
        XCTAssertEqual(provider.descriptor.capability, .audioTranscription)
        XCTAssertEqual(provider.descriptor.executionMode, .local)
        XCTAssertFalse(provider.descriptor.requiresNetwork)
    }

    func testTranscribeExistingAudioReturnsTranscriptDocument() async throws {
        let provider = WhisperAudioTranscriptionProvider(speechProvider: StubSpeechTranscriptionProvider())

        let document = try await provider.transcribe(
            audio: AudioInput(wavURL: URL(fileURLWithPath: "/tmp/input.wav"), localeIdentifier: "en-US"),
            options: TranscriptionOptions(sourceLocale: "en-US")
        )

        XCTAssertEqual(document.segments.map(\.text), ["hello from whisper"])
        XCTAssertEqual(document.segments.first?.sourceProvider, "whisper-local")
    }
}

private struct StubSpeechTranscriptionProvider: SpeechTranscriptionProvider {
    let provider: SpeechProvider = .whisper

    func start(transcriptURL: URL, localeIdentifier: String) async throws -> AudioFrameTranscriber {
        throw ProbeError.speechRecognition("not used")
    }

    func transcribeExistingAudio(context: SpeechTranscriptionContext) async throws -> TranscriptDocument {
        TranscriptDocument(segments: [
            TranscriptSegment(text: "hello from whisper", language: context.localeIdentifier, sourceProvider: "whisper")
        ])
    }
}
