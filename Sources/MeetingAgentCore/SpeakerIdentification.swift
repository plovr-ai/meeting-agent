import Foundation

public struct SpeakerVoiceEmbedding: Codable, Equatable, Sendable {
    public var modelID: String
    public var vector: [Double]
    public var durationSeconds: Double
    public var sourceMeetingID: UUID?
    public var createdAt: Date
    public var quality: [String: String]

    public init(
        modelID: String,
        vector: [Double],
        durationSeconds: Double,
        sourceMeetingID: UUID?,
        createdAt: Date = Date(),
        quality: [String: String] = [:]
    ) {
        self.modelID = modelID
        self.vector = vector
        self.durationSeconds = durationSeconds
        self.sourceMeetingID = sourceMeetingID
        self.createdAt = createdAt
        self.quality = quality
    }
}

public enum SpeakerProfileConfirmationStatus: String, Codable, Equatable, Sendable {
    case anonymous
    case needsConfirmation
    case confirmed
}

public struct SpeakerProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var displayName: String?
    public var anonymousName: String
    public var confirmationStatus: SpeakerProfileConfirmationStatus
    public var embeddings: [SpeakerVoiceEmbedding]
    public var sourceMeetingIDs: [UUID]
    public var createdAt: Date
    public var updatedAt: Date

    public var displayLabel: String {
        let trimmedDisplayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedDisplayName.flatMap { $0.isEmpty ? nil : $0 } ?? anonymousName
    }

    public init(
        id: UUID = UUID(),
        displayName: String?,
        anonymousName: String,
        confirmationStatus: SpeakerProfileConfirmationStatus,
        embeddings: [SpeakerVoiceEmbedding],
        sourceMeetingIDs: [UUID] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.anonymousName = anonymousName
        self.confirmationStatus = confirmationStatus
        self.embeddings = embeddings
        self.sourceMeetingIDs = sourceMeetingIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public mutating func addEmbedding(_ embedding: SpeakerVoiceEmbedding, maxEmbeddings: Int = 8) {
        embeddings.append(embedding)
        embeddings.sort { $0.createdAt < $1.createdAt }
        if embeddings.count > max(1, maxEmbeddings) {
            embeddings.removeFirst(embeddings.count - max(1, maxEmbeddings))
        }
        if let meetingID = embedding.sourceMeetingID, !sourceMeetingIDs.contains(meetingID) {
            sourceMeetingIDs.append(meetingID)
        }
        updatedAt = max(updatedAt, embedding.createdAt)
    }
}

public enum SpeakerIdentityDecision: String, Codable, Equatable, Sendable {
    case matched
    case needsConfirmation
    case createdAnonymous
}

public struct SpeakerIdentityResolution: Codable, Equatable, Sendable {
    public var localSpeaker: TranscriptSpeaker
    public var profile: SpeakerProfile
    public var decision: SpeakerIdentityDecision
    public var confidence: Double
    public var secondBestConfidence: Double?
    public var displayLabel: String
    public var resolvedAt: Date

    public init(
        localSpeaker: TranscriptSpeaker,
        profile: SpeakerProfile,
        decision: SpeakerIdentityDecision,
        confidence: Double,
        secondBestConfidence: Double?,
        displayLabel: String,
        resolvedAt: Date = Date()
    ) {
        self.localSpeaker = localSpeaker
        self.profile = profile
        self.decision = decision
        self.confidence = confidence
        self.secondBestConfidence = secondBestConfidence
        self.displayLabel = displayLabel
        self.resolvedAt = resolvedAt
    }
}

public struct SpeakerIdentityResolver: Sendable {
    public var autoMatchThreshold: Double
    public var reviewThreshold: Double

    public init(autoMatchThreshold: Double = 0.82, reviewThreshold: Double = 0.68) {
        self.autoMatchThreshold = autoMatchThreshold
        self.reviewThreshold = reviewThreshold
    }

    public func resolve(
        localSpeaker: TranscriptSpeaker,
        candidate: SpeakerVoiceEmbedding,
        profiles: [SpeakerProfile],
        nextAnonymousName: String
    ) -> SpeakerIdentityResolution {
        let scoredProfiles = profiles
            .map { profile in
                (
                    profile: profile,
                    score: profile.embeddings
                        .map { Self.cosineSimilarity(candidate.vector, $0.vector) }
                        .max() ?? 0
                )
            }
            .sorted { $0.score > $1.score }

        if let best = scoredProfiles.first, best.score >= reviewThreshold {
            var profile = best.profile
            profile.addEmbedding(candidate)
            if best.score < autoMatchThreshold, profile.confirmationStatus != .confirmed {
                profile.confirmationStatus = .needsConfirmation
            }
            let decision: SpeakerIdentityDecision = best.score >= autoMatchThreshold ? .matched : .needsConfirmation
            return SpeakerIdentityResolution(
                localSpeaker: localSpeaker,
                profile: profile,
                decision: decision,
                confidence: best.score,
                secondBestConfidence: scoredProfiles.dropFirst().first?.score,
                displayLabel: profile.displayLabel
            )
        }

        let profile = SpeakerProfile(
            displayName: nil,
            anonymousName: nextAnonymousName,
            confirmationStatus: .anonymous,
            embeddings: [candidate],
            sourceMeetingIDs: candidate.sourceMeetingID.map { [$0] } ?? []
        )
        return SpeakerIdentityResolution(
            localSpeaker: localSpeaker,
            profile: profile,
            decision: .createdAnonymous,
            confidence: scoredProfiles.first?.score ?? 0,
            secondBestConfidence: scoredProfiles.dropFirst().first?.score,
            displayLabel: profile.displayLabel
        )
    }

    public static func cosineSimilarity(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        var dot = 0.0
        var lhsMagnitude = 0.0
        var rhsMagnitude = 0.0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            lhsMagnitude += lhs[index] * lhs[index]
            rhsMagnitude += rhs[index] * rhs[index]
        }
        guard lhsMagnitude > 0, rhsMagnitude > 0 else { return 0 }
        return dot / (sqrt(lhsMagnitude) * sqrt(rhsMagnitude))
    }
}

public final class SpeakerProfileStore {
    private let url: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    public convenience init(fileManager: FileManager = .default) {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.init(
            url: appSupport
                .appendingPathComponent("MeetingAgent", isDirectory: true)
                .appendingPathComponent("speaker-profiles.json"),
            fileManager: fileManager
        )
    }

    public init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    public func loadProfiles() throws -> [SpeakerProfile] {
        lock.lock()
        defer { lock.unlock() }
        return try loadProfilesUnlocked()
    }

    public func saveProfiles(_ profiles: [SpeakerProfile]) throws {
        lock.lock()
        defer { lock.unlock() }
        try saveProfilesUnlocked(profiles)
    }

    public func upsert(_ profile: SpeakerProfile) throws {
        lock.lock()
        defer { lock.unlock() }
        var profiles = try loadProfilesUnlocked()
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        try saveProfilesUnlocked(profiles)
    }

    public func nextAnonymousName() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        let names = Set(try loadProfilesUnlocked().map(\.anonymousName))
        var index = 1
        while names.contains("Speaker \(index)") {
            index += 1
        }
        return "Speaker \(index)"
    }

    private func loadProfilesUnlocked() throws -> [SpeakerProfile] {
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder.meetingAgent.decode([SpeakerProfile].self, from: data)
    }

    private func saveProfilesUnlocked(_ profiles: [SpeakerProfile]) throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.meetingAgent.encode(profiles)
        try data.write(to: url, options: .atomic)
    }
}
