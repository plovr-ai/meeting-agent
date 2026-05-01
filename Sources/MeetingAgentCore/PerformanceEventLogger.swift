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

    func logDeepgramRawResponse(_ data: Data, context: DeepgramRawResponseContext) {
        guard let response = try? JSONDecoder.meetingAgent.decode(DeepgramStreamingResponse.self, from: data) else {
            log(
                "deepgram_raw_response_received",
                metadata: [
                    "providerID": context.providerID,
                    "transport": context.transport.rawValue,
                    "payloadBytes": String(data.count),
                    "parseStatus": "failed"
                ]
            )
            return
        }
        let alternative = response.channel?.alternatives.first
        let words = alternative?.words ?? []
        var metadata: [String: String] = [
            "providerID": context.providerID,
            "transport": context.transport.rawValue,
            "payloadBytes": String(data.count),
            "parseStatus": "ok"
        ]
        if let type = response.type {
            metadata["responseType"] = type
        }
        if let start = response.start {
            metadata["responseStartSeconds"] = Self.metricString(start)
        }
        if let duration = response.duration {
            metadata["responseDurationSeconds"] = Self.metricString(duration)
        }
        if let speechFinal = response.speechFinal {
            metadata["speechFinal"] = String(speechFinal)
        }
        if let requestID = response.metadata?.requestID {
            metadata["requestID"] = requestID
        }
        if let firstWordStart = words.compactMap(\.start).first {
            metadata["firstWordStartSeconds"] = Self.metricString(firstWordStart)
        }
        if let lastWordEnd = words.compactMap(\.end).last {
            metadata["lastWordEndSeconds"] = Self.metricString(lastWordEnd)
        }
        metadata["wordCount"] = String(words.count)

        let audioTimeSeconds = response.start.flatMap { start in
            response.duration.map { start + $0 }
        } ?? words.compactMap(\.end).last
        log(
            "deepgram_raw_response_received",
            audioTimeSeconds: audioTimeSeconds,
            isFinal: response.isFinal,
            textLength: alternative?.transcript.count,
            metadata: metadata
        )
    }
}

extension PerformanceEventLogger {
    static func durationMetadata(from start: Date, to end: Date = Date()) -> [String: String] {
        let milliseconds = max(0, Int((end.timeIntervalSince(start) * 1_000).rounded()))
        return ["durationMilliseconds": String(milliseconds)]
    }

    static func metricString(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(value)
    }
}
