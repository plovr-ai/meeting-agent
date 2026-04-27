import Foundation

enum OpenAIRealtimeTranscriptionProviderError: Error, CustomStringConvertible, Equatable {
    case missingAPIKey
    case invalidEvent
    case transportClosed

    var description: String {
        switch self {
        case .missingAPIKey:
            return "OpenAI API key is not configured"
        case .invalidEvent:
            return "OpenAI Realtime transcription event could not be decoded"
        case .transportClosed:
            return "OpenAI Realtime transcription transport is closed"
        }
    }
}

enum OpenAIRealtimeTranscriptionEvent: Equatable {
    case connected
    case delta(itemID: String, text: String)
    case completed(itemID: String, transcript: String)
    case failed(String)
}

enum OpenAIRealtimeTranscriptionEventDecoder {
    static func decode(_ data: Data) throws -> OpenAIRealtimeTranscriptionEvent? {
        let envelope = try JSONDecoder().decode(EventEnvelope.self, from: data)
        switch envelope.type {
        case "session.created":
            return .connected
        case "conversation.item.input_audio_transcription.delta":
            return .delta(itemID: envelope.itemID ?? "", text: envelope.delta ?? "")
        case "conversation.item.input_audio_transcription.completed":
            return .completed(itemID: envelope.itemID ?? "", transcript: envelope.transcript ?? "")
        case "error":
            return .failed(envelope.error?.message ?? "OpenAI Realtime transcription error")
        default:
            return nil
        }
    }

    private struct EventEnvelope: Decodable {
        let type: String
        let itemID: String?
        let delta: String?
        let transcript: String?
        let error: ErrorEnvelope?

        enum CodingKeys: String, CodingKey {
            case type
            case itemID = "item_id"
            case delta
            case transcript
            case error
        }
    }

    private struct ErrorEnvelope: Decodable {
        let message: String
    }
}
