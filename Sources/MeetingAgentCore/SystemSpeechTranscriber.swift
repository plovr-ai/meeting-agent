import AVFoundation
import Foundation
import Speech

enum SpeechAudioBufferFactory {
    static func buffer(from frame: AudioFrame) throws -> AVAudioPCMBuffer {
        let channelCount = max(1, frame.channelCount)
        let bytesPerFrame = MemoryLayout<Int16>.size * channelCount
        guard frame.pcm.count >= bytesPerFrame, frame.pcm.count % bytesPerFrame == 0 else {
            throw ProbeError.speechRecognition("Audio frame is not aligned to 16-bit PCM samples")
        }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: frame.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw ProbeError.speechRecognition("Unable to create Speech audio format")
        }

        let frameCount = AVAudioFrameCount(frame.pcm.count / bytesPerFrame)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw ProbeError.speechRecognition("Unable to create Speech audio buffer")
        }

        buffer.frameLength = frameCount
        guard let destination = buffer.floatChannelData?[0] else {
            throw ProbeError.speechRecognition("Speech audio buffer has no writable storage")
        }

        frame.pcm.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for frameIndex in 0..<Int(frameCount) {
                var mixedSample: Float = 0
                for channelIndex in 0..<channelCount {
                    let byteOffset = (frameIndex * channelCount + channelIndex) * MemoryLayout<Int16>.size
                    let low = UInt16(bytes[byteOffset])
                    let high = UInt16(bytes[byteOffset + 1]) << 8
                    let sample = Int16(bitPattern: high | low)
                    mixedSample += Float(sample) / 32768.0
                }
                destination[frameIndex] = mixedSample / Float(channelCount)
            }
        }

        return buffer
    }
}

struct SystemSpeechRecognitionUpdate {
    let text: String?
    let isFinal: Bool
    let error: Error?

    static func result(text: String, isFinal: Bool) -> Self {
        Self(text: text, isFinal: isFinal, error: nil)
    }

    static func failure(_ error: Error) -> Self {
        Self(text: nil, isFinal: false, error: error)
    }
}

protocol SystemSpeechTasking: AnyObject {
    func finish()
    func cancel()
}

protocol SystemSpeechRequesting: AnyObject {
    func configureForDictation()
    func append(_ buffer: AVAudioPCMBuffer)
    func endAudio()
}

protocol SystemSpeechRecognizing {
    var isAvailable: Bool { get }
    func recognitionTask(
        request: SystemSpeechRequesting,
        onUpdate: @escaping (SystemSpeechRecognitionUpdate) -> Void
    ) -> SystemSpeechTasking?
}

protocol SystemSpeechAuthorizing {
    func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus
}

protocol SystemSpeechWriting: AnyObject {
    func replace(with segments: [TranscriptSegment]) throws
    func close() throws
}

struct SystemSpeechEnvironment {
    let authorizer: SystemSpeechAuthorizing
    let recognizerFactory: (Locale) -> SystemSpeechRecognizing?
    let requestFactory: () -> SystemSpeechRequesting
    let writerFactory: (URL) throws -> SystemSpeechWriting

    static let live = SystemSpeechEnvironment(
        authorizer: LiveSystemSpeechAuthorizer(),
        recognizerFactory: { LiveSystemSpeechRecognizer(locale: $0) },
        requestFactory: { LiveSystemSpeechRequest() },
        writerFactory: { CaptionDocumentSystemSpeechWriter(transcriptURL: $0) }
    )
}

struct LiveSystemSpeechAuthorizer: SystemSpeechAuthorizing {
    func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}

final class LiveSystemSpeechRecognizer: SystemSpeechRecognizing {
    private let recognizer: SFSpeechRecognizer?

    init(locale: Locale) {
        recognizer = SFSpeechRecognizer(locale: locale)
    }

    var isAvailable: Bool {
        recognizer?.isAvailable == true
    }

    func recognitionTask(
        request: SystemSpeechRequesting,
        onUpdate: @escaping (SystemSpeechRecognitionUpdate) -> Void
    ) -> SystemSpeechTasking? {
        guard let liveRequest = request as? LiveSystemSpeechRequest else { return nil }
        return recognizer?.recognitionTask(with: liveRequest.request) { result, error in
            if let result {
                onUpdate(.result(text: result.bestTranscription.formattedString, isFinal: result.isFinal))
            }
            if let error {
                onUpdate(.failure(error))
            }
        }
    }
}

