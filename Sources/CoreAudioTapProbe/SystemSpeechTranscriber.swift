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
            commonFormat: .pcmFormatInt16,
            sampleRate: frame.sampleRate,
            channels: AVAudioChannelCount(channelCount),
            interleaved: true
        ) else {
            throw ProbeError.speechRecognition("Unable to create Speech audio format")
        }

        let frameCount = AVAudioFrameCount(frame.pcm.count / bytesPerFrame)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw ProbeError.speechRecognition("Unable to create Speech audio buffer")
        }

        buffer.frameLength = frameCount
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard let destination = buffers[0].mData else {
            throw ProbeError.speechRecognition("Speech audio buffer has no writable storage")
        }

        frame.pcm.copyBytes(to: destination.assumingMemoryBound(to: UInt8.self), count: frame.pcm.count)
        buffers[0].mDataByteSize = UInt32(frame.pcm.count)
        buffers[0].mNumberChannels = AVAudioChannelCount(channelCount)

        return buffer
    }
}

final class SystemSpeechTranscriber {
    private let request: SFSpeechAudioBufferRecognitionRequest
    private let writer: TranscriptFileWriter
    private var task: SFSpeechRecognitionTask?

    private init(request: SFSpeechAudioBufferRecognitionRequest, writer: TranscriptFileWriter) {
        self.request = request
        self.writer = writer
    }

    static func start(transcriptURL: URL) async throws -> SystemSpeechTranscriber {
        try await requestAuthorization()

        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            throw ProbeError.speechRecognition("System speech recognizer is unavailable")
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

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
