import Foundation

public enum MeetingKnowledgePackageWriterError: Error, Equatable, LocalizedError {
    case destinationIsFile(String)

    public var errorDescription: String? {
        switch self {
        case .destinationIsFile(let path):
            return "Knowledge package destination is a file: \(path)"
        }
    }
}

public struct MeetingKnowledgePackageWriteResult: Equatable {
    public let destinationURL: URL
    public let filesWritten: [URL]

    public init(destinationURL: URL, filesWritten: [URL]) {
        self.destinationURL = destinationURL
        self.filesWritten = filesWritten
    }
}

public struct MeetingKnowledgePackageWriter {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    @discardableResult
    public func write(_ package: MeetingKnowledgePackage, to destinationURL: URL) throws -> MeetingKnowledgePackageWriteResult {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: destinationURL.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            throw MeetingKnowledgePackageWriterError.destinationIsFile(destinationURL.path)
        }

        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        let files: [(String, String)] = [
            ("meeting.md", MeetingKnowledgePackageMarkdownRenderer.renderMeeting(package)),
            ("transcript.md", MeetingKnowledgePackageMarkdownRenderer.renderTranscript(package)),
            ("knowledge.md", MeetingKnowledgePackageMarkdownRenderer.renderKnowledge(package)),
            ("ingest.md", MeetingKnowledgePackageMarkdownRenderer.renderIngest(package))
        ]

        let written = try files.map { filename, content in
            let url = destinationURL.appendingPathComponent(filename)
            try content.write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        return MeetingKnowledgePackageWriteResult(destinationURL: destinationURL, filesWritten: written)
    }
}
