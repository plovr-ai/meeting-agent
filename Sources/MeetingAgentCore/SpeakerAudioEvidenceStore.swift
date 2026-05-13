import Foundation

public struct SpeakerAudioEvidenceClip: Equatable, Sendable {
    public let url: URL
    public let durationSeconds: Double
    public let sampleRate: Double
    public let channelCount: Int

    public init(url: URL, durationSeconds: Double, sampleRate: Double, channelCount: Int) {
        self.url = url
        self.durationSeconds = durationSeconds
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}

public final class SpeakerAudioEvidenceStore {
    private struct TimedFrame {
        var frame: AudioFrame
        var startSeconds: Double
        var endSeconds: Double
    }

    private let retentionDurationSeconds: Double
    private let lock = NSLock()
    private var frames: [TimedFrame] = []
    private var nextStartSeconds = 0.0

    public init(retentionDurationSeconds: Double = 90) {
        self.retentionDurationSeconds = max(1, retentionDurationSeconds)
    }

    public func append(_ newFrames: [AudioFrame]) {
        lock.lock()
        defer { lock.unlock() }

        for frame in newFrames {
            let duration = Self.durationSeconds(for: frame)
            guard duration > 0 else { continue }
            let start = nextStartSeconds
            let end = start + duration
            frames.append(TimedFrame(frame: frame, startSeconds: start, endSeconds: end))
            nextStartSeconds = end
        }
        pruneUnlocked()
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }

        frames = []
        nextStartSeconds = 0
    }

    public func writeClip(
        for segments: [TranscriptSegment],
        to destinationURL: URL,
        minimumDurationSeconds: Double
    ) throws -> SpeakerAudioEvidenceClip? {
        lock.lock()
        let selectedFrames = selectedFramesUnlocked(for: segments)
        lock.unlock()

        let duration = selectedFrames.reduce(0.0) { $0 + Self.durationSeconds(for: $1) }
        guard duration >= minimumDurationSeconds,
              let first = selectedFrames.first
        else {
            return nil
        }

        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let writer = try WavFileWriter(
            url: destinationURL,
            sampleRate: UInt32(first.sampleRate.rounded()),
            channelCount: UInt16(first.channelCount)
        )
        for frame in selectedFrames {
            try writer.append(frame)
        }
        try writer.close()
        return SpeakerAudioEvidenceClip(
            url: destinationURL,
            durationSeconds: duration,
            sampleRate: first.sampleRate,
            channelCount: first.channelCount
        )
    }

    private func selectedFramesUnlocked(for segments: [TranscriptSegment]) -> [AudioFrame] {
        let ranges = segments.compactMap { segment -> ClosedRange<Double>? in
            guard let start = segment.startTimeSeconds,
                  let end = segment.endTimeSeconds,
                  end > start
            else {
                return nil
            }
            return start...end
        }
        guard !ranges.isEmpty else { return [] }
        return frames
            .filter { timedFrame in
                ranges.contains { range in
                    timedFrame.startSeconds < range.upperBound && timedFrame.endSeconds > range.lowerBound
                }
            }
            .map(\.frame)
    }

    private func pruneUnlocked() {
        let cutoff = nextStartSeconds - retentionDurationSeconds
        frames.removeAll { $0.endSeconds <= cutoff }
    }

    private static func durationSeconds(for frame: AudioFrame) -> Double {
        guard frame.sampleRate > 0, frame.channelCount > 0 else { return 0 }
        let bytesPerSample = MemoryLayout<Int16>.size
        let sampleCount = frame.pcm.count / bytesPerSample / frame.channelCount
        return Double(sampleCount) / frame.sampleRate
    }
}
