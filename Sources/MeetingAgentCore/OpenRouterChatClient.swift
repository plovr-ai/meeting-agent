import Foundation

public struct OpenRouterChatMessage: Codable, Equatable {
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

public struct OpenRouterResponseFormat: Codable, Equatable {
    public let type: String

    public init(type: String) {
        self.type = type
    }
}

public enum OpenRouterChatConfiguration: Equatable {
    case available(apiKey: String, model: String)
    case unavailable(String)

    public var apiKey: String {
        if case .available(let apiKey, _) = self { return apiKey }
        return ""
    }

    public var model: String {
        if case .available(_, let model) = self { return model }
        return ""
    }

    public init(apiKey: String?, model: String?) {
        guard let apiKey = Self.normalized(apiKey) else {
            self = .unavailable("OpenRouter API key is not configured")
            return
        }
        guard let model = Self.normalized(model) else {
            self = .unavailable("OpenRouter model is not configured")
            return
        }
        self = .available(apiKey: apiKey, model: model)
    }

    public static func environment(
        model: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Self {
        OpenRouterChatConfiguration(
            apiKey: environment["MEETING_AGENT_OPENROUTER_API_KEY"],
            model: model
        )
    }

    static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.flatMap { $0.isEmpty ? nil : $0 }
    }
}

public protocol OpenRouterChatClient {
    func complete(
        configuration: OpenRouterChatConfiguration,
        messages: [OpenRouterChatMessage],
        responseFormat: OpenRouterResponseFormat?
    ) async throws -> String
}

public final class URLSessionOpenRouterChatClient: OpenRouterChatClient {
    private let endpointURL: URL
    private let session: URLSession

    public init(
        endpointURL: URL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
        session: URLSession = .shared
    ) {
        self.endpointURL = endpointURL
        self.session = session
    }

    public func complete(
        configuration: OpenRouterChatConfiguration,
        messages: [OpenRouterChatMessage],
        responseFormat: OpenRouterResponseFormat?
    ) async throws -> String {
        guard case .available(let apiKey, let model) = configuration else {
            throw OpenRouterChatError.unavailable("OpenRouter configuration is unavailable")
        }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder.meetingAgent.encode(OpenRouterChatCompletionRequest(
            model: model,
            messages: messages,
            temperature: 0.2,
            responseFormat: responseFormat
        ))

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenRouterChatError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw OpenRouterChatError.httpStatus(httpResponse.statusCode, String(data: data, encoding: .utf8))
        }
        let completion = try JSONDecoder.meetingAgent.decode(OpenRouterChatCompletionResponse.self, from: data)
        guard let content = completion.choices.first?.message.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw OpenRouterChatError.emptyContent
        }
        return content
    }
}

private struct OpenRouterChatCompletionRequest: Encodable {
    let model: String
    let messages: [OpenRouterChatMessage]
    let temperature: Double
    let responseFormat: OpenRouterResponseFormat?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case responseFormat = "response_format"
    }
}

private struct OpenRouterChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String
        }

        let message: Message
    }

    let choices: [Choice]
}

public enum OpenRouterChatError: Error, CustomStringConvertible {
    case unavailable(String)
    case invalidResponse
    case httpStatus(Int, String?)
    case emptyContent
    case invalidJSONContent

    public var description: String {
        switch self {
        case .unavailable(let reason):
            return reason
        case .invalidResponse:
            return "invalid HTTP response"
        case .httpStatus(let statusCode, let body):
            let detail = body?.trimmingCharacters(in: .whitespacesAndNewlines)
            return "HTTP \(statusCode)\(detail.map { ": \($0)" } ?? "")"
        case .emptyContent:
            return "response content was empty"
        case .invalidJSONContent:
            return "response content did not contain a JSON object"
        }
    }
}
