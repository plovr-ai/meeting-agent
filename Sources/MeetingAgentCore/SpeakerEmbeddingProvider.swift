import Foundation

public struct SpeakerEmbeddingRequest: Codable, Equatable, Sendable {
    public var wavURL: URL
    public var modelID: String
    public var sourceMeetingID: UUID?

    public init(
        wavURL: URL,
        modelID: String = "speechbrain/spkrec-ecapa-voxceleb",
        sourceMeetingID: UUID? = nil
    ) {
        self.wavURL = wavURL
        self.modelID = modelID
        self.sourceMeetingID = sourceMeetingID
    }
}

public protocol SpeakerEmbeddingProvider: Sendable {
    func embedding(for request: SpeakerEmbeddingRequest) async throws -> SpeakerVoiceEmbedding
}

public enum SpeakerEmbeddingProviderError: Error, CustomStringConvertible, Equatable {
    case sidecarError(String)
    case malformedResponse(String)
    case processFailed(Int32, String)

    public var description: String {
        switch self {
        case .sidecarError(let message):
            return "Sidecar error: \(message)"
        case .malformedResponse(let message):
            return "Malformed sidecar response: \(message)"
        case .processFailed(let status, let message):
            return "Sidecar process failed (\(status)): \(message)"
        }
    }
}

public struct SidecarSpeakerEmbeddingProvider: SpeakerEmbeddingProvider {
    private let pythonExecutableURL: URL
    private let scriptURL: URL

    public init(
        pythonExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/env"),
        scriptURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("scripts/speaker-embedding.py")
    ) {
        self.pythonExecutableURL = pythonExecutableURL
        self.scriptURL = scriptURL
    }

    public func embedding(for request: SpeakerEmbeddingRequest) async throws -> SpeakerVoiceEmbedding {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = pythonExecutableURL
            process.arguments = ["python3", scriptURL.path]

            let input = Pipe()
            let output = Pipe()
            let error = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = error

            try process.run()
            let requestData = try JSONEncoder.meetingAgent.encode(SidecarRequest(request: request))
            try input.fileHandleForWriting.write(contentsOf: requestData)
            try input.fileHandleForWriting.close()
            process.waitUntilExit()

            let outputData = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = error.fileHandleForReading.readDataToEndOfFile()
            if process.terminationStatus != 0 {
                let message = String(data: errorData, encoding: .utf8) ?? ""
                throw SpeakerEmbeddingProviderError.processFailed(process.terminationStatus, message)
            }
            return try Self.parseResponse(outputData, sourceMeetingID: request.sourceMeetingID)
        }.value
    }

    public static func parseResponse(_ data: Data, sourceMeetingID: UUID?) throws -> SpeakerVoiceEmbedding {
        let response: SidecarResponse
        do {
            response = try JSONDecoder.meetingAgent.decode(SidecarResponse.self, from: data)
        } catch {
            throw SpeakerEmbeddingProviderError.malformedResponse(String(describing: error))
        }
        if let error = response.error?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
            throw SpeakerEmbeddingProviderError.sidecarError(error)
        }
        guard let modelID = response.modelID?.trimmingCharacters(in: .whitespacesAndNewlines), !modelID.isEmpty else {
            throw SpeakerEmbeddingProviderError.malformedResponse("missing modelID")
        }
        guard let vector = response.embedding, !vector.isEmpty else {
            throw SpeakerEmbeddingProviderError.malformedResponse("empty embedding")
        }
        guard let durationSeconds = response.durationSeconds, durationSeconds > 0 else {
            throw SpeakerEmbeddingProviderError.malformedResponse("invalid durationSeconds")
        }
        var quality = response.quality ?? [:]
        if let sampleRate = response.sampleRate {
            quality["sampleRate"] = String(sampleRate)
        }
        return SpeakerVoiceEmbedding(
            modelID: modelID,
            vector: vector,
            durationSeconds: durationSeconds,
            sourceMeetingID: sourceMeetingID,
            quality: quality
        )
    }
}

private struct SidecarRequest: Encodable {
    var wavPath: String
    var modelID: String

    init(request: SpeakerEmbeddingRequest) {
        self.wavPath = request.wavURL.path
        self.modelID = request.modelID
    }
}

private struct SidecarResponse: Decodable {
    var modelID: String?
    var embedding: [Double]?
    var durationSeconds: Double?
    var sampleRate: Int?
    var quality: [String: String]?
    var error: String?
}
