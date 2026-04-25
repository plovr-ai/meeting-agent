import Foundation

public final class WavFileWriter {
    private let handle: FileHandle
    private let sampleRate: UInt32
    private let channelCount: UInt16
    private let bitsPerSample: UInt16 = 16
    private var dataByteCount: UInt32 = 0
    private var isClosed = false

    public init(url: URL, sampleRate: UInt32, channelCount: UInt16) throws {
        self.sampleRate = sampleRate
        self.channelCount = channelCount

        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        try writePlaceholderHeader()
    }

    public func append(_ frame: AudioFrame) throws {
        guard !isClosed else { return }
        try handle.seekToEnd()
        try handle.write(contentsOf: frame.pcm)
        dataByteCount += UInt32(frame.pcm.count)
    }

    public func close() throws {
        guard !isClosed else { return }
        try handle.seek(toOffset: 0)
        try writeHeader(dataSize: dataByteCount)
        try handle.close()
        isClosed = true
    }

    private func writePlaceholderHeader() throws {
        try writeHeader(dataSize: 0)
    }

    private func writeHeader(dataSize: UInt32) throws {
        let byteRate = sampleRate * UInt32(channelCount) * UInt32(bitsPerSample / 8)
        let blockAlign = channelCount * (bitsPerSample / 8)

        var data = Data()
        data.appendASCII("RIFF")
        data.appendLittleEndian(UInt32(36) + dataSize)
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(channelCount)
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)
        data.appendASCII("data")
        data.appendLittleEndian(dataSize)
        try handle.write(contentsOf: data)
    }

    deinit {
        try? close()
    }
}

private extension Data {
    mutating func appendASCII(_ value: String) {
        append(value.data(using: .ascii)!)
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
