import Foundation

public enum KnowledgeConnectorKind: String, Codable, Equatable {
    case karpathyWiki
    case gbrain
}

public enum KnowledgeConnectorAvailabilityStatus: String, Codable, Equatable {
    case available
    case unavailable
}

public struct KnowledgeConnectorValidation: Codable, Equatable {
    public let status: KnowledgeConnectorAvailabilityStatus
    public let message: String

    public init(status: KnowledgeConnectorAvailabilityStatus, message: String) {
        self.status = status
        self.message = message
    }

    public static func available(_ message: String) -> KnowledgeConnectorValidation {
        KnowledgeConnectorValidation(status: .available, message: message)
    }

    public static func unavailable(_ message: String) -> KnowledgeConnectorValidation {
        KnowledgeConnectorValidation(status: .unavailable, message: message)
    }
}

public struct KnowledgeConnectorConfiguration: Codable, Equatable {
    public let kind: KnowledgeConnectorKind
    public let isEnabled: Bool
    public let rootURL: URL?
    public let commandPath: String?
    public let autoSyncEnabled: Bool
    public let requireReviewBeforeSync: Bool

    public init(
        kind: KnowledgeConnectorKind,
        isEnabled: Bool,
        rootURL: URL?,
        commandPath: String?,
        autoSyncEnabled: Bool,
        requireReviewBeforeSync: Bool
    ) {
        self.kind = kind
        self.isEnabled = isEnabled
        self.rootURL = rootURL
        self.commandPath = commandPath
        self.autoSyncEnabled = autoSyncEnabled
        self.requireReviewBeforeSync = requireReviewBeforeSync
    }
}

public enum KnowledgeSyncStatus: String, Codable, Equatable {
    case succeeded
    case failed
}

public struct KnowledgeSyncResult: Codable, Equatable {
    public let connectorID: String
    public let status: KnowledgeSyncStatus
    public let destinationDescription: String
    public let filesWritten: [URL]
    public let commandOutput: String?
    public let syncedAt: Date

    public init(
        connectorID: String,
        status: KnowledgeSyncStatus,
        destinationDescription: String,
        filesWritten: [URL],
        commandOutput: String?,
        syncedAt: Date
    ) {
        self.connectorID = connectorID
        self.status = status
        self.destinationDescription = destinationDescription
        self.filesWritten = filesWritten
        self.commandOutput = commandOutput
        self.syncedAt = syncedAt
    }
}

public enum KnowledgeConnectorError: Error, Equatable, LocalizedError {
    case missingRoot
    case invalidConnectorKind(KnowledgeConnectorKind)
    case destinationAlreadyExists(String)

    public var errorDescription: String? {
        switch self {
        case .missingRoot:
            return "Karpathy Wiki root is not configured."
        case .invalidConnectorKind(let kind):
            return "Invalid knowledge connector kind: \(kind.rawValue)"
        case .destinationAlreadyExists(let path):
            return "Knowledge destination already exists: \(path)"
        }
    }
}

public protocol KnowledgeConnector {
    var id: String { get }
    var displayName: String { get }

    func validate(configuration: KnowledgeConnectorConfiguration) async -> KnowledgeConnectorValidation
    func sync(package: MeetingKnowledgePackage, configuration: KnowledgeConnectorConfiguration) async throws -> KnowledgeSyncResult
}
