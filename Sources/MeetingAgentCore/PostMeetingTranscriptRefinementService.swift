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
    private static let localUserSpeakerID = "local-user"
    private static let localUserSpeakerLabel = "Me"

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
                liveDocument: liveDocument,
                configuration: configuration,
                startedAt: startedAt,
                qualitySource: .fallbackLive,
                reason: "Batch transcript provider is not supported"
            )
        }
        guard let audioURL = record.audioURL else {
            return await fail(
                record: updatedRecord,
                liveDocument: liveDocument,
                configuration: configuration,
                startedAt: startedAt,
                qualitySource: .refinementFailed,
                reason: "No saved audio is available for transcript refinement"
            )
        }
        guard fileManager.isReadableFile(atPath: audioURL.path) else {
            return await fail(
                record: updatedRecord,
                liveDocument: liveDocument,
                configuration: configuration,
                startedAt: startedAt,
                qualitySource: .refinementFailed,
                reason: "Saved audio is not readable for transcript refinement"
            )
        }

        do {
            let provider = providerFactory(configuration)
            let transcript = try await provider.transcribe(
                audio: AudioInput(wavURL: audioURL, localeIdentifier: record.speechLocaleIdentifier),
                options: TranscriptionOptions(sourceLocale: record.speechLocaleIdentifier)
            )
            var segments = transcript.segments
            if let microphoneAudioURL = record.microphoneAudioURL,
               fileManager.isReadableFile(atPath: microphoneAudioURL.path) {
                let microphoneTranscript = try await provider.transcribe(
                    audio: AudioInput(wavURL: microphoneAudioURL, localeIdentifier: record.speechLocaleIdentifier),
                    options: TranscriptionOptions(sourceLocale: record.speechLocaleIdentifier)
                )
                segments.append(contentsOf: microphoneTranscript.segments.map(Self.localUserSegment))
            }
            let refinedDocument = Self.captionDocument(
                from: segments,
                providerID: configuration.batchTranscriptionProviderID,
                modelID: configuration.batchTranscriptionModelID,
                localeIdentifier: record.speechLocaleIdentifier,
                createdAt: liveDocument.createdAt,
                updatedAt: now()
            )
            guard !refinedDocument.turns.isEmpty else {
                return await fail(
                    record: updatedRecord,
                    liveDocument: liveDocument,
                    configuration: configuration,
                    startedAt: startedAt,
                    qualitySource: .refinementFailed,
                    reason: "Batch transcript refinement returned no usable transcript"
                )
            }
            let endedAt = now()
            let qualityDocument = refinedDocument.updatingQuality(
                source: .postProcessed,
                updatedAt: endedAt
            )
            try saveCaptionDocument(qualityDocument, record)
            updatedRecord.transcriptRefinement = metadata(
                configuration: configuration,
                status: .refined,
                failureReason: nil,
                startedAt: startedAt,
                endedAt: endedAt
            )
            try? store.save(updatedRecord)
            return PostMeetingTranscriptRefinementResult(record: updatedRecord, captionDocument: qualityDocument)
        } catch {
            return await fail(
                record: updatedRecord,
                liveDocument: liveDocument,
                configuration: configuration,
                startedAt: startedAt,
                qualitySource: .refinementFailed,
                reason: "Transcript refinement failed: \(error)"
            )
        }
    }

    private func fail(
        record: MeetingRecord,
        liveDocument: CaptionDocument,
        configuration: SpeechTranscriptionConfiguration,
        startedAt: Date,
        qualitySource: TranscriptQualitySource,
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
        let fallbackDocument = liveDocument.updatingQuality(
            source: qualitySource,
            fallbackReason: reason,
            updatedAt: endedAt
        )
        try? saveCaptionDocument(fallbackDocument, failedRecord)
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

    private static func localUserSegment(_ segment: TranscriptSegment) -> TranscriptSegment {
        TranscriptSegment(
            id: segment.id,
            speaker: TranscriptSpeaker(identifier: localUserSpeakerID, label: localUserSpeakerLabel),
            startTimeSeconds: segment.startTimeSeconds,
            endTimeSeconds: segment.endTimeSeconds,
            text: segment.text,
            language: segment.language,
            sourceProvider: segment.sourceProvider,
            isFinal: segment.isFinal,
            speechFinal: segment.speechFinal,
            confidence: segment.confidence,
            createdAt: segment.createdAt,
            timingSource: segment.timingSource,
            translatedText: segment.translatedText,
            translationTargetLocale: segment.translationTargetLocale,
            translationIsFinal: segment.translationIsFinal
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

        turns.sort { lhs, rhs in
            switch (lhs.startTimeSeconds, rhs.startTimeSeconds) {
            case let (lhs?, rhs?) where lhs != rhs:
                return lhs < rhs
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            default:
                return lhs.createdAt < rhs.createdAt
            }
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
