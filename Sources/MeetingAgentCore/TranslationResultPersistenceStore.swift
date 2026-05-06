import Foundation

public struct TranslationResultPersistenceStore {
    public let fileURL: URL

    public init(directoryURL: URL) {
        fileURL = directoryURL.appendingPathComponent("translation-results.jsonl")
    }

    public func append(_ record: TranslationResultPersistenceRecord) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var line = try encoder.encode(record)
        line.append(0x0A)

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: fileURL, options: .atomic)
        }
    }

    public func load() throws -> [TranslationResultPersistenceRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try text
            .split(separator: "\n")
            .map { line in
                try decoder.decode(TranslationResultPersistenceRecord.self, from: Data(line.utf8))
            }
    }
}
