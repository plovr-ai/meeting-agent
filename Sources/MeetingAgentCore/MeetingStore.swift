import Foundation

public struct StoredMeeting: Equatable {
    public var record: MeetingRecord
    public let directory: URL
    public let metadataURL: URL

    public init(record: MeetingRecord, directory: URL, metadataURL: URL) {
        self.record = record
        self.directory = directory
        self.metadataURL = metadataURL
    }
}

public final class MeetingStore {
    private let baseDirectory: URL
    private let fileManager: FileManager

    public init(baseDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else {
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.baseDirectory = appSupport.appendingPathComponent("MeetingAgent", isDirectory: true)
        }
    }

    public var meetingsDirectory: URL {
        baseDirectory.appendingPathComponent("Meetings", isDirectory: true)
    }

    public func createMeeting(id: UUID = UUID(), name: String, startedAt: Date = Date()) throws -> StoredMeeting {
        let directory = meetingsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let record = MeetingRecord(
            id: id,
            name: name,
            startedAt: startedAt,
            endedAt: nil,
            audioURL: directory.appendingPathComponent("audio.wav"),
            transcriptURL: directory.appendingPathComponent("transcript.txt"),
            diagnosticsURL: directory.appendingPathComponent("diagnostics.json")
        )
        try save(record)
        return StoredMeeting(
            record: record,
            directory: directory,
            metadataURL: metadataURL(for: record.id)
        )
    }

    public func save(_ record: MeetingRecord) throws {
        let directory = meetingsDirectory.appendingPathComponent(record.id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.meetingAgent.encode(record)
        try data.write(to: metadataURL(for: record.id), options: .atomic)
    }

    public func loadMeetings() throws -> [MeetingRecord] {
        guard fileManager.fileExists(atPath: meetingsDirectory.path) else { return [] }
        let directories = try fileManager.contentsOfDirectory(
            at: meetingsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        let records = try directories.compactMap { directory -> MeetingRecord? in
            let metadataURL = directory.appendingPathComponent("metadata.json")
            guard fileManager.fileExists(atPath: metadataURL.path) else { return nil }
            let data = try Data(contentsOf: metadataURL)
            return try JSONDecoder.meetingAgent.decode(MeetingRecord.self, from: data)
        }

        return records.sorted { $0.startedAt > $1.startedAt }
    }

    public func metadataURL(for id: UUID) -> URL {
        meetingsDirectory
            .appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent("metadata.json")
    }
}
