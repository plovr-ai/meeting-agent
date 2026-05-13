import CoreAudio
import Foundation

@available(macOS 14.2, *)
public protocol DefaultInputDeviceResolving {
    func defaultInputDeviceID() throws -> AudioObjectID
}

@available(macOS 14.2, *)
public struct SystemDefaultInputDeviceResolver: DefaultInputDeviceResolving {
    public init() {}

    public func defaultInputDeviceID() throws -> AudioObjectID {
        var address = CoreAudioHelpers.propertyAddress(kAudioHardwarePropertyDefaultInputDevice)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try CoreAudioHelpers.check(
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID),
            "AudioObjectGetPropertyData(kAudioHardwarePropertyDefaultInputDevice)"
        )
        guard deviceID != AudioObjectID(kAudioObjectUnknown) else {
            throw ProbeError.coreAudio("No default input device is available")
        }
        return deviceID
    }
}

@available(macOS 14.2, *)
public final class MicrophoneCaptureSession {
    private let defaultInputDeviceResolver: DefaultInputDeviceResolving
    private let readerFactory: (AudioFrameRingBuffer) -> AudioDeviceReading
    public let frameBuffer: AudioFrameRingBuffer
    private var reader: AudioDeviceReading?

    public private(set) var isRunning = false
    public private(set) var outputSampleRate: Double = 48_000
    public private(set) var outputChannelCount: Int = 1

    public init(
        defaultInputDeviceResolver: DefaultInputDeviceResolving = SystemDefaultInputDeviceResolver(),
        readerFactory: @escaping (AudioFrameRingBuffer) -> AudioDeviceReading = { AudioIOReader(frameBuffer: $0) },
        frameBuffer: AudioFrameRingBuffer = AudioFrameRingBuffer(capacity: 512)
    ) {
        self.defaultInputDeviceResolver = defaultInputDeviceResolver
        self.readerFactory = readerFactory
        self.frameBuffer = frameBuffer
    }

    public func start(source: AudioCaptureSource) throws {
        guard source.kind == .microphone else {
            throw ProbeError.invalidArguments("MicrophoneCaptureSession only supports microphone capture sources")
        }
        guard !isRunning else { return }
        let reader = readerFactory(frameBuffer)
        do {
            let deviceID = try defaultInputDeviceResolver.defaultInputDeviceID()
            try reader.start(deviceID: deviceID)
            outputSampleRate = reader.outputSampleRate
            outputChannelCount = reader.outputChannelCount
            self.reader = reader
            isRunning = true
        } catch {
            reader.stop()
            throw error
        }
    }

    public func stop() {
        guard isRunning || reader != nil else { return }
        reader?.stop()
        reader = nil
        isRunning = false
    }

    deinit {
        stop()
    }
}

@available(macOS 14.2, *)
extension MicrophoneCaptureSession: AudioCaptureSessionManaging {}
