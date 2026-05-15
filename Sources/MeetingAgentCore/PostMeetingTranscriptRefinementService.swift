import Foundation

public struct PostMeetingTranscriptRefinementResult: Equatable {
    public var record: MeetingRecord
    public var captionDocument: CaptionDocument?

    public init(record: MeetingRecord, captionDocument: CaptionDocument?) {
        self.record = record
        self.captionDocument = captionDocument
    }
}

public protocol PostMeetingTranscriptRefining {
    func refineTranscript(
        for record: MeetingRecord,
        liveDocument: CaptionDocument,
        configuration: SpeechTranscriptionConfiguration
    ) async -> PostMeetingTranscriptRefinementResult
}

public final class PostMeetingTranscriptRefinementService: PostMeetingTranscriptRefining {
    private let store: MeetingStore
    private let saveCaptionDocument: (CaptionDocument, MeetingRecord) throws -> Void
    private let providerFactory: (SpeechTranscriptionConfiguration) -> AudioTranscriptionProvider
    private let fileManager: FileManager
    private let now: () -> Date

    public init(
        store: MeetingStore,
        saveCaptionDocument: @escaping (CaptionDocument, MeetingRecord) throws -> Void,
        providerFactory: @escaping (SpeechTranscriptionConfiguration) -> AudioTranscriptionProvider = {
            DeepgramAudioTranscriptionProvider(configuration: .batch($0))
        },
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.saveCaptionDocument = saveCaptionDocument
        self.providerFactory = providerFactory
        self.fileManager = fileManager
        self.now = now
    }

    public func refineTranscript(
        for record: MeetingRecord,
        liveDocument: CaptionDocument,
        configuration: SpeechTranscriptionConfiguration
    ) async -> PostMeetingTranscriptRefinementResult {
        let startedAt = now()
        var updatedRecord = record
        updatedRecord.transcriptRefinement = metadata(
            configuration: configuration,
            status: .running,
            failureReason: nil,
            startedAt: startedAt,
            endedAt: startedAt
        )
        try? store.save(updatedRecord)

        guard configuration.usesDeepgramBatchRefinement else {
            return await fail(
                record: updatedRecord,
                configuration: configuration,
                startedAt: startedAt,
                reason: "Batch transcript provider is not supported"
            )
        }
        guard let audioURL = record.audioURL else {
            return await fail(
                record: updatedRecord,
                configuration: configuration,
                startedAt: startedAt,
                reason: "No saved audio is available for transcript refinement"
            )
        }
        guard fileManager.isReadableFile(atPath: audioURL.path) else {
            return await fail(
                record: updatedRecord,
                configuration: configuration,
                startedAt: startedAt,
                reason: "Saved audio is not readable for transcript refinement"
            )
        }

        do {
            let provider = providerFactory(configuration)
            let transcript = try await provider.transcribe(
                audio: AudioInput(wavURL: audioURL, localeIdentifier: record.speechLocaleIdentifier),
                options: TranscriptionOptions(sourceLocale: record.speechLocaleIdentifier)
            )
            let refinedDocument = Self.captionDocument(
                from: transcript.segments,
                providerID: configuration.batchTranscriptionProviderID,
                modelID: configuration.batchTranscriptionModelID,
                localeIdentifier: record.speechLocaleIdentifier,
                createdAt: liveDocument.createdAt,
                updatedAt: now()
            )
            guard !refinedDocument.turns.isEmpty else {
                return await fail(
                    record: updatedRecord,
                    configuration: configuration,
                    startedAt: startedAt,
                    reason: "Batch transcript refinement returned no usable transcript"
                )
            }
            try saveCaptionDocument(refinedDocument, record)
            let endedAt = now()
            updatedRecord.transcriptRefinement = metadata(
                configuration: configuration,
                status: .refined,
                failureReason: nil,
                startedAt: startedAt,
                endedAt: endedAt
            )
            try? store.save(updatedRecord)
            return PostMeetingTranscriptRefinementResult(record: updatedRecord, captionDocument: refinedDocument)
        } catch {
            return await fail(
                record: updatedRecord,
                configuration: configuration,
                startedAt: startedAt,
                reason: "Transcript refinement failed: \(error)"
            )
        }
    }

