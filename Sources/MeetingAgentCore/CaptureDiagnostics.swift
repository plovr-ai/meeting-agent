import Foundation

public enum CaptureEndedReason: String, Codable, Equatable {
    case saved
    case captureFailed
    case targetProcessEnded
}

public enum CaptureStatus: String, Codable, Equatable {
    case preparingCapture
    case recording
    case recordingNoAudioDetected
    case recordingSilentAudio
    case targetProcessEnded
    case captureFailed
    case recordingSaved
}

public struct CaptureDiagnostics: Codable, Equatable {
    public let framesCaptured: Int
    public let durationSeconds: Double
    public let lastFrameAt: Date?
    public let sampleRate: Double
    public let channelCount: Int
    public let averageLevel: Double
    public let peakLevel: Double
    public let silentDurationSeconds: Double
    public let bufferBacklog: Int
    public let droppedFrameCount: Int
    public let startupReplayFrameCount: Int
    public let startupReplayDurationSeconds: Double
    public let startupReplayDroppedFrameCount: Int
    public let targetProcessID: pid_t
    public let targetDisplayName: String
    public let endedReason: CaptureEndedReason?
    public let status: CaptureStatus

    public init(
        framesCaptured: Int,
        durationSeconds: Double,
        lastFrameAt: Date?,
        sampleRate: Double,
        channelCount: Int,
        averageLevel: Double,
        peakLevel: Double,
        silentDurationSeconds: Double,
        bufferBacklog: Int,
        droppedFrameCount: Int,
        startupReplayFrameCount: Int = 0,
        startupReplayDurationSeconds: Double = 0,
        startupReplayDroppedFrameCount: Int = 0,
        targetProcessID: pid_t,
        targetDisplayName: String,
        endedReason: CaptureEndedReason?,
        status: CaptureStatus
    ) {
        self.framesCaptured = framesCaptured
        self.durationSeconds = durationSeconds
        self.lastFrameAt = lastFrameAt
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.averageLevel = averageLevel
        self.peakLevel = peakLevel
        self.silentDurationSeconds = silentDurationSeconds
        self.bufferBacklog = bufferBacklog
        self.droppedFrameCount = droppedFrameCount
        self.startupReplayFrameCount = startupReplayFrameCount
        self.startupReplayDurationSeconds = startupReplayDurationSeconds
        self.startupReplayDroppedFrameCount = startupReplayDroppedFrameCount
        self.targetProcessID = targetProcessID
        self.targetDisplayName = targetDisplayName
        self.endedReason = endedReason
        self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case framesCaptured
        case durationSeconds
        case lastFrameAt
        case sampleRate
        case channelCount
        case averageLevel
        case peakLevel
        case silentDurationSeconds
        case bufferBacklog
        case droppedFrameCount
        case startupReplayFrameCount
        case startupReplayDurationSeconds
        case startupReplayDroppedFrameCount
        case targetProcessID
        case targetDisplayName
        case endedReason
        case status
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            framesCaptured: try container.decode(Int.self, forKey: .framesCaptured),
            durationSeconds: try container.decode(Double.self, forKey: .durationSeconds),
            lastFrameAt: try container.decodeIfPresent(Date.self, forKey: .lastFrameAt),
            sampleRate: try container.decode(Double.self, forKey: .sampleRate),
            channelCount: try container.decode(Int.self, forKey: .channelCount),
            averageLevel: try container.decode(Double.self, forKey: .averageLevel),
            peakLevel: try container.decode(Double.self, forKey: .peakLevel),
            silentDurationSeconds: try container.decode(Double.self, forKey: .silentDurationSeconds),
            bufferBacklog: try container.decode(Int.self, forKey: .bufferBacklog),
            droppedFrameCount: try container.decode(Int.self, forKey: .droppedFrameCount),
            startupReplayFrameCount: try container.decodeIfPresent(Int.self, forKey: .startupReplayFrameCount) ?? 0,
            startupReplayDurationSeconds: try container.decodeIfPresent(Double.self, forKey: .startupReplayDurationSeconds) ?? 0,
            startupReplayDroppedFrameCount: try container.decodeIfPresent(Int.self, forKey: .startupReplayDroppedFrameCount) ?? 0,
            targetProcessID: try container.decode(pid_t.self, forKey: .targetProcessID),
            targetDisplayName: try container.decode(String.self, forKey: .targetDisplayName),
            endedReason: try container.decodeIfPresent(CaptureEndedReason.self, forKey: .endedReason),
            status: try container.decode(CaptureStatus.self, forKey: .status)
        )
    }

    public func write(to url: URL) throws {
        let data = try JSONEncoder.meetingAgent.encode(self)
        try data.write(to: url, options: .atomic)
    }
}

public final class CaptureDiagnosticsTracker {
    private static let silenceThreshold = 0.01

