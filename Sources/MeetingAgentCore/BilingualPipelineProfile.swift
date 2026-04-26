import Foundation

public enum PipelineReference: Codable, Equatable {
    case provider(String)
    case profile(String)

    public var id: String {
        switch self {
        case .provider(let id), .profile(let id):
            return id
        }
    }
}

public struct PipelineStep: Codable, Equatable {
    public var capability: ProviderCapability
    public var primary: PipelineReference
    public var fallbacks: [PipelineReference]

    public init(
        capability: ProviderCapability,
        primary: PipelineReference,
        fallbacks: [PipelineReference] = []
    ) {
        self.capability = capability
        self.primary = primary
        self.fallbacks = fallbacks
    }
}

public struct BilingualPipelineProfile: Codable, Equatable {
    public var id: String
    public var displayName: String
    public var steps: [PipelineStep]

    public init(id: String, displayName: String, steps: [PipelineStep]) {
        self.id = id
        self.displayName = displayName
        self.steps = steps
    }

    public func validate(registry: ProviderRegistry, profilesByID: [String: BilingualPipelineProfile]) throws {
        for step in steps {
            try validate(reference: step.primary, step: step, registry: registry, profilesByID: profilesByID)
            for fallback in step.fallbacks {
                try validate(reference: fallback, step: step, registry: registry, profilesByID: profilesByID)
            }
        }
    }

    private func validate(
        reference: PipelineReference,
        step: PipelineStep,
        registry: ProviderRegistry,
        profilesByID: [String: BilingualPipelineProfile]
    ) throws {
        let provider = registry.descriptor(id: reference.id)
        let profile = profilesByID[reference.id]
        if provider != nil && profile != nil {
            throw BilingualPipelineProfileError.invalidProfile(
                id: id,
                reason: "fallback id \(reference.id) is both a provider and a profile"
            )
        }

        switch reference {
        case .provider(let providerID):
            guard let provider else {
                throw BilingualPipelineProfileError.invalidProfile(
                    id: id,
                    reason: "provider \(providerID) is not registered"
                )
            }
            guard provider.capability == step.capability else {
                throw BilingualPipelineProfileError.invalidProfile(
                    id: id,
                    reason: "provider \(providerID) does not support \(step.capability.rawValue)"
                )
            }
        case .profile(let profileID):
            guard profile != nil else {
                throw BilingualPipelineProfileError.invalidProfile(
                    id: id,
                    reason: "profile \(profileID) is not registered"
                )
            }
        }
    }
}

public enum BilingualPipelineProfileError: Error, CustomStringConvertible, Equatable {
    case invalidProfile(id: String, reason: String)

    public var description: String {
        switch self {
        case .invalidProfile(let id, let reason):
            return "Invalid pipeline profile \(id): \(reason)"
        }
    }
}
