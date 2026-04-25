import CoreAudio
import Foundation

public final class AudioIOReader {
    private let frameBuffer: AudioFrameRingBuffer
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var sampleRate: Double = 48_000
    private var channelCount: Int = 1
    private var inputFormat = AudioStreamBasicDescription()

    public private(set) var outputSampleRate: Double = 48_000
    public private(set) var outputChannelCount: Int = 1

    public init(frameBuffer: AudioFrameRingBuffer) {
        self.frameBuffer = frameBuffer
    }

    public func start(deviceID: AudioObjectID) throws {
        self.deviceID = deviceID
        inputFormat = try readInputStreamFormat(deviceID: deviceID)
        sampleRate = inputFormat.mSampleRate > 0 ? inputFormat.mSampleRate : try readNominalSampleRate(deviceID: deviceID)
        channelCount = max(1, Int(inputFormat.mChannelsPerFrame == 0 ? UInt32(try readInputChannelCount(deviceID: deviceID)) : inputFormat.mChannelsPerFrame))
        outputSampleRate = sampleRate
        outputChannelCount = channelCount

        var createdIOProcID: AudioDeviceIOProcID?

        try CoreAudioHelpers.check(
            AudioDeviceCreateIOProcIDWithBlock(&createdIOProcID, deviceID, DispatchQueue(label: "CoreAudioTapProbe.IOProc")) { [weak self] _, inputData, _, _, _ in
                self?.handle(inputData: inputData.pointee)
            },
            "AudioDeviceCreateIOProcIDWithBlock"
        )

        guard let createdIOProcID else {
            throw ProbeError.coreAudio("AudioDeviceCreateIOProcIDWithBlock returned nil IOProcID")
        }

        ioProcID = createdIOProcID

        try CoreAudioHelpers.check(
            AudioDeviceStart(deviceID, createdIOProcID),
            "AudioDeviceStart"
        )
    }

    public func stop() {
        guard deviceID != AudioObjectID(kAudioObjectUnknown), let ioProcID else { return }
        AudioDeviceStop(deviceID, ioProcID)
        AudioDeviceDestroyIOProcID(deviceID, ioProcID)
        self.ioProcID = nil
        deviceID = AudioObjectID(kAudioObjectUnknown)
    }

    private func handle(inputData: AudioBufferList) {
        var mutableInputData = inputData
        let buffers = UnsafeMutableAudioBufferListPointer(&mutableInputData)

        for buffer in buffers {
            guard let dataPointer = buffer.mData, buffer.mDataByteSize > 0 else { continue }
            let raw = Data(bytes: dataPointer, count: Int(buffer.mDataByteSize))
            let pcm = convertToInt16PCM(raw)
            let frame = AudioFrame(
                pcm: pcm,
                sampleRate: outputSampleRate,
                channelCount: Int(buffer.mNumberChannels == 0 ? UInt32(outputChannelCount) : buffer.mNumberChannels),
                timestampNanos: UInt64(DispatchTime.now().uptimeNanoseconds)
            )
            frameBuffer.push(frame)
        }
    }

    private func convertToInt16PCM(_ raw: Data) -> Data {
        guard inputFormat.mFormatID == kAudioFormatLinearPCM else {
            return raw
        }

        let isFloat = (inputFormat.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        if isFloat && inputFormat.mBitsPerChannel == 32 {
            return AudioSampleConverter.float32ToInt16PCM(raw)
        }

        if !isFloat && inputFormat.mBitsPerChannel == 16 {
            return raw
        }

        return raw
    }

    private func readNominalSampleRate(deviceID: AudioObjectID) throws -> Double {
        var address = CoreAudioHelpers.propertyAddress(kAudioDevicePropertyNominalSampleRate)
        var rate = Float64(48_000)
        var size = UInt32(MemoryLayout<Float64>.size)

        try CoreAudioHelpers.check(
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate),
            "AudioObjectGetPropertyData(kAudioDevicePropertyNominalSampleRate)"
        )

        return rate
    }

    private func readInputChannelCount(deviceID: AudioObjectID) throws -> Int {
        var address = CoreAudioHelpers.propertyAddress(
            kAudioDevicePropertyStreamConfiguration,
            scope: kAudioDevicePropertyScopeInput
        )
        var size: UInt32 = 0

        try CoreAudioHelpers.check(
            AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size),
            "AudioObjectGetPropertyDataSize(kAudioDevicePropertyStreamConfiguration)"
        )

        let bufferList = AudioBufferList.allocate(maximumBuffers: Int(size) / MemoryLayout<AudioBuffer>.size)
        defer { free(bufferList.unsafeMutablePointer) }

        try CoreAudioHelpers.check(
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferList.unsafeMutablePointer),
            "AudioObjectGetPropertyData(kAudioDevicePropertyStreamConfiguration)"
        )

        return bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func readInputStreamFormat(deviceID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = CoreAudioHelpers.propertyAddress(
            kAudioDevicePropertyStreamFormat,
            scope: kAudioDevicePropertyScopeInput
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

        try CoreAudioHelpers.check(
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &format),
            "AudioObjectGetPropertyData(kAudioDevicePropertyStreamFormat)"
        )

        return format
    }

    deinit {
        stop()
    }
}
