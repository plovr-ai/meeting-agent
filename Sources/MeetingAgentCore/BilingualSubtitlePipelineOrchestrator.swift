import Foundation

public final class BilingualSubtitlePipelineOrchestrator {
    private let profilesByID: [String: BilingualPipelineProfile]
    private let audioTranscriptionProviders: [String: AudioTranscriptionProvider]
    private let textTranslationProviders: [String: TextTranslationProvider]
    private let directBilingualProviders: [String: DirectBilingualSubtitleProvider]

    public init(
        profiles: [BilingualPipelineProfile],
        audioTranscriptionProviders: [AudioTranscriptionProvider] = [],
        textTranslationProviders: [TextTranslationProvider] = [],
        directBilingualProviders: [DirectBilingualSubtitleProvider] = []
    ) {
        self.profilesByID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        self.audioTranscriptionProviders = Dictionary(uniqueKeysWithValues: audioTranscriptionProviders.map { ($0.descriptor.id, $0) })
        self.textTranslationProviders = Dictionary(uniqueKeysWithValues: textTranslationProviders.map { ($0.descriptor.id, $0) })
        self.directBilingualProviders = Dictionary(uniqueKeysWithValues: directBilingualProviders.map { ($0.descriptor.id, $0) })
    }

    public func generate(
        audio: AudioInput,
        sourceLocale: String,
        targetLocale: String,
        profileID: String
    ) async throws -> BilingualTranscript {
        var provenance = PipelineProvenance(profileID: profileID)
        return try await generate(
            audio: audio,
            sourceLocale: sourceLocale,
            targetLocale: targetLocale,
            profileID: profileID,
            provenance: &provenance,
            visitedProfiles: []
        )
    }

    private func generate(
        audio: AudioInput,
        sourceLocale: String,
        targetLocale: String,
        profileID: String,
        provenance: inout PipelineProvenance,
        visitedProfiles: Set<String>
    ) async throws -> BilingualTranscript {
        guard !visitedProfiles.contains(profileID) else {
            throw BilingualPipelineError.profileCycle(profileID)
        }
        guard let profile = profilesByID[profileID] else {
            throw BilingualPipelineError.profileNotFound(profileID)
        }

        let nextVisitedProfiles = visitedProfiles.union([profileID])
        var transcript: TranscriptDocument?

        for step in profile.steps {
            switch step.capability {
            case .audioTranscription:
                transcript = try await runTranscriptionStep(
                    step,
                    audio: audio,
                    sourceLocale: sourceLocale,
                    provenance: &provenance
                )
            case .textTranslation:
                guard let transcript else {
                    throw BilingualPipelineError.missingTranscriptBeforeTranslation
                }
                let translated = try await runTranslationStep(
                    step,
                    transcript: transcript,
                    sourceLocale: sourceLocale,
                    targetLocale: targetLocale,
                    provenance: &provenance
                )
                return BilingualTranscript(
                    sourceLocale: sourceLocale,
                    targetLocale: targetLocale,
                    segments: translated.segments,
                    provenance: provenance
                )
            case .speechTranslation:
                throw BilingualPipelineError.unsupportedStep(step.capability)
            case .bilingualSubtitle:
                return try await runDirectBilingualStep(
                    step,
                    audio: audio,
                    sourceLocale: sourceLocale,
                    targetLocale: targetLocale,
                    provenance: &provenance,
                    visitedProfiles: nextVisitedProfiles
                )
            }
        }

        throw BilingualPipelineError.noBilingualOutput(profileID)
    }

    private func runTranscriptionStep(
        _ step: PipelineStep,
        audio: AudioInput,
        sourceLocale: String,
        provenance: inout PipelineProvenance
    ) async throws -> TranscriptDocument {
        for reference in [step.primary] + step.fallbacks {
            guard case .provider(let providerID) = reference else { continue }
            guard let provider = audioTranscriptionProviders[providerID] else { continue }
            provenance.attemptedProviders.append(providerID)
            do {
                let result = try await provider.transcribe(
                    audio: audio,
                    options: TranscriptionOptions(sourceLocale: sourceLocale)
                )
                provenance.successfulProviders.append(providerID)
                return result
            } catch {
                provenance.fallbackReasons[providerID] = String(describing: error)
            }
        }
        throw BilingualPipelineError.stepFailed(step.capability)
    }