    private func fail(
        record: MeetingRecord,
        configuration: SpeechTranscriptionConfiguration,
        startedAt: Date,
        reason: String
    ) async -> PostMeetingTranscriptRefinementResult {
        var failedRecord = record
        let endedAt = now()
        failedRecord.transcriptRefinement = metadata(
            configuration: configuration,
            status: .failed,
            failureReason: reason,
            startedAt: startedAt,
            endedAt: endedAt
        )
        try? store.save(failedRecord)
        return PostMeetingTranscriptRefinementResult(record: failedRecord, captionDocument: nil)
    }

    private func metadata(
        configuration: SpeechTranscriptionConfiguration,
        status: TranscriptRefinementStatus,
        failureReason: String?,
        startedAt: Date,
        endedAt: Date
    ) -> TranscriptRefinementMetadata {
        TranscriptRefinementMetadata(
            providerID: configuration.batchTranscriptionProviderID,
            modelID: configuration.batchTranscriptionModelID,
            status: status,
            failureReason: failureReason,
            durationSeconds: max(0, endedAt.timeIntervalSince(startedAt)),
            updatedAt: endedAt
        )
    }

    public static func captionDocument(
        from segments: [TranscriptSegment],
        providerID: String,
        modelID: String,
        localeIdentifier: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) -> CaptionDocument {
        var speakerLabels: [String: String] = [:]
        var speakers: [CaptionSpeaker] = []
        var turns: [CaptionTurn] = []

        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, segment.isFinal else { continue }
            let speakerID = segment.speakerID
            let speakerLabel = label(
                for: speakerID,
                explicitLabel: segment.speakerLabel,
                labels: &speakerLabels
            )
            if let speakerID, !speakers.contains(where: { $0.id == speakerID }) {
                speakers.append(CaptionSpeaker(id: speakerID, label: speakerLabel, providerSpeakerID: speakerID))
            }
            turns.append(CaptionTurn(
                id: segment.id,
                speakerID: speakerID,
                speakerLabel: speakerLabel,
                startTimeSeconds: segment.startTimeSeconds,
                endTimeSeconds: segment.endTimeSeconds,
                sections: [
                    CaptionSection(
                        id: "\(segment.id)-section",
                        text: text,
                        utteranceIDs: [segment.id],
                        startTimeSeconds: segment.startTimeSeconds,
                        endTimeSeconds: segment.endTimeSeconds
                    )
                ],
                state: .final,
                source: CaptionTurnSource(
                    providerID: providerID,
                    resultIDs: [segment.id],
                    utteranceIDs: [segment.id]
                ),
                language: segment.language ?? localeIdentifier,
                createdAt: segment.createdAt,
                updatedAt: updatedAt
            ))
        }

        return CaptionDocument(
            speakers: speakers,
            turns: turns,
            provider: CaptionProviderInfo(id: providerID, model: modelID, locale: localeIdentifier),
            createdAt: createdAt,
            updatedAt: updatedAt,
            finalizedAt: updatedAt
        )
    }

    private static func label(
        for speakerID: String?,
        explicitLabel: String?,
        labels: inout [String: String]
    ) -> String? {
        guard let speakerID else {
            return SpeechTranscriptionConfiguration.normalized(explicitLabel)
        }
        if let explicitLabel = SpeechTranscriptionConfiguration.normalized(explicitLabel) {
            labels[speakerID] = explicitLabel
            return explicitLabel
        }
        if let existing = labels[speakerID] {
            return existing
        }
        let generated = "Speaker \(labels.count + 1)"
        labels[speakerID] = generated
        return generated
    }
}
