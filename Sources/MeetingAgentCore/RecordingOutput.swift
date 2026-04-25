import Foundation

public struct RecordingOutput {
    public let directory: URL
    public let wavURL: URL
    public let transcriptURL: URL

    public static func defaultOutput(
        forRequestedWavPath wavPath: String,
        timestamp: Date = Date(),
        timeZone: TimeZone = .current,
        fileManager: FileManager = .default
    ) throws -> RecordingOutput {
        let directory = URL(fileURLWithPath: fileManager.currentDirectoryPath).appendingPathComponent(".record", isDirectory: true)
        let wavName: String
        if wavPath.isEmpty {
            wavName = timestampedWavName(timestamp: timestamp, timeZone: timeZone)
        } else {
            let requestedURL = URL(fileURLWithPath: wavPath)
            wavName = requestedURL.lastPathComponent.isEmpty ? timestampedWavName(timestamp: timestamp, timeZone: timeZone) : requestedURL.lastPathComponent
        }
        let wavURL = directory.appendingPathComponent(wavName)
        let transcriptURL = wavURL.deletingPathExtension().appendingPathExtension("txt")

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        return RecordingOutput(directory: directory, wavURL: wavURL, transcriptURL: transcriptURL)
    }

    private static func timestampedWavName(timestamp: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(formatter.string(from: timestamp)).wav"
    }
}

public final class TranscriptFileWriter {
    private let url: URL
    private var isClosed = false

    public init(url: URL) throws {
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: Data())
    }

    public func replace(with text: String) throws {
        guard !isClosed else { return }
        try (text + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    public func close() throws {
        isClosed = true
    }
}
