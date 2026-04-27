import Foundation
import CoreAudio

@available(macOS 14.2, *)
public protocol AudioCaptureSessionManaging: AnyObject {
    var frameBuffer: AudioFrameRingBuffer { get }
    var outputSampleRate: Double { get }
    var outputChannelCount: Int { get }
    func start(target: AudioCaptureTarget) throws
    func stop()
}

@available(macOS 14.2, *)
public final class AudioCaptureSession {
    private let tapManager: AudioTapManaging
    private let aggregateManager: AggregateDeviceManaging
    private let readerFactory: (AudioFrameRingBuffer) -> AudioDeviceReading
    public let frameBuffer: AudioFrameRingBuffer
    private var reader: AudioDeviceReading?

    public private(set) var isRunning = false
    public private(set) var outputSampleRate: Double = 48_000
    public private(set) var outputChannelCount: Int = 1

    public init(
        tapManager: AudioTapManaging = AudioTapManager(),
        aggregateManager: AggregateDeviceManaging = AggregateDeviceManager(),
        readerFactory: @escaping (AudioFrameRingBuffer) -> AudioDeviceReading = { AudioIOReader(frameBuffer: $0) },
        frameBuffer: AudioFrameRingBuffer = AudioFrameRingBuffer(capacity: 512)
    ) {
        self.tapManager = tapManager
        self.aggregateManager = aggregateManager
        self.readerFactory = readerFactory
        self.frameBuffer = frameBuffer
    }

    public func start(target: AudioCaptureTarget) throws {
        guard !isRunning else { return }
        let reader = readerFactory(frameBuffer)
        do {
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
        } catch {
            reader.stop()
            aggregateManager.destroyAggregateDevice()
            tapManager.destroyTap()
            throw error
        }
    }

    public func stop() {
        guard isRunning || reader != nil else { return }
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

@available(macOS 14.2, *)
extension AudioCaptureSession: AudioCaptureSessionManaging {}
