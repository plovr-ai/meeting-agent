import Foundation

public struct OpenRouterChatMessage: Codable, Equatable {
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

public enum OpenRouterSummaryConfiguration: Equatable {
    case available(apiKey: String, model: String)
    case unavailable(String)

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

    public static func environment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        OpenRouterSummaryConfiguration(
            apiKey: environment["MEETING_AGENT_OPENROUTER_API_KEY"],
            model: environment["MEETING_AGENT_OPENROUTER_MODEL"]
        )
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.flatMap { $0.isEmpty ? nil : $0 }
    }
}

public protocol OpenRouterSummaryClient {
    func complete(apiKey: String, model: String, messages: [OpenRouterChatMessage]) async throws -> String
}

public final class URLSessionOpenRouterSummaryClient: OpenRouterSummaryClient {
    private let endpointURL: URL
    private let session: URLSession

    public init(
        endpointURL: URL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
        session: URLSession = .shared
    ) {
        self.endpointURL = endpointURL
        self.session = session
    }

    public func complete(apiKey: String, model: String, messages: [OpenRouterChatMessage]) async throws -> String {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder.meetingAgent.encode(OpenRouterChatCompletionRequest(
            model: model,
            messages: messages,
            temperature: 0.2,
            responseFormat: OpenRouterResponseFormat(type: "json_object")
        ))

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenRouterSummaryError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw OpenRouterSummaryError.httpStatus(httpResponse.statusCode, String(data: data, encoding: .utf8))
        }
        let completion = try JSONDecoder.meetingAgent.decode(OpenRouterChatCompletionResponse.self, from: data)
        guard let content = completion.choices.first?.message.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw OpenRouterSummaryError.emptyContent
        }
        return content
    }
}

public struct OpenRouterMeetingSummaryProvider: MeetingSummaryProvider {
    public var providerName: String {
        switch configuration {
        case .available(_, let model):
            return "openrouter:\(model)"
        case .unavailable:
            return "openrouter"
        }
    }

    private let configuration: OpenRouterSummaryConfiguration
    private let client: OpenRouterSummaryClient

    public init(
        configuration: OpenRouterSummaryConfiguration = .environment(),
        client: OpenRouterSummaryClient = URLSessionOpenRouterSummaryClient()
    ) {
        self.configuration = configuration
        self.client = client
    }

    public func generateSummary(input: MeetingSummaryInput) async throws -> MeetingSummary {
        let sourceSegmentIDs = input.segments
            .map(\.id)
        switch configuration {
        case .unavailable(let reason):
            return failedSummary(input: input, sourceSegmentIDs: sourceSegmentIDs, reason: reason)
        case .available(let apiKey, let model):
            do {
                let content = try await client.complete(
                    apiKey: apiKey,
                    model: model,
                    messages: Self.messages(for: input)
                )
                let payload = try Self.decodePayload(from: content)
                return MeetingSummary(
                    overview: payload.overview,
                    keyTopics: payload.keyTopics,
                    decisions: payload.decisions,
                    actionItems: payload.actionItems,
                    openQuestions: payload.openQuestions,
                    risks: payload.risks,
                    followUps: payload.followUps,
                    language: input.language ?? input.segments.compactMap(\.language).first,
                    sourceSegmentIDs: sourceSegmentIDs,
                    generatedAt: input.generatedAt,
                    provider: providerName,
                    status: .succeeded,
                    failureReason: nil
                )
            } catch {
                return failedSummary(
                    input: input,
                    sourceSegmentIDs: sourceSegmentIDs,
                    reason: "OpenRouter summary generation failed: \(error)"
                )
            }
        }
    }

    private static func messages(for input: MeetingSummaryInput) -> [OpenRouterChatMessage] {
        [
            OpenRouterChatMessage(role: "system", content: """
            You summarize business meetings for managers. Return only valid JSON with these keys: overview, keyTopics, decisions, actionItems, openQuestions, risks, followUps. decisions must contain description, participants, sourceSegmentIDs, confidence. actionItems must contain description, owner, dueDate, sourceSegmentIDs, confidence.
            """),
            OpenRouterChatMessage(role: "user", content: prompt(for: input))
        ]
    }

    private static func prompt(for input: MeetingSummaryInput) -> String {
        var lines = [
            "Meeting name: \(input.meetingName)",
            "Language: \(input.language ?? "unknown")"
        ]
        if let meetingGoal = input.meetingGoal?.trimmingCharacters(in: .whitespacesAndNewlines),
           !meetingGoal.isEmpty {
            lines.append("Meeting goal: \(meetingGoal)")
        }
        lines.append("")
        lines.append("Transcript segments:")
        lines.append(contentsOf: input.segments.map { segment in
            let speaker = segment.speakerLabel ?? segment.speakerID ?? "Unknown speaker"
            return "- id: \(segment.id)\n  speaker: \(speaker)\n  text: \(segment.text)"
        })
        return lines.joined(separator: "\n")
    }

    private static func decodePayload(from content: String) throws -> OpenRouterSummaryPayload {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let json = try extractJSONObject(from: trimmed)
        return try JSONDecoder.meetingAgent.decode(OpenRouterSummaryPayload.self, from: Data(json.utf8))
    }

    private static func extractJSONObject(from content: String) throws -> String {
        guard let start = content.firstIndex(of: "{"),
              let end = content.lastIndex(of: "}"),
              start <= end
        else {
            throw OpenRouterSummaryError.invalidJSONContent
        }
        return String(content[start...end])
    }

    private func failedSummary(input: MeetingSummaryInput, sourceSegmentIDs: [String], reason: String) -> MeetingSummary {
        MeetingSummary(
            overview: "",
            keyTopics: [],
            decisions: [],
            actionItems: [],
            openQuestions: [],
            risks: [],
            followUps: [],
            language: input.language,
            sourceSegmentIDs: sourceSegmentIDs,
            generatedAt: input.generatedAt,
            provider: providerName,
            status: .failed,
            failureReason: reason
        )
    }
}

private struct OpenRouterSummaryPayload: Decodable {
    let overview: String
    let keyTopics: [String]
    let decisions: [MeetingDecision]
    let actionItems: [MeetingActionItem]
    let openQuestions: [String]
    let risks: [String]
    let followUps: [String]
}

private struct OpenRouterChatCompletionRequest: Encodable {
    let model: String
    let messages: [OpenRouterChatMessage]
    let temperature: Double
    let responseFormat: OpenRouterResponseFormat

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case responseFormat = "response_format"
    }
}

private struct OpenRouterResponseFormat: Encodable {
    let type: String
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

private enum OpenRouterSummaryError: Error, CustomStringConvertible {
    case invalidResponse
    case httpStatus(Int, String?)
    case emptyContent
    case invalidJSONContent

    var description: String {
        switch self {
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
