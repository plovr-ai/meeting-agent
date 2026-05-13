import Foundation

public typealias SpeakerEvidenceClipProvider = @MainActor (
    _ segments: [TranscriptSegment],
    _ destinationURL: URL,
    _ minimumDurationSeconds: Double
) async throws -> SpeakerAudioEvidenceClip?

@MainActor
public final class RealtimeSpeakerIdentificationRuntime {
    private struct LaneState {
        var segmentIDs = Set<String>()
        var isResolved = false
        var isInFlight = false
    }

    private let embeddingProvider: SpeakerEmbeddingProvider
    private let profileStore: SpeakerProfileStore
    private let resolver: SpeakerIdentityResolver
    private let minimumEvidenceDurationSeconds: Double
    private let performanceEventLogger: PerformanceEventLogger?
    private let temporaryDirectory: URL
    private let clipProvider: SpeakerEvidenceClipProvider
    private let resolutionHandler: @MainActor (SpeakerIdentityResolution) async -> Void
    private var lanes: [String: LaneState] = [:]

    public init(
        embeddingProvider: SpeakerEmbeddingProvider,
        profileStore: SpeakerProfileStore = SpeakerProfileStore(),
        resolver: SpeakerIdentityResolver = SpeakerIdentityResolver(),
        minimumEvidenceDurationSeconds: Double = 3,
        performanceEventLogger: PerformanceEventLogger? = nil,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingAgentSpeakerIdentification", isDirectory: true),
        clipProvider: @escaping SpeakerEvidenceClipProvider,
        resolutionHandler: @escaping @MainActor (SpeakerIdentityResolution) async -> Void
    ) {
        self.embeddingProvider = embeddingProvider
        self.profileStore = profileStore
        self.resolver = resolver
        self.minimumEvidenceDurationSeconds = minimumEvidenceDurationSeconds
        self.performanceEventLogger = performanceEventLogger
        self.temporaryDirectory = temporaryDirectory
        self.clipProvider = clipProvider
        self.resolutionHandler = resolutionHandler
    }

    public func submit(
        document: TranscriptDocument,
        changedSegmentIDs: [String],
        meetingID: UUID?
    ) async {
        let changedIDs = Set(changedSegmentIDs)
        let changedFinalSegments = document.segments.filter { segment in
            changedIDs.contains(segment.id)
                && segment.isFinal
                && segment.speaker.identifier != nil
        }
        let speakerIDs = Set(changedFinalSegments.compactMap(\.speaker.identifier))
        for speakerID in speakerIDs {
            await identifyIfReady(
                speakerID: speakerID,
                document: document,
                meetingID: meetingID
            )
        }
    }

    public func reset() {
        lanes.removeAll()
    }

    private func identifyIfReady(
        speakerID: String,
        document: TranscriptDocument,
        meetingID: UUID?
    ) async {
        var state = lanes[speakerID] ?? LaneState()
        guard !state.isResolved, !state.isInFlight else { return }

        let speakerSegments = document.segments
            .filter { $0.speaker.identifier == speakerID && $0.isFinal }
            .sorted { ($0.startTimeSeconds ?? 0) < ($1.startTimeSeconds ?? 0) }
        let segmentIDs = Set(speakerSegments.map(\.id))
        guard segmentIDs != state.segmentIDs else { return }
        state.segmentIDs = segmentIDs
        let usableDuration = speakerSegments.reduce(0.0) { partial, segment in
            guard let start = segment.startTimeSeconds,
                  let end = segment.endTimeSeconds,
                  end > start
            else {
                return partial
            }
            return partial + (end - start)
        }
        guard usableDuration >= minimumEvidenceDurationSeconds else {
            lanes[speakerID] = state
            return
        }

        state.isInFlight = true
        lanes[speakerID] = state
        let sourceSegmentIDs = speakerSegments.map(\.id)
        performanceEventLogger?.log(
            "speaker_identity_scheduled",
            segmentID: speakerID,
            metadata: [
                "speakerID": speakerID,
                "sourceSegmentIDs": sourceSegmentIDs.joined(separator: ","),
                "evidenceDurationSeconds": Self.metricString(usableDuration)
            ]
        )
        defer {
            var latest = lanes[speakerID] ?? LaneState()
            latest.isInFlight = false
            lanes[speakerID] = latest
        }

        do {
            let destinationURL = temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString)-\(speakerID).wav")
            guard let clip = try await clipProvider(
                speakerSegments,
                destinationURL,
                minimumEvidenceDurationSeconds
            ) else {
                performanceEventLogger?.log(
                    "speaker_identity_clip_unavailable",
                    segmentID: speakerID,
                    metadata: [
                        "speakerID": speakerID,
                        "sourceSegmentIDs": sourceSegmentIDs.joined(separator: ","),
                        "minimumDurationSeconds": Self.metricString(minimumEvidenceDurationSeconds)
                    ]
                )
                return
            }
            performanceEventLogger?.log(
                "speaker_identity_embedding_started",
                segmentID: speakerID,
                metadata: [
                    "speakerID": speakerID,
                    "sourceSegmentIDs": sourceSegmentIDs.joined(separator: ","),
                    "clipDurationSeconds": Self.metricString(clip.durationSeconds)
                ]
            )
            let candidate = try await embeddingProvider.embedding(for: SpeakerEmbeddingRequest(
                wavURL: clip.url,
                sourceMeetingID: meetingID
            ))
            performanceEventLogger?.log(
                "speaker_identity_embedding_finished",
                segmentID: speakerID,
                metadata: [
                    "speakerID": speakerID,
                    "sourceSegmentIDs": sourceSegmentIDs.joined(separator: ","),
                    "durationSeconds": Self.metricString(candidate.durationSeconds),
                    "modelID": candidate.modelID
                ]
            )
            let profiles = try profileStore.loadProfiles()
            let resolution = resolver.resolve(
                localSpeaker: TranscriptSpeaker(identifier: speakerID),
                candidate: candidate,
                profiles: profiles,
                nextAnonymousName: try profileStore.nextAnonymousName()
            )
            try profileStore.upsert(resolution.profile)
            var resolvedState = lanes[speakerID] ?? LaneState()
            resolvedState.isResolved = true
            lanes[speakerID] = resolvedState
            performanceEventLogger?.log(
                "speaker_identity_resolved",
                segmentID: speakerID,
                metadata: [
                    "speakerID": speakerID,
                    "profileID": resolution.profile.id.uuidString,
                    "decision": resolution.decision.rawValue,
                    "displayLabel": resolution.displayLabel,
                    "confidence": Self.metricString(resolution.confidence),
                    "secondBestConfidence": resolution.secondBestConfidence.map(Self.metricString) ?? "",
                    "sourceSegmentIDs": sourceSegmentIDs.joined(separator: ",")
                ]
            )
            await resolutionHandler(resolution)
        } catch {
            performanceEventLogger?.log(
                "speaker_identity_embedding_failed",
                segmentID: speakerID,
                metadata: [
                    "speakerID": speakerID,
                    "sourceSegmentIDs": sourceSegmentIDs.joined(separator: ","),
                    "error": String(describing: error)
                ]
            )
            return
        }
    }

    private static func metricString(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.3f", value)
    }
}
