import Foundation

enum AudioSampleConverter {
    static func float32ToInt16PCM(_ input: Data) -> Data {
        let sampleCount = input.count / MemoryLayout<Float32>.size
        var output = Data()
        output.reserveCapacity(sampleCount * MemoryLayout<Int16>.size)

        input.withUnsafeBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Float32.self)
            for sample in samples {
                let clamped = min(1.0, max(-1.0, sample))
                let scaled = clamped >= 0 ? clamped * Float32(Int16.max) : clamped * 32768.0
                var value = Int16(scaled.rounded()).littleEndian
                Swift.withUnsafeBytes(of: &value) { output.append(contentsOf: $0) }
            }
        }

        return output
    }
}
