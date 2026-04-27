import AVFoundation
import Foundation

public final class LocalAudioPlaybackSink: AudioPlaybackSink {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var currentFormat: AVAudioFormat?

    public init() {}

    public func play(_ pcmData: Data, sampleRate: Double, channelCount: Int) async throws {
        guard !pcmData.isEmpty else { return }
        let format = try playbackFormat(sampleRate: sampleRate, channelCount: channelCount)
        if engine.attachedNodes.contains(player) == false {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
        }
        if engine.isRunning == false {
            try engine.start()
        }
        if player.isPlaying == false {
            player.play()
        }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(pcmData.count / MemoryLayout<Int16>.size / max(1, channelCount))
        ) else {
            throw ProbeError.invalidArguments("Could not allocate playback buffer")
        }
        buffer.frameLength = buffer.frameCapacity
        pcmData.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            let source = baseAddress.assumingMemoryBound(to: Int16.self)
            let frameCount = Int(buffer.frameLength)
            for channel in 0..<channelCount {
                guard let destination = buffer.int16ChannelData?[channel] else { continue }
                for frame in 0..<frameCount {
                    destination[frame] = source[frame * channelCount + channel]
                }
            }
        }
        await player.scheduleBuffer(buffer)
    }

    public func stop() async {
        player.stop()
        engine.stop()
    }

    private func playbackFormat(sampleRate: Double, channelCount: Int) throws -> AVAudioFormat {
        if let currentFormat,
           currentFormat.sampleRate == sampleRate,
           Int(currentFormat.channelCount) == channelCount {
            return currentFormat
        }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channelCount),
            interleaved: false
        ) else {
            throw ProbeError.invalidArguments("Unsupported playback format")
        }
        currentFormat = format
        return format
    }
}
