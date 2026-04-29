import Foundation

public struct PerformanceEvent: Codable, Equatable {
    public let event: String
    public let wallTime: Date
    public let audioTimeSeconds: Double?
    public let segmentID: String?
    public let isFinal: Bool?
    public let textLength: Int?
    public let metadata: [String: String]

    public init(
        event: String,
        wallTime: Date = Date(),
        audioTimeSeconds: Double? = nil,
        segmentID: String? = nil,
        isFinal: Bool? = nil,
        textLength: Int? = nil,
        metadata: [String: String] = [:]
    ) {
        self.event = event
        self.wallTime = wallTime
        self.audioTimeSeconds = audioTimeSeconds
        self.segmentID = segmentID
        self.isFinal = isFinal
        self.textLength = textLength
        self.metadata = metadata
    }
}

public final class PerformanceEventLogger {
    private let url: URL
    private let encoder: JSONEncoder
    private let lock = NSLock()
    private let now: () -> Date

    public init(url: URL, now: @escaping () -> Date = Date.init) {
        self.url = url
        self.now = now
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
    }

    public func log(
        _ event: String,
        audioTimeSeconds: Double? = nil,
        segmentID: String? = nil,
        isFinal: Bool? = nil,
        textLength: Int? = nil,
        metadata: [String: String] = [:]
    ) {
        append(PerformanceEvent(
            event: event,
            wallTime: now(),
            audioTimeSeconds: audioTimeSeconds,
            segmentID: segmentID,
            isFinal: isFinal,
            textLength: textLength,
            metadata: metadata
        ))
    }

    public func append(_ event: PerformanceEvent) {
        lock.lock()
        defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let line = try encoder.encode(event) + Data([0x0A])
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                try handle.close()
            } else {
                try line.write(to: url, options: .atomic)
            }
        } catch {
            // Performance logging must never affect recording or transcription.
        }
    }
}

public extension PerformanceEventLogger {
    func logSegment(_ event: String, segment: TranscriptSegment, metadata: [String: String] = [:]) {
        log(
            event,
            audioTimeSeconds: segment.endTimeSeconds,
            segmentID: segment.id,
            isFinal: segment.isFinal,
            textLength: segment.text.count,
            metadata: metadata
        )
    }
}
