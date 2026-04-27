import AVFoundation
import Foundation

public struct LocalAudioPlaybackFormat: Equatable {
    public let sampleRate: Double
    public let channelCount: Int
}

public struct LocalAudioPlaybackBuffer: Equatable {
    public let format: LocalAudioPlaybackFormat
    public let samplesByChannel: [[Int16]]

    public var sampleRate: Double { format.sampleRate }
    public var channelCount: Int { format.channelCount }
}

public protocol LocalAudioPlaybackClient: AnyObject {
    func attachIfNeeded(format: LocalAudioPlaybackFormat) throws
    func startEngineIfNeeded() throws
    func playIfNeeded()
    func schedule(_ buffer: LocalAudioPlaybackBuffer) async throws
    func stop()
}

public final class AVFoundationLocalAudioPlaybackClient: LocalAudioPlaybackClient {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var avFormat: AVAudioFormat?

    public init() {}

    public func attachIfNeeded(format: LocalAudioPlaybackFormat) throws {
        guard engine.attachedNodes.contains(player) == false else { return }
        let avFormat = try makeAVFormat(from: format)
        self.avFormat = avFormat
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: avFormat)
    }

    public func startEngineIfNeeded() throws {
        guard engine.isRunning == false else { return }
        try engine.start()
    }

    public func playIfNeeded() {
        guard player.isPlaying == false else { return }
        player.play()
    }

    public func schedule(_ buffer: LocalAudioPlaybackBuffer) async throws {
        let format = try makeAVFormat(from: buffer.format)
        guard let pcmBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(buffer.samplesByChannel.first?.count ?? 0)
        ) else {
            throw ProbeError.invalidArguments("Could not allocate playback buffer")
        }
        pcmBuffer.frameLength = pcmBuffer.frameCapacity
        for channel in 0..<buffer.channelCount {
            guard let destination = pcmBuffer.int16ChannelData?[channel],
                  channel < buffer.samplesByChannel.count
            else { continue }
            for frame in 0..<Int(pcmBuffer.frameLength) {
                destination[frame] = buffer.samplesByChannel[channel][frame]
            }
        }
        await player.scheduleBuffer(pcmBuffer)
    }

    public func stop() {
        player.stop()
        engine.stop()
    }

    private func makeAVFormat(from format: LocalAudioPlaybackFormat) throws -> AVAudioFormat {
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw ProbeError.invalidArguments("Unsupported playback format")
        }
        guard let avFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: format.sampleRate,
            channels: AVAudioChannelCount(format.channelCount),
            interleaved: false
        ) else {
            throw ProbeError.invalidArguments("Unsupported playback format")
        }
        return avFormat
    }
}

public final class LocalAudioPlaybackSink: AudioPlaybackSink {
    private let client: LocalAudioPlaybackClient
    private var currentFormat: LocalAudioPlaybackFormat?

    public init(client: LocalAudioPlaybackClient = AVFoundationLocalAudioPlaybackClient()) {
        self.client = client
    }

    public func play(_ pcmData: Data, sampleRate: Double, channelCount: Int) async throws {
        guard !pcmData.isEmpty else { return }
        let format = playbackFormat(sampleRate: sampleRate, channelCount: channelCount)
        let buffer = try playbackBuffer(pcmData: pcmData, format: format)
        try client.attachIfNeeded(format: format)
        try client.startEngineIfNeeded()
        client.playIfNeeded()
        try await client.schedule(buffer)
    }

    public func stop() async {
        client.stop()
    }

    private func playbackFormat(sampleRate: Double, channelCount: Int) -> LocalAudioPlaybackFormat {
        if let currentFormat,
           currentFormat.sampleRate == sampleRate,
           currentFormat.channelCount == channelCount {
            return currentFormat
        }
        let format = LocalAudioPlaybackFormat(sampleRate: sampleRate, channelCount: channelCount)
        currentFormat = format
        return format
    }

    private func playbackBuffer(pcmData: Data, format: LocalAudioPlaybackFormat) throws -> LocalAudioPlaybackBuffer {
        let channelCount = max(1, format.channelCount)
        let bytesPerFrame = MemoryLayout<Int16>.size * channelCount
        guard pcmData.count >= bytesPerFrame, pcmData.count % bytesPerFrame == 0 else {
            throw ProbeError.invalidArguments("Playback PCM data is not aligned to 16-bit samples")
        }

        let frameCount = pcmData.count / bytesPerFrame
        var samplesByChannel = Array(
            repeating: Array(repeating: Int16(0), count: frameCount),
            count: channelCount
        )
        pcmData.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for frame in 0..<frameCount {
                for channel in 0..<channelCount {
                    let byteOffset = (frame * channelCount + channel) * MemoryLayout<Int16>.size
                    let low = UInt16(bytes[byteOffset])
                    let high = UInt16(bytes[byteOffset + 1]) << 8
                    samplesByChannel[channel][frame] = Int16(bitPattern: high | low)
                }
            }
        }

        return LocalAudioPlaybackBuffer(format: format, samplesByChannel: samplesByChannel)
    }
}
