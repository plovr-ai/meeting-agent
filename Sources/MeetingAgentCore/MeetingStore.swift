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
    private let transcriptRepository: any TranscriptRepository

    public init(
        baseDirectory: URL? = nil,
        fileManager: FileManager = .default,
        transcriptRepository: any TranscriptRepository = FileTranscriptRepository()
    ) {
        self.fileManager = fileManager
        self.transcriptRepository = transcriptRepository
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
            transcriptJSONURL: directory.appendingPathComponent("transcript.json"),
            meetingProgressJSONURL: directory.appendingPathComponent("meeting-progress.json"),
            summaryURL: directory.appendingPathComponent("summary.md"),
            summaryJSONURL: directory.appendingPathComponent("summary.json"),
            summaryMarkdownURL: directory.appendingPathComponent("summary.md"),
            diagnosticsURL: directory.appendingPathComponent("diagnostics.json"),
            performanceEventsURL: directory.appendingPathComponent("performance-events.jsonl")
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
            var record = try JSONDecoder.meetingAgent.decode(MeetingRecord.self, from: data)
            if record.summaryURL == nil {
                record.summaryURL = directory.appendingPathComponent("summary.md")
            }
            if record.summaryJSONURL == nil {
                record.summaryJSONURL = directory.appendingPathComponent("summary.json")
            }
            if record.summaryMarkdownURL == nil {
                record.summaryMarkdownURL = record.summaryURL ?? directory.appendingPathComponent("summary.md")
            }
            var didBackfill = false
            if record.meetingProgressJSONURL == nil {
                record.meetingProgressJSONURL = directory.appendingPathComponent("meeting-progress.json")
                didBackfill = true
            }
            if record.performanceEventsURL == nil {
                record.performanceEventsURL = directory.appendingPathComponent("performance-events.jsonl")
                didBackfill = true
            }
            if backfillTranscriptionProviderIDIfNeeded(&record) {
                didBackfill = true
            }
            if didBackfill {
                try save(record)
            }
            return record
        }

        return records.sorted { $0.startedAt > $1.startedAt }
    }

    private func backfillTranscriptionProviderIDIfNeeded(_ record: inout MeetingRecord) -> Bool {
        guard record.transcriptionProviderID == record.speechProvider.rawValue,
              let actualProviderID = actualTranscriptionProviderID(for: record),
              actualProviderID != record.transcriptionProviderID
        else {
            return false
        }
        record.transcriptionProviderID = actualProviderID
        return true
    }

    private func actualTranscriptionProviderID(for record: MeetingRecord) -> String? {
        guard let captionDocument = try? transcriptRepository.loadCaptionDocument(for: record) else {
            return nil
        }
        let providers = Array(Set(
            [captionDocument.provider?.id].compactMap { $0?.nilIfBlankForMeetingStore }
                + captionDocument.turns.map(\.source.providerID).compactMap(\.nilIfBlankForMeetingStore)
        )).sorted()
        return providers.count == 1 ? providers[0] : providers.first
    }

    public func metadataURL(for id: UUID) -> URL {
        meetingsDirectory
            .appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent("metadata.json")
    }
}

private extension String {
    var nilIfBlankForMeetingStore: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