    private let target: AudioCaptureTarget
    private var framesCaptured = 0
    private var durationSeconds = 0.0
    private var lastFrameAt: Date?
    private var sampleRate = 0.0
    private var channelCount = 0
    private var absoluteLevelSum = 0.0
    private var sampleCount = 0
    private var peakLevel = 0.0
    private var silentDurationSeconds = 0.0
    private var bufferBacklog = 0
    private var droppedFrameCount = 0
    private var startupReplayFrameCount = 0
    private var startupReplayDurationSeconds = 0.0
    private var startupReplayDroppedFrameCount = 0
    private var endedReason: CaptureEndedReason?
    private var status: CaptureStatus = .preparingCapture

    public init(target: AudioCaptureTarget) {
        self.target = target
    }

    public func markRecording(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        status = .recording
    }

    public func record(
        frames: [AudioFrame],
        bufferBacklog: Int = 0,
        droppedFrameCount: Int = 0
    ) {
        self.bufferBacklog = bufferBacklog
        self.droppedFrameCount = droppedFrameCount

        for frame in frames {
            sampleRate = frame.sampleRate
            channelCount = frame.channelCount
            lastFrameAt = Date(timeIntervalSince1970: TimeInterval(frame.timestampNanos) / 1_000_000_000)

            let levels = Self.levels(for: frame.pcm)
            guard levels.sampleCount > 0, frame.sampleRate > 0 else { continue }

            let sampleFrames = levels.sampleCount / max(1, frame.channelCount)
            framesCaptured += sampleFrames
            sampleCount += levels.sampleCount
            absoluteLevelSum += levels.absoluteLevelSum
            peakLevel = max(peakLevel, levels.peakLevel)

            let frameDuration = Double(sampleFrames) / frame.sampleRate
            durationSeconds += frameDuration
            if levels.peakLevel <= Self.silenceThreshold {
                silentDurationSeconds += frameDuration
            }
        }

        if status == .preparingCapture {
            status = .recording
        }
    }

    public func recordStartupReplay(frames: [AudioFrame]) {
        startupReplayFrameCount += frames.count
        for frame in frames {
            let sampleCount = frame.pcm.count / MemoryLayout<Int16>.size
            guard sampleCount > 0, frame.sampleRate > 0 else { continue }
            let sampleFrames = sampleCount / max(1, frame.channelCount)
            startupReplayDurationSeconds += Double(sampleFrames) / frame.sampleRate
        }
    }

    public func recordDroppedStartupReplayFrames(_ count: Int) {
        startupReplayDroppedFrameCount += max(0, count)
    }

    public func finish(endedReason: CaptureEndedReason) {
        guard self.endedReason == nil else { return }
        self.endedReason = endedReason
        switch endedReason {
        case .captureFailed:
            status = .captureFailed
        case .targetProcessEnded:
            status = .targetProcessEnded
        case .saved:
            if framesCaptured == 0 {
                status = .recordingNoAudioDetected
            } else if peakLevel <= Self.silenceThreshold {
                status = .recordingSilentAudio
            } else {
                status = .recordingSaved
            }
        }
    }

    public func snapshot() -> CaptureDiagnostics {
        CaptureDiagnostics(
            framesCaptured: framesCaptured,
            durationSeconds: durationSeconds,
            lastFrameAt: lastFrameAt,
            sampleRate: sampleRate,
            channelCount: channelCount,
            averageLevel: sampleCount == 0 ? 0 : absoluteLevelSum / Double(sampleCount),
            peakLevel: peakLevel,
            silentDurationSeconds: silentDurationSeconds,
            bufferBacklog: bufferBacklog,
            droppedFrameCount: droppedFrameCount,
            startupReplayFrameCount: startupReplayFrameCount,
            startupReplayDurationSeconds: startupReplayDurationSeconds,
            startupReplayDroppedFrameCount: startupReplayDroppedFrameCount,
            targetProcessID: target.processID,
            targetDisplayName: target.displayName,
            endedReason: endedReason,
            status: status
        )
    }

    public var liveStatus: CaptureStatus {
        if status == .recording, framesCaptured == 0 {
            return .recordingNoAudioDetected
        }
        if status == .recording, framesCaptured > 0, peakLevel <= Self.silenceThreshold {
            return .recordingSilentAudio
        }
        return status
    }

    private static func levels(for pcm: Data) -> (sampleCount: Int, absoluteLevelSum: Double, peakLevel: Double) {
        let sampleCount = pcm.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else {
            return (0, 0, 0)
        }

        var absoluteLevelSum = 0.0
        var peakLevel = 0.0
        for index in 0..<sampleCount {
            let byteOffset = index * MemoryLayout<Int16>.size
            let value = pcm.withUnsafeBytes { rawBuffer in
                rawBuffer.loadUnaligned(fromByteOffset: byteOffset, as: Int16.self)
            }
            let sample = Int16(littleEndian: value)
            let level = min(1.0, Double(abs(Int(sample))) / 32_768.0)
            absoluteLevelSum += level
            peakLevel = max(peakLevel, level)
        }

        return (sampleCount, absoluteLevelSum, peakLevel)
    }
}