    private func runTranslationStep(
        _ step: PipelineStep,
        transcript: TranscriptDocument,
        sourceLocale: String,
        targetLocale: String,
        provenance: inout PipelineProvenance
    ) async throws -> TranslatedTranscript {
        for reference in [step.primary] + step.fallbacks {
            guard case .provider(let providerID) = reference else { continue }
            guard let provider = textTranslationProviders[providerID] else { continue }
            provenance.attemptedProviders.append(providerID)
            do {
                let result = try await provider.translate(
                    transcript: transcript,
                    options: TranslationOptions(sourceLocale: sourceLocale, targetLocale: targetLocale)
                )
                provenance.successfulProviders.append(providerID)
                return result
            } catch {
                provenance.fallbackReasons[providerID] = String(describing: error)
            }
        }

        return TranslatedTranscript(
            sourceLocale: sourceLocale,
            targetLocale: targetLocale,
            segments: transcript.segments.map {
                BilingualSubtitleSegment(
                    id: $0.id,
                    startTimeSeconds: $0.startTimeSeconds,
                    endTimeSeconds: $0.endTimeSeconds,
                    speaker: $0.speaker,
                    sourceText: $0.text,
                    targetText: "",
                    confidence: $0.confidence,
                    status: .sourceOnly,
                    errorMessage: "all translation providers failed",
                    providerChain: provenance.successfulProviders
                )
            },
            provenance: provenance
        )
    }

    private func runDirectBilingualStep(
        _ step: PipelineStep,
        audio: AudioInput,
        sourceLocale: String,
        targetLocale: String,
        provenance: inout PipelineProvenance,
        visitedProfiles: Set<String>
    ) async throws -> BilingualTranscript {
        for reference in [step.primary] + step.fallbacks {
            switch reference {
            case .provider(let providerID):
                guard let provider = directBilingualProviders[providerID] else { continue }
                provenance.attemptedProviders.append(providerID)
                do {
                    var output = try await provider.generate(
                        audio: audio,
                        options: BilingualSubtitleOptions(sourceLocale: sourceLocale, targetLocale: targetLocale)
                    )
                    provenance.successfulProviders.append(providerID)
                    output.provenance = provenance
                    return output
                } catch {
                    provenance.fallbackReasons[providerID] = String(describing: error)
                }
            case .profile(let fallbackProfileID):
                return try await generate(
                    audio: audio,
                    sourceLocale: sourceLocale,
                    targetLocale: targetLocale,
                    profileID: fallbackProfileID,
                    provenance: &provenance,
                    visitedProfiles: visitedProfiles
                )
            }
        }
        throw BilingualPipelineError.stepFailed(.bilingualSubtitle)
    }
}

public enum BilingualPipelineError: Error, CustomStringConvertible, Equatable {
    case profileNotFound(String)
    case missingTranscriptBeforeTranslation
    case unsupportedStep(ProviderCapability)
    case stepFailed(ProviderCapability)
    case noBilingualOutput(String)
    case profileCycle(String)

    public var description: String {
        switch self {
        case .profileNotFound(let id):
            return "Bilingual pipeline profile not found: \(id)"
        case .missingTranscriptBeforeTranslation:
            return "Bilingual pipeline missing transcript before translation"
        case .unsupportedStep(let capability):
            return "Unsupported bilingual pipeline step: \(capability.rawValue)"
        case .stepFailed(let capability):
            return "Bilingual pipeline step failed: \(capability.rawValue)"
        case .noBilingualOutput(let id):
            return "Bilingual pipeline did not produce output for profile \(id)"
        case .profileCycle(let id):
            return "Bilingual pipeline profile cycle detected at \(id)"
        }
    }
}
