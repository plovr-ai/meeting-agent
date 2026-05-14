import Foundation

public final class MeetingTranscriptStore {
    public let directoryURL: URL
    public let transcriptJSONURL: URL
    public let eventLogURL: URL

    private var reducer: CaptionReducer
    private let snapshotInterval: TimeInterval
    private let now: () -> Date
    private var lastSnapshotAt: Date
    private let lock = NSLock()

    public var currentDocument: CaptionDocument {
        lock.lock()
        defer { lock.unlock() }
        return reducer.document
    }

    public init(
        directoryURL: URL,
        provider: CaptionProviderInfo? = nil,
        snapshotInterval: TimeInterval = 2,
        now: @escaping () -> Date = Date.init
    ) throws {
        self.directoryURL = directoryURL
        self.transcriptJSONURL = directoryURL.appendingPathComponent("transcript.json")
        self.eventLogURL = directoryURL.appendingPathComponent("transcript-events.jsonl")
        self.snapshotInterval = snapshotInterval
        self.now = now
        self.lastSnapshotAt = now()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: transcriptJSONURL.path),
           let document = try? Self.readDocument(from: transcriptJSONURL) {
            self.reducer = CaptionReducer(document: document, provider: provider ?? document.provider)
        } else {
            var replayReducer = CaptionReducer(provider: provider)
            if FileManager.default.fileExists(atPath: eventLogURL.path) {
                let events = try Self.readEvents(from: eventLogURL)
                for event in events {
                    replayReducer.apply(event)
                }
            }
            self.reducer = replayReducer
            try writeSnapshot(replayReducer.document)
        }
    }

    @discardableResult
    public func apply(_ event: SpeechRecognitionEvent, forceSnapshot: Bool = false) throws -> CaptionDocument {
        lock.lock()
        defer { lock.unlock() }

        try appendEvent(event)
        let document = reducer.apply(event)
        if forceSnapshot || shouldWriteDebouncedSnapshot() || event.isFinal {
            try writeSnapshot(document)
            lastSnapshotAt = now()
        }
        return document
    }

    public func flushSnapshot() throws {
        lock.lock()
        defer { lock.unlock() }
        try writeSnapshot(reducer.document)
        lastSnapshotAt = now()
    }

    public static func readDocument(from url: URL) throws -> CaptionDocument {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return CaptionDocument()
        }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else {
            return CaptionDocument()
        }
        return try JSONDecoder.meetingAgent.decode(CaptionDocument.self, from: data)
    }

    private func shouldWriteDebouncedSnapshot() -> Bool {
        now().timeIntervalSince(lastSnapshotAt) >= snapshotInterval
    }

    private func writeSnapshot(_ document: CaptionDocument) throws {
        let data = try JSONEncoder.meetingAgent.encode(document)
        try data.write(to: transcriptJSONURL, options: .atomic)
    }

    private func appendEvent(_ event: SpeechRecognitionEvent) throws {
        let data = try Self.eventEncoder.encode(event)
        if FileManager.default.fileExists(atPath: eventLogURL.path) {
            let handle = try FileHandle(forWritingTo: eventLogURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: Data([0x0A]))
        } else {
            var line = data
            line.append(0x0A)
            try line.write(to: eventLogURL, options: .atomic)
        }
    }

    private static func readEvents(from url: URL) throws -> [SpeechRecognitionEvent] {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return try text.split(whereSeparator: \.isNewline).map { line in
            try JSONDecoder.meetingAgent.decode(SpeechRecognitionEvent.self, from: Data(line.utf8))
        }
    }

    private static var eventEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
