import Foundation

public struct BilingualTranscriptArtifacts: Equatable {
    public var jsonURL: URL
    public var textURL: URL

    public init(jsonURL: URL, textURL: URL) {
        self.jsonURL = jsonURL
        self.textURL = textURL
    }
}

public struct BilingualTranscriptStore {
    private let directoryURL: URL
    private let fileManager: FileManager

    public init(directoryURL: URL, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
    }

    public func save(_ transcript: BilingualTranscript) throws -> BilingualTranscriptArtifacts {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let jsonURL = directoryURL.appendingPathComponent("bilingual-transcript.json")
        let textURL = directoryURL.appendingPathComponent("bilingual-transcript.txt")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(transcript).write(to: jsonURL, options: .atomic)
        try BilingualTranscriptFormatter.render(transcript).write(to: textURL, atomically: true, encoding: .utf8)

        return BilingualTranscriptArtifacts(jsonURL: jsonURL, textURL: textURL)
    }
}
