import Foundation
import Security

public enum CredentialKind: String, CaseIterable, Codable, Equatable {
    case openAI
    case deepgram
    case openRouter

    public var service: String { "MeetingAgent" }

    public var account: String {
        switch self {
        case .openAI:
            return "openai-api-key"
        case .deepgram:
            return "deepgram-api-key"
        case .openRouter:
            return "openrouter-api-key"
        }
    }
}

public protocol CredentialStoring {
    func load(_ kind: CredentialKind) throws -> String?
    func save(_ value: String?, for kind: CredentialKind) throws
    func delete(_ kind: CredentialKind) throws
}

public enum CredentialStoreError: Error, Equatable, CustomStringConvertible {
    case unexpectedStatus(OSStatus)
    case invalidData

    public var description: String {
        switch self {
        case .unexpectedStatus(let status):
            return "Keychain returned status \(status)"
        case .invalidData:
            return "Keychain credential data was not valid UTF-8"
        }
    }
}

public final class MemoryCredentialStore: CredentialStoring {
    private var values: [CredentialKind: String] = [:]

    public init() {}

    public func load(_ kind: CredentialKind) throws -> String? {
        values[kind]
    }

    public func save(_ value: String?, for kind: CredentialKind) throws {
        guard let normalized = SpeechTranscriptionConfiguration.normalized(value) else {
            try delete(kind)
            return
        }
        values[kind] = normalized
    }

    public func delete(_ kind: CredentialKind) throws {
        values.removeValue(forKey: kind)
    }
}

public final class KeychainCredentialStore: CredentialStoring {
    public init() {}

    public func load(_ kind: CredentialKind) throws -> String? {
        var query = Self.baseQuery(for: kind)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw CredentialStoreError.unexpectedStatus(status)
        }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            throw CredentialStoreError.invalidData
        }
        return value
    }

    public func save(_ value: String?, for kind: CredentialKind) throws {
        guard let normalized = SpeechTranscriptionConfiguration.normalized(value) else {
            try delete(kind)
            return
        }

        let data = Data(normalized.utf8)
        var query = Self.baseQuery(for: kind)
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            throw CredentialStoreError.unexpectedStatus(updateStatus)
        }

        query[kSecValueData as String] = data
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CredentialStoreError.unexpectedStatus(addStatus)
        }
    }

    public func delete(_ kind: CredentialKind) throws {
        let status = SecItemDelete(Self.baseQuery(for: kind) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.unexpectedStatus(status)
        }
    }

    private static func baseQuery(for kind: CredentialKind) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: kind.service,
            kSecAttrAccount as String: kind.account
        ]
    }
}
