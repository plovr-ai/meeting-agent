import Foundation

final class RecordingTranscriptPersistenceStore {
    private let transcriptURL: URL
    private let structuredURL: URL
    private let eventLogURL: URL
    private let snapshotInterval: TimeInterval
    private let now: () -> Date
    private var accumulator: TranscriptSegmentAccumulator
    private var lastSnapshotAt: Date
    private var plainTextReplacement: String?

    init(
        transcriptURL: URL,
        snapshotInterval: TimeInterval = 2,
        now: @escaping () -> Date = Date.init
    ) throws {
        self.transcriptURL = transcriptURL
        self.structuredURL = transcriptURL.deletingPathExtension().appendingPathExtension("json")
        self.eventLogURL = transcriptURL
            .deletingLastPathComponent()
            .appendingPathComponent("transcript-events.jsonl")
        self.snapshotInterval = snapshotInterval
        self.now = now
        self.lastSnapshotAt = now()
        let initialDocument = try TranscriptFileWriter.readDocument(from: structuredURL)
        FileManager.default.createFile(atPath: transcriptURL.path, contents: Data())
        self.accumulator = TranscriptSegmentAccumulator(document: initialDocument)
        try replayEvents()
    }

    var currentDocument: TranscriptDocument {
        accumulator.currentDocument
    }

    @discardableResult
    func apply(_ update: TranscriptSegmentUpdate, forceSnapshot: Bool = false) throws -> TranscriptSegmentAccumulationResult {
        try validate(update)
        try appendEvent(for: update)
        let result = applyInMemory(update)
        if forceSnapshot || shouldForceSnapshot(for: update) || shouldWriteDebouncedSnapshot() {
            try flushSnapshot()
        }
        return result
    }

    func flushSnapshot() throws {
        if let plainTextReplacement {
            try writeSnapshot(CaptionDocument(), renderedText: plainTextReplacement)
        } else {
            let labeledSegments = TranscriptFileWriter.assignSpeakerLabels(to: accumulator.currentDocument.segments)
            try writeSnapshot(
                Self.captionDocument(from: labeledSegments, updatedAt: now()),
                renderedText: TranscriptFormatter.render(labeledSegments)
            )
        }
        lastSnapshotAt = now()
    }

    func close() throws {
        try flushSnapshot()
    }

    private func replayEvents() throws {
        guard FileManager.default.fileExists(atPath: eventLogURL.path) else { return }
        let data = try Data(contentsOf: eventLogURL)
        guard let contents = String(data: data, encoding: .utf8) else { return }
        for line in contents.split(whereSeparator: \.isNewline) {
            let eventData = Data(line.utf8)
            let event = try JSONDecoder.meetingAgent.decode(RecordingTranscriptEvent.self, from: eventData)
            _ = applyInMemory(try event.makeUpdate())
        }
    }

    private func applyInMemory(_ update: TranscriptSegmentUpdate) -> TranscriptSegmentAccumulationResult {
        let result = accumulator.apply(update)
        if let text = result.plainTextReplacement {
            plainTextReplacement = text
        } else {
            plainTextReplacement = nil
        }
        return result
    }

