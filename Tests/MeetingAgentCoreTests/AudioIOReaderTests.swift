import CoreAudio
import XCTest
@testable import MeetingAgentCore

final class AudioIOReaderTests: XCTestCase {
    func testSystemDeviceClientReportsCoreAudioFailuresForInvalidDevice() {
        let client = SystemAudioIODeviceClient()
        let invalidDeviceID = AudioObjectID(kAudioObjectUnknown)
        let ioProcID = unsafeBitCast(1, to: AudioDeviceIOProcID.self)

        XCTAssertThrowsError(try client.readInputStreamFormat(deviceID: invalidDeviceID))
        XCTAssertThrowsError(try client.readNominalSampleRate(deviceID: invalidDeviceID))
        XCTAssertThrowsError(try client.readInputChannelCount(deviceID: invalidDeviceID))
        XCTAssertThrowsError(try client.createIOProcID(deviceID: invalidDeviceID) { _ in })
        XCTAssertThrowsError(try client.startDevice(deviceID: invalidDeviceID, ioProcID: ioProcID))

        client.stopDevice(deviceID: invalidDeviceID, ioProcID: ioProcID)
        client.destroyIOProcID(deviceID: invalidDeviceID, ioProcID: ioProcID)
    }

    func testStartReadsDeviceFormatAndStartsIOProc() throws {
        let buffer = AudioFrameRingBuffer(capacity: 4)
        let client = FakeAudioIODeviceClient()
        client.inputFormat = AudioStreamBasicDescription(
            mSampleRate: 44_100,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let reader = AudioIOReader(frameBuffer: buffer, deviceClient: client)

        try reader.start(deviceID: 123)

        XCTAssertEqual(reader.outputSampleRate, 44_100)
        XCTAssertEqual(reader.outputChannelCount, 2)
        XCTAssertEqual(client.startedDeviceID, 123)
        XCTAssertNotNil(client.handler)
    }

    func testStartFallsBackToNominalRateAndInputChannelCount() throws {
        let client = FakeAudioIODeviceClient()
        client.inputFormat = AudioStreamBasicDescription(
            mSampleRate: 0,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: 0,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 0,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        client.nominalSampleRate = 16_000
        client.inputChannelCount = 2
        let reader = AudioIOReader(frameBuffer: AudioFrameRingBuffer(capacity: 4), deviceClient: client)

        try reader.start(deviceID: 123)

        XCTAssertEqual(reader.outputSampleRate, 16_000)
        XCTAssertEqual(reader.outputChannelCount, 2)
    }

    func testStartRejectsNilIOProcID() {
        let client = FakeAudioIODeviceClient()
        client.createdIOProcID = nil
        let reader = AudioIOReader(frameBuffer: AudioFrameRingBuffer(capacity: 4), deviceClient: client)

        XCTAssertThrowsError(try reader.start(deviceID: 123)) { error in
            XCTAssertTrue(String(describing: error).contains("returned nil IOProcID"))
        }
    }

    func testHandleConvertsFloat32InputAndSkipsEmptyBuffers() throws {
        let buffer = AudioFrameRingBuffer(capacity: 4)
        let client = FakeAudioIODeviceClient()
        client.inputFormat = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let reader = AudioIOReader(frameBuffer: buffer, deviceClient: client)
        try reader.start(deviceID: 123)
        var samples: [Float32] = [-1, 0, 1]
        samples.withUnsafeMutableBytes { sampleBytes in
            let list = AudioBufferList.allocate(maximumBuffers: 2)
            defer { free(list.unsafeMutablePointer) }
            list[0] = AudioBuffer(
                mNumberChannels: 0,
                mDataByteSize: UInt32(sampleBytes.count),
                mData: sampleBytes.baseAddress
            )
            list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil)
            client.handler?(list.unsafeMutablePointer.pointee)
        }

        let frames = buffer.drain()
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.pcm, Data([0, 128, 0, 0, 255, 127]))
        XCTAssertEqual(frames.first?.sampleRate, 48_000)
        XCTAssertEqual(frames.first?.channelCount, 1)
    }

