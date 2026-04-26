import Foundation

enum OpenAIRealtimeProviderError: Error, CustomStringConvertible, Equatable {
    case missingAPIKey
    case invalidEvent
    case invalidBase64Audio
    case transportClosed

    var description: String {
        switch self {
        case .missingAPIKey:
            return "MEETING_AGENT_OPENAI_API_KEY is not configured"
        case .invalidEvent:
            return "OpenAI Realtime event could not be decoded"
        case .invalidBase64Audio:
            return "OpenAI Realtime audio delta was not valid base64"
        case .transportClosed:
            return "OpenAI Realtime WebSocket transport is closed"
        }
    }
}

enum OpenAIRealtimeEventDecoder {
    static func decode(_ data: Data) throws -> RealtimeTranslationEvent? {
        let envelope = try JSONDecoder().decode(EventEnvelope.self, from: data)
        switch envelope.type {
        case "session.created", "session.updated":
            return .connected
        case "response.output_audio.delta":
            guard let delta = envelope.delta,
                  let audioData = Data(base64Encoded: delta)
            else { throw OpenAIRealtimeProviderError.invalidBase64Audio }
            return .targetAudioDelta(audioData)
        case "response.output_audio_transcript.delta":
            return .targetTextDelta(envelope.delta ?? "")
        case "response.output_audio_transcript.done":
            return .targetTextFinal(envelope.transcript ?? "")
        case "rate_limits.updated":
            return .rateLimitsUpdated
        case "error":
            return .failed(envelope.error?.message ?? "OpenAI Realtime error")
        case "response.done", "response.output_audio.done":
            return nil
        default:
            return nil
        }
    }

    private struct EventEnvelope: Decodable {
        var type: String
        var delta: String?
        var transcript: String?
        var error: ErrorEnvelope?
    }

    private struct ErrorEnvelope: Decodable {
        var message: String
    }
}

enum OpenAIRealtimeMessageFactory {
    static func sessionUpdate(configuration: RealtimeTranslationConfiguration) throws -> Data {
        let instructions = """
        You are a real-time meeting interpreter.
        Translate all incoming speech into \(configuration.targetLocale).
        Output only the translation.
        Preserve meaning, tone, intent, names, numbers, dates, and business context.
        Do not answer the speaker or add commentary.
        """
        let event = SessionUpdateEvent(
            session: Session(
                model: configuration.model,
                instructions: instructions,
                audio: Audio(
                    input: AudioInputConfig(turnDetection: TurnDetection(type: "server_vad")),
                    output: AudioOutputConfig(
                        voice: configuration.voice,
                        format: AudioFormat(type: "audio/pcm", rate: 24_000)
                    )
                )
            )
        )
        return try JSONEncoder().encode(event)
    }

    static func appendAudio(_ pcm16: Data) throws -> Data {
        try JSONEncoder().encode(AppendAudioEvent(audio: pcm16.base64EncodedString()))
    }

    private struct SessionUpdateEvent: Encodable {
        var type = "session.update"
        var session: Session
    }

    private struct Session: Encodable {
        var type = "realtime"
        var model: String
        var instructions: String
        var audio: Audio
    }

    private struct Audio: Encodable {
        var input: AudioInputConfig
        var output: AudioOutputConfig
    }

    private struct AudioInputConfig: Encodable {
        enum CodingKeys: String, CodingKey {
            case turnDetection = "turn_detection"
        }

        var turnDetection: TurnDetection
    }

    private struct TurnDetection: Encodable {
        var type: String
    }

    private struct AudioOutputConfig: Encodable {
        var voice: String
        var format: AudioFormat
    }

    private struct AudioFormat: Encodable {
        var type: String
        var rate: Int
    }

    private struct AppendAudioEvent: Encodable {
        var type = "input_audio_buffer.append"
        var audio: String
    }
}
