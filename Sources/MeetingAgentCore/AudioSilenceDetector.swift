import Foundation

public struct AudioSilenceDetector: Equatable {
    public let amplitudeThreshold: Int16

    public init(amplitudeThreshold: Int16 = 32) {
        self.amplitudeThreshold = max(0, amplitudeThreshold)
    }

    public func isSilent(_ frame: AudioFrame) -> Bool {
        guard !frame.pcm.isEmpty,
              frame.pcm.count.isMultiple(of: MemoryLayout<Int16>.size)
        else {
            return false
        }

        let threshold = Int(amplitudeThreshold)
        var index = 0
        while index < frame.pcm.count {
            let low = UInt16(frame.pcm[index])
            let high = UInt16(frame.pcm[index + 1]) << 8
            let sample = Int(Int16(bitPattern: high | low))
            if abs(sample) > threshold {
                return false
            }
            index += MemoryLayout<Int16>.size
        }
        return true
    }
}