final class LiveSystemSpeechRequest: SystemSpeechRequesting {
    let request = SFSpeechAudioBufferRecognitionRequest()

    func configureForDictation() {
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        request.append(buffer)
    }

    func endAudio() {
        request.endAudio()
    }
}

extension SFSpeechRecognitionTask: SystemSpeechTasking {}
final class SystemSpeechTranscriber: AudioFrameTranscriber {
    private let request: SystemSpeechRequesting
    private let writer: SystemSpeechWriting
    private var task: SystemSpeechTasking?

    private init(request: SystemSpeechRequesting, writer: SystemSpeechWriting) {
        self.request = request
        self.writer = writer
    }

    static func start(transcriptURL: URL, localeIdentifier: String) async throws -> SystemSpeechTranscriber {
        try await start(
            transcriptURL: transcriptURL,
            localeIdentifier: localeIdentifier,
            environment: .live,
            transcriptUpdateSink: nil
        )
    }

    static func start(
        transcriptURL: URL,
        localeIdentifier: String,
        environment: SystemSpeechEnvironment,
        transcriptUpdateSink: TranscriptUpdateSink? = nil
    ) async throws -> SystemSpeechTranscriber {
        try await requestAuthorization(authorizer: environment.authorizer)

        let locale = Locale(identifier: localeIdentifier)
        guard let recognizer = environment.recognizerFactory(locale), recognizer.isAvailable else {
            throw ProbeError.speechRecognition("System speech recognizer is unavailable for locale \(localeIdentifier)")
        }

        let request = environment.requestFactory()
        request.configureForDictation()

        let writer: SystemSpeechWriting
        if let transcriptUpdateSink {
            writer = SystemSpeechUpdateSinkWriter(sink: transcriptUpdateSink)
        } else {
            writer = try environment.writerFactory(transcriptURL)
        }
        let transcriber = SystemSpeechTranscriber(request: request, writer: writer)
        transcriber.task = recognizer.recognitionTask(with: request, localeIdentifier: localeIdentifier, writer: writer)

        return transcriber
    }

    func append(_ frame: AudioFrame) throws {
        request.append(try SpeechAudioBufferFactory.buffer(from: frame))
    }

    func finish() {
        request.endAudio()
        task?.finish()
    }

    deinit {
        task?.cancel()
        try? writer.close()
    }

    private static func requestAuthorization(authorizer: SystemSpeechAuthorizing) async throws {
        let status = await authorizer.requestAuthorization()
        guard status == .authorized else {
            throw ProbeError.speechRecognition("Speech recognition permission is \(status)")
        }
    }
}

private final class SystemSpeechUpdateSinkWriter: SystemSpeechWriting {
    private let sink: TranscriptUpdateSink

    init(sink: TranscriptUpdateSink) {
        self.sink = sink
    }

    func replace(with segments: [TranscriptSegment]) throws {
        for segment in segments {
            sink.receive(.upsert(segment))
        }
    }

    func close() throws {}
}

private final class CaptionDocumentSystemSpeechWriter: SystemSpeechWriting {
    private let sink: CaptionDocumentTranscriptUpdateSink

    init(transcriptURL: URL) {
        self.sink = CaptionDocumentTranscriptUpdateSink(transcriptURL: transcriptURL)
    }

    func replace(with segments: [TranscriptSegment]) throws {
        try sink.persist(.replaceAll(segments))
    }

    func close() throws {}
}

private extension SystemSpeechRecognizing {
    func recognitionTask(
        with request: SystemSpeechRequesting,
        localeIdentifier: String,
        writer: SystemSpeechWriting
    ) -> SystemSpeechTasking? {
        recognitionTask(request: request) { update in
            if let text = update.text {
                try? writer.replace(with: [
                    TranscriptSegment(
                        id: "local-current",
                        text: text,
                        language: localeIdentifier,
                        sourceProvider: "local",
                        isFinal: update.isFinal,
                        timingSource: .unavailable
                    )
                ])
            }
            if update.error != nil {
                try? writer.close()
            }
        }
    }
}
