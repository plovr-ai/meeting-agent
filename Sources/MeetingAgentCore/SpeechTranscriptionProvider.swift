import Foundation

public enum SpeechProvider: String, Codable, Equatable, CaseIterable {
    case local
    case whisper

    public static var supportedValuesDescription: String {
        "local, whisper"
    }
}

public protocol AudioFrameTranscriber: AnyObject {
    var failureReason: String? { get }
    func append(_ frame: AudioFrame) throws
    func finish()
}

public extension AudioFrameTranscriber {
    var failureReason: String? { nil }
}

public protocol TranscriptUpdateSink: AnyObject {
    func receive(_ update: TranscriptSegmentUpdate)
    func receiveRealtime(_ update: TranscriptSegmentUpdate)
    func receiveFinal(_ update: TranscriptSegmentUpdate)
}

public protocol SpeechRecognitionEventSink: AnyObject {
    func receive(_ event: SpeechRecognitionEvent)
}

public extension TranscriptUpdateSink {
    func receiveRealtime(_ update: TranscriptSegmentUpdate) {
        receive(update)
    }

    func receiveFinal(_ update: TranscriptSegmentUpdate) {
        receive(update)
    }
}

public struct SpeechTranscriptionContext: Equatable {
    public let inputAudioURL: URL?
    public let transcriptURL: URL
    public let localeIdentifier: String
    public let meetingID: UUID?
    public let previousTranscript: String?

    public init(
        inputAudioURL: URL?,
        transcriptURL: URL,
        localeIdentifier: String,
        meetingID: UUID?,
        previousTranscript: String?
    ) {
        self.inputAudioURL = inputAudioURL
        self.transcriptURL = transcriptURL
        self.localeIdentifier = localeIdentifier
        self.meetingID = meetingID
        self.previousTranscript = previousTranscript
    }
}

public struct SpeechTranscriptionStreamContext {
    public let transcriptURL: URL
    public let localeIdentifier: String
    public let sampleRate: Double
    public let channelCount: Int
    public let performanceEventLogger: PerformanceEventLogger?
    public let transcriptUpdateSink: TranscriptUpdateSink?
    public let speechEventSink: SpeechRecognitionEventSink?

    public init(
        transcriptURL: URL,
        localeIdentifier: String,
        sampleRate: Double,
        channelCount: Int,
        performanceEventLogger: PerformanceEventLogger? = nil,
        transcriptUpdateSink: TranscriptUpdateSink? = nil,
        speechEventSink: SpeechRecognitionEventSink? = nil
    ) {
        self.transcriptURL = transcriptURL
        self.localeIdentifier = localeIdentifier
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.performanceEventLogger = performanceEventLogger
        self.transcriptUpdateSink = transcriptUpdateSink
        self.speechEventSink = speechEventSink
    }
}

public protocol SpeechTranscriptionProvider {
    var provider: SpeechProvider { get }
    func start(transcriptURL: URL, localeIdentifier: String) async throws -> AudioFrameTranscriber
    func start(context: SpeechTranscriptionStreamContext) async throws -> AudioFrameTranscriber
    func transcribeExistingAudio(context: SpeechTranscriptionContext) async throws
}

public extension SpeechTranscriptionProvider {
    func start(context: SpeechTranscriptionStreamContext) async throws -> AudioFrameTranscriber {
        try await start(
            transcriptURL: context.transcriptURL,
            localeIdentifier: context.localeIdentifier
        )
    }

    func transcribeExistingAudio(context: SpeechTranscriptionContext) async throws {
        throw ProbeError.speechRecognition("\(provider.rawValue) does not support retrying from an existing audio file")
    }
}

public struct LocalSpeechTranscriptionProvider: SpeechTranscriptionProvider {
    public let provider: SpeechProvider = .local

    public init() {}

    public func start(transcriptURL: URL, localeIdentifier: String) async throws -> AudioFrameTranscriber {
        try await SystemSpeechTranscriber.start(
            transcriptURL: transcriptURL,
            localeIdentifier: localeIdentifier
        )
    }

    public func start(context: SpeechTranscriptionStreamContext) async throws -> AudioFrameTranscriber {
        try await SystemSpeechTranscriber.start(
            transcriptURL: context.transcriptURL,
            localeIdentifier: context.localeIdentifier,
            environment: .live,
            transcriptUpdateSink: context.transcriptUpdateSink
        )
    }
}

public enum StreamingSpeechTranscriberFactory {
    public static func startTranscriber(
        configuration: SpeechTranscriptionConfiguration,
        transcriptURL: URL,
        sampleRate: Double,
        channelCount: Int,
        performanceEventLogger: PerformanceEventLogger? = nil,
        transcriptUpdateSink: TranscriptUpdateSink? = nil,
        speechEventSink: SpeechRecognitionEventSink? = nil
    ) async throws -> AudioFrameTranscriber {
        let context = SpeechTranscriptionStreamContext(
            transcriptURL: transcriptURL,
            localeIdentifier: configuration.localeIdentifier,
            sampleRate: sampleRate,
            channelCount: channelCount,
            performanceEventLogger: performanceEventLogger,
            transcriptUpdateSink: transcriptUpdateSink,
            speechEventSink: speechEventSink
        )
        if configuration.usesDeepgram {
            return try await DeepgramStreamingSpeechTranscriptionProvider(
                appConfiguration: configuration
            ).start(context: context)
        }
        if configuration.hostedTranscriptionProviderID == SpeechTranscriptionConfiguration.defaultOpenAIRealtimeTranscriptionProviderID {
            return try await OpenAIRealtimeTranscriptionProvider(
                apiKey: configuration.openAIRealtimeAPIKey ?? ProcessInfo.processInfo.environment["MEETING_AGENT_OPENAI_API_KEY"],
                model: configuration.hostedTranscriptionModelID
            ).start(context: context)
        }
        guard configuration.transcriptionExecutionMode == .local else {
            throw ProbeError.speechRecognition("Hosted transcription provider \(configuration.hostedTranscriptionProviderID) does not support streaming audio")
        }
        return try await SpeechTranscriptionProviderFactory.provider(
            for: configuration.provider,
            configuration: configuration
        ).start(context: context)
    }
}

public enum SpeechTranscriptionProviderFactory {
    public static func provider(
        for provider: SpeechProvider,
        configuration: SpeechTranscriptionConfiguration = .default
    ) -> SpeechTranscriptionProvider {
        switch provider {
        case .local:
            return LocalSpeechTranscriptionProvider()
        case .whisper:
            return WhisperSpeechTranscriptionProvider(appConfiguration: configuration)
        }
    }
}
