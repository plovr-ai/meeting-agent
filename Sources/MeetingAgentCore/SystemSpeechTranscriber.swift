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

final class SystemSpeechTranscriber: AudioFrameTranscriber {
    private let request: SFSpeechAudioBufferRecognitionRequest
    private let writer: TranscriptFileWriter
    private var task: SFSpeechRecognitionTask?

    private init(request: SFSpeechAudioBufferRecognitionRequest, writer: TranscriptFileWriter) {
        self.request = request
        self.writer = writer
    }

    static func start(transcriptURL: URL, localeIdentifier: String) async throws -> SystemSpeechTranscriber {
        try await requestAuthorization()

        let locale = Locale(identifier: localeIdentifier)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw ProbeError.speechRecognition("System speech recognizer is unavailable for locale \(localeIdentifier)")
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation

        let writer = try TranscriptFileWriter(url: transcriptURL)
        let transcriber = SystemSpeechTranscriber(request: request, writer: writer)
        transcriber.task = recognizer.recognitionTask(with: request) { result, error in
            if let result {
                try? writer.replace(with: result.bestTranscription.formattedString)
            }
            if error != nil {
                try? writer.close()
            }
        }

        return transcriber
    }

    func append(_ frame: AudioFrame) throws {
        try request.append(SpeechAudioBufferFactory.buffer(from: frame))
    }

    func finish() {
        request.endAudio()
        task?.finish()
    }

    deinit {
        task?.cancel()
        try? writer.close()
    }

    private static func requestAuthorization() async throws {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }

        guard status == .authorized else {
            throw ProbeError.speechRecognition("Speech recognition permission is \(status)")
        }
    }
}
