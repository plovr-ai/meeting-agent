import Foundation

public protocol TranscriptRepository {
    func loadCaptionDocument(for meeting: MeetingRecord) throws -> CaptionDocument
    func saveCaptionDocument(_ document: CaptionDocument, for meeting: MeetingRecord) throws
}

public protocol SummaryRepository {
    func loadSummary(for meeting: MeetingRecord) throws -> MeetingSummary?
    func saveSummary(_ summary: MeetingSummary, for meeting: MeetingRecord) throws
}

public struct FileTranscriptRepository: TranscriptRepository {
    public init() {}

    public func loadCaptionDocument(for meeting: MeetingRecord) throws -> CaptionDocument {
        guard let url = meeting.transcriptJSONURL else {
            return CaptionDocument()
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return CaptionDocument()
        }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else {
            return CaptionDocument()
        }
        return try JSONDecoder.meetingAgent.decode(CaptionDocument.self, from: data)
    }

    public func saveCaptionDocument(_ document: CaptionDocument, for meeting: MeetingRecord) throws {
        guard let url = meeting.transcriptJSONURL else {
            throw ProbeError.invalidArguments("Meeting has no transcript JSON URL")
        }
        let data = try JSONEncoder.meetingAgent.encode(document)
        try data.write(to: url, options: .atomic)
    }
}

public struct FileSummaryRepository: SummaryRepository {
    public init() {}

    public func loadSummary(for meeting: MeetingRecord) throws -> MeetingSummary? {
        guard let url = meeting.summaryJSONURL,
              FileManager.default.fileExists(atPath: url.path)
        else {
            return nil
        }
        return try MeetingSummaryWriter.read(from: url)
    }

    public func saveSummary(_ summary: MeetingSummary, for meeting: MeetingRecord) throws {
        guard let jsonURL = meeting.summaryJSONURL,
              let markdownURL = meeting.summaryMarkdownURL
        else {
            throw ProbeError.invalidArguments("Meeting has no summary output URL")
        }
        try MeetingSummaryWriter.write(summary, jsonURL: jsonURL, markdownURL: markdownURL)
    }
}
