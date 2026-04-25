import Foundation

@available(macOS 14.2, *)
public final class AudioCaptureSession {
    private let tapManager = AudioTapManager()
    private let aggregateManager = AggregateDeviceManager()
    public let frameBuffer: AudioFrameRingBuffer
    private var reader: AudioIOReader?

    public private(set) var isRunning = false
    public private(set) var outputSampleRate: Double = 48_000
    public private(set) var outputChannelCount: Int = 1

    public init(frameBuffer: AudioFrameRingBuffer = AudioFrameRingBuffer(capacity: 512)) {
        self.frameBuffer = frameBuffer
    }

    public func start(target: AudioCaptureTarget) throws {
        guard !isRunning else { return }
        let reader = AudioIOReader(frameBuffer: frameBuffer)
        _ = try tapManager.createTap(for: target)
        let tapUID = try tapManager.tapUID()
        let aggregateID = try aggregateManager.createAggregateDevice(
            named: "MeetingAgent Probe Aggregate",
            tapUID: tapUID
        )
        try reader.start(deviceID: aggregateID)
        outputSampleRate = reader.outputSampleRate
        outputChannelCount = reader.outputChannelCount
        self.reader = reader
        isRunning = true
    }

    public func stop() {
        reader?.stop()
        reader = nil
        aggregateManager.destroyAggregateDevice()
        tapManager.destroyTap()
        isRunning = false
    }

    deinit {
        stop()
    }
}
