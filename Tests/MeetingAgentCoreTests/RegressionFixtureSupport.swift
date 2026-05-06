import Foundation
@testable import MeetingAgentCore

enum RegressionFixturePurpose: String, Codable, Equatable {
    case knownFailure
    case golden
}

enum RegressionAnalyzerStatus: String, Codable, Equatable {
    case pass
    case fail
}

struct RegressionFixtureManifest: Codable, Equatable {
    var id: String
    var sourceMeetingID: String
    var scenario: String
    var sourceLocale: String
    var targetLocale: String
    var purpose: RegressionFixturePurpose
    var expectedAnalyzerStatus: RegressionAnalyzerStatus
    var expectedFailures: [String]
    var notes: [String]?
}

struct RegressionExpectedUI: Codable, Equatable {
    var displayModes: [String: [RegressionExpectedUIRow]]
}

struct RegressionExpectedUIRow: Codable, Equatable {
    var sourceSegmentIDs: [String]
    var primaryText: String
    var sourceText: String?
    var isFinal: Bool?
    var translationState: String?
}

enum RegressionFixtureError: Error, Equatable, CustomStringConvertible {
    case missingTranslation(String)

    var description: String {
        switch self {
        case .missingTranslation(let key):
            return "Missing fixture translation for \(key)"
        }
    }
}

struct RegressionFixtureTranslationLookup {
    private var translationsBySegmentSet: [String: String]
    private var translationsBySourceTextHash: [String: String]

    init(records: [TranslationResultPersistenceRecord]) {
        translationsBySegmentSet = Dictionary(uniqueKeysWithValues: records.map {
            (Self.canonical($0.sourceSegmentIDs), $0.translatedText)
        })
        translationsBySourceTextHash = Dictionary(uniqueKeysWithValues: records.map {
            ($0.sourceTextHash, $0.translatedText)
        })
    }

    func translation(forSourceSegmentIDs ids: [String]) throws -> String {
        let key = Self.canonical(ids)
        guard let text = translationsBySegmentSet[key] else {
            throw RegressionFixtureError.missingTranslation(key)
        }
        return text
    }

    func translation(forSourceTextHash hash: String) throws -> String {
        guard let text = translationsBySourceTextHash[hash] else {
            throw RegressionFixtureError.missingTranslation(hash)
        }
        return text
    }

    static func canonical(_ ids: [String]) -> String {
        ids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
            .joined(separator: ",")
    }
}