    private func appendEvent(for update: TranscriptSegmentUpdate) throws {
        try FileManager.default.createDirectory(
            at: eventLogURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try Self.eventEncoder.encode(RecordingTranscriptEvent(update: update))
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

    private func shouldForceSnapshot(for update: TranscriptSegmentUpdate) -> Bool {
        switch update {
        case .replaceAll, .replaceWithPlainText:
            return true
        case .translationPatch(_, _, _, let isFinal):
            return isFinal
        case .upsert:
            return false
        }
    }

    private func shouldWriteDebouncedSnapshot() -> Bool {
        now().timeIntervalSince(lastSnapshotAt) >= snapshotInterval
    }

    private func validate(_ update: TranscriptSegmentUpdate) throws {
        switch update {
        case .translationPatch(let segmentID, let text, let targetLocale, _):
            let normalizedSegmentID = segmentID.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedTargetLocale = targetLocale.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedSegmentID.isEmpty, !normalizedText.isEmpty, !normalizedTargetLocale.isEmpty else {
                throw ProbeError.invalidArguments("Segment ID, translated text, and target locale are required")
            }
            guard accumulator.currentDocument.segments.contains(where: { $0.id == normalizedSegmentID }) else {
                throw ProbeError.invalidArguments("Transcript segment not found")
            }
        case .upsert, .replaceAll, .replaceWithPlainText:
            return
        }
    }

    private func writeSnapshot(_ document: CaptionDocument, renderedText: String) throws {
        let data = try JSONEncoder.meetingAgent.encode(document)
        try data.write(to: structuredURL, options: .atomic)
        try (renderedText + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
    }

    private static func captionDocument(from segments: [TranscriptSegment], updatedAt: Date) -> CaptionDocument {
        let speakers = captionSpeakers(from: segments)
        let turns = segments.map { segment in
            CaptionTurn(
                id: segment.id,
                speakerID: segment.speakerID,
                speakerLabel: segment.speakerLabel,
                startTimeSeconds: segment.startTimeSeconds,
                endTimeSeconds: segment.endTimeSeconds,
                sections: [
                    CaptionSection(
                        id: "\(segment.id)-section",
                        text: segment.text,
                        utteranceIDs: [segment.id],
                        startTimeSeconds: segment.startTimeSeconds,
                        endTimeSeconds: segment.endTimeSeconds
                    )
                ],
                state: segment.isFinal ? .final : .draft,
                source: CaptionTurnSource(
                    providerID: segment.sourceProvider,
                    resultIDs: [segment.id],
                    utteranceIDs: [segment.id]
                ),
                language: segment.language,
                translatedText: segment.translatedText,
                translationTargetLocale: segment.translationTargetLocale,
                translationIsFinal: segment.translationIsFinal,
                createdAt: segment.createdAt,
                updatedAt: updatedAt
            )
        }
        let provider = captionProvider(from: segments)
        return CaptionDocument(
            speakers: speakers,
            turns: turns,
            provider: provider,
            createdAt: segments.map(\.createdAt).min() ?? updatedAt,
            updatedAt: updatedAt,
            finalizedAt: turns.isEmpty || turns.contains(where: { $0.state != .final }) ? nil : updatedAt
        )
    }

    private static func captionSpeakers(from segments: [TranscriptSegment]) -> [CaptionSpeaker] {
        var speakers: [CaptionSpeaker] = []
        var seen = Set<String>()
        for segment in segments {
            guard let speakerID = segment.speakerID, !seen.contains(speakerID) else { continue }
            speakers.append(CaptionSpeaker(id: speakerID, label: segment.speakerLabel))
            seen.insert(speakerID)
        }
        return speakers
    }

    private static func captionProvider(from segments: [TranscriptSegment]) -> CaptionProviderInfo? {
        let providerIDs = Set(segments.map(\.sourceProvider).filter { !$0.isEmpty && $0 != "unknown" })
        guard providerIDs.count == 1, let providerID = providerIDs.first else {
            return nil
        }
        let locales = Set(segments.compactMap(\.language).filter { !$0.isEmpty })
        return CaptionProviderInfo(id: providerID, locale: locales.count == 1 ? locales.first : nil)
    }

    private static var eventEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private struct RecordingTranscriptEvent: Codable {
    let type: EventType
    let segment: TranscriptSegment?
    let segments: [TranscriptSegment]?
    let text: String?
    let segmentID: String?
    let targetLocale: String?
    let isFinal: Bool?

    init(update: TranscriptSegmentUpdate) {
        switch update {
        case .upsert(let segment):
            self.type = .upsert
            self.segment = segment
            self.segments = nil
            self.text = nil
            self.segmentID = nil
            self.targetLocale = nil
            self.isFinal = nil
        case .replaceAll(let segments):
            self.type = .replaceAll
            self.segment = nil
            self.segments = segments
            self.text = nil
            self.segmentID = nil
            self.targetLocale = nil
            self.isFinal = nil
        case .replaceWithPlainText(let text):
            self.type = .replaceWithPlainText
            self.segment = nil
            self.segments = nil
            self.text = text
            self.segmentID = nil
            self.targetLocale = nil
            self.isFinal = nil
        case .translationPatch(let segmentID, let text, let targetLocale, let isFinal):
            self.type = .translationPatch
            self.segment = nil
            self.segments = nil
            self.text = text
            self.segmentID = segmentID
            self.targetLocale = targetLocale
            self.isFinal = isFinal
        }
    }

    func makeUpdate() throws -> TranscriptSegmentUpdate {
        switch type {
        case .upsert:
            guard let segment else {
                throw ProbeError.invalidArguments("Transcript event is missing a segment payload")
            }
            return .upsert(segment)
        case .replaceAll:
            guard let segments else {
                throw ProbeError.invalidArguments("Transcript event is missing a segment list payload")
            }
            return .replaceAll(segments)
        case .replaceWithPlainText:
            guard let text else {
                throw ProbeError.invalidArguments("Transcript event is missing a plain-text payload")
            }
            return .replaceWithPlainText(text)
        case .translationPatch:
            guard let segmentID, let text, let targetLocale, let isFinal else {
                throw ProbeError.invalidArguments("Transcript event is missing a translation patch payload")
            }
            return .translationPatch(
                segmentID: segmentID,
                text: text,
                targetLocale: targetLocale,
                isFinal: isFinal
            )
        }
    }

    enum EventType: String, Codable {
        case upsert
        case replaceAll
        case replaceWithPlainText
        case translationPatch
    }
}