    func testHandlePreservesAlreadyEncodedAndUnknownPCMInput() throws {
        let cases: [(AudioStreamBasicDescription, Data)] = [
            (
                AudioStreamBasicDescription(
                    mSampleRate: 48_000,
                    mFormatID: kAudioFormatLinearPCM,
                    mFormatFlags: 0,
                    mBytesPerPacket: 2,
                    mFramesPerPacket: 1,
                    mBytesPerFrame: 2,
                    mChannelsPerFrame: 1,
                    mBitsPerChannel: 16,
                    mReserved: 0
                ),
                Data([1, 2, 3, 4])
            ),
            (
                AudioStreamBasicDescription(
                    mSampleRate: 48_000,
                    mFormatID: 0,
                    mFormatFlags: 0,
                    mBytesPerPacket: 4,
                    mFramesPerPacket: 1,
                    mBytesPerFrame: 4,
                    mChannelsPerFrame: 1,
                    mBitsPerChannel: 32,
                    mReserved: 0
                ),
                Data([5, 6, 7, 8])
            )
        ]

        for (format, input) in cases {
            let buffer = AudioFrameRingBuffer(capacity: 4)
            let client = FakeAudioIODeviceClient()
            client.inputFormat = format
            let reader = AudioIOReader(frameBuffer: buffer, deviceClient: client)
            try reader.start(deviceID: 123)
            var bytes = input

            bytes.withUnsafeMutableBytes { rawBytes in
                let list = AudioBufferList.allocate(maximumBuffers: 1)
                defer { free(list.unsafeMutablePointer) }
                list[0] = AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(rawBytes.count),
                    mData: rawBytes.baseAddress
                )
                client.handler?(list.unsafeMutablePointer.pointee)
            }

            XCTAssertEqual(buffer.drain().first?.pcm, input)
        }
    }

    func testHandleUsesBufferChannelCountWhenProvided() throws {
        let buffer = AudioFrameRingBuffer(capacity: 4)
        let client = FakeAudioIODeviceClient()
        client.inputFormat.mChannelsPerFrame = 2
        let reader = AudioIOReader(frameBuffer: buffer, deviceClient: client)
        try reader.start(deviceID: 123)
        var bytes = Data([1, 0, 2, 0, 3, 0, 4, 0])

        bytes.withUnsafeMutableBytes { rawBytes in
            let list = AudioBufferList.allocate(maximumBuffers: 1)
            defer { free(list.unsafeMutablePointer) }
            list[0] = AudioBuffer(
                mNumberChannels: 2,
                mDataByteSize: UInt32(rawBytes.count),
                mData: rawBytes.baseAddress
            )
            client.handler?(list.unsafeMutablePointer.pointee)
        }

        XCTAssertEqual(buffer.drain().first?.channelCount, 2)
    }

    func testStopStopsAndDestroysIOProc() throws {
        let client = FakeAudioIODeviceClient()
        let reader = AudioIOReader(frameBuffer: AudioFrameRingBuffer(capacity: 4), deviceClient: client)
        try reader.start(deviceID: 123)

        reader.stop()
        reader.stop()

        XCTAssertEqual(client.stoppedDeviceIDs, [123])
        XCTAssertEqual(client.destroyedDeviceIDs, [123])
    }
}

private final class FakeAudioIODeviceClient: AudioIODeviceClient {
    var inputFormat = AudioStreamBasicDescription(
        mSampleRate: 48_000,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: 0,
        mBytesPerPacket: 2,
        mFramesPerPacket: 1,
        mBytesPerFrame: 2,
        mChannelsPerFrame: 1,
        mBitsPerChannel: 16,
        mReserved: 0
    )
    var nominalSampleRate = 48_000.0
    var inputChannelCount = 1
    var createdIOProcID: AudioDeviceIOProcID? = unsafeBitCast(1, to: AudioDeviceIOProcID.self)
    var handler: ((AudioBufferList) -> Void)?
    var startedDeviceID: AudioObjectID?
    var stoppedDeviceIDs: [AudioObjectID] = []
    var destroyedDeviceIDs: [AudioObjectID] = []

    func readInputStreamFormat(deviceID: AudioObjectID) throws -> AudioStreamBasicDescription {
        inputFormat
    }

    func readNominalSampleRate(deviceID: AudioObjectID) throws -> Double {
        nominalSampleRate
    }

    func readInputChannelCount(deviceID: AudioObjectID) throws -> Int {
        inputChannelCount
    }

    func createIOProcID(deviceID: AudioObjectID, handler: @escaping (AudioBufferList) -> Void) throws -> AudioDeviceIOProcID? {
        self.handler = handler
        return createdIOProcID
    }

    func startDevice(deviceID: AudioObjectID, ioProcID: AudioDeviceIOProcID) throws {
        startedDeviceID = deviceID
    }

    func stopDevice(deviceID: AudioObjectID, ioProcID: AudioDeviceIOProcID) {
        stoppedDeviceIDs.append(deviceID)
    }

    func destroyIOProcID(deviceID: AudioObjectID, ioProcID: AudioDeviceIOProcID) {
        destroyedDeviceIDs.append(deviceID)
    }
}
