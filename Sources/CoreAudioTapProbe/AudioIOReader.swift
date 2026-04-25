import CoreAudio
import Foundation

final class AudioIOReader {
    private let frameBuffer: AudioFrameRingBuffer
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var sampleRate: Double = 48_000
    private var channelCount: Int = 1

    init(frameBuffer: AudioFrameRingBuffer) {
        self.frameBuffer = frameBuffer
    }

    func start(deviceID: AudioObjectID) throws {
        self.deviceID = deviceID
        sampleRate = try readNominalSampleRate(deviceID: deviceID)
        channelCount = max(1, try readInputChannelCount(deviceID: deviceID))

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

    func stop() {
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
            let pcm = Data(bytes: dataPointer, count: Int(buffer.mDataByteSize))
            let frame = AudioFrame(
                pcm: pcm,
                sampleRate: sampleRate,
                channelCount: Int(buffer.mNumberChannels == 0 ? UInt32(channelCount) : buffer.mNumberChannels),
                timestampNanos: UInt64(DispatchTime.now().uptimeNanoseconds)
            )
            frameBuffer.push(frame)
        }
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

    deinit {
        stop()
    }
}
