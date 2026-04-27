import Foundation

public protocol RealtimeFrameConsumer: AnyObject {
    func consumeRealtimeFrames(_ frames: [AudioFrame])
}

public final class RealtimeTranslationController: RealtimeFrameConsumer {
    private let provider: RealtimeSpeechTranslationProvider
    private let playbackSink: AudioPlaybackSink?
    private let rolloverFrameLimit: Int?
    private var session: RealtimeTranslationSession?
    private var eventTask: Task<Void, Never>?
    private var store = LiveTranslationStore()
    private var activeConfiguration: RealtimeTranslationConfiguration?
    private var appendedFrameCount = 0

    public private(set) var status: RealtimeTranslationStatus = .idle

    public var liveTranslationTurns: [LiveTranslationTurn] {
        store.turns
    }

    public init(
        provider: RealtimeSpeechTranslationProvider = OpenAIRealtimeSpeechTranslationProvider(),
        playbackSink: AudioPlaybackSink? = nil
    ) {
        self.provider = provider
        self.playbackSink = playbackSink
        self.rolloverFrameLimit = nil
    }

    public init(
        provider: RealtimeSpeechTranslationProvider = OpenAIRealtimeSpeechTranslationProvider(),
        playbackSink: AudioPlaybackSink? = nil,
        rolloverFrameLimit: Int?
    ) {
        self.provider = provider
        self.playbackSink = playbackSink
        self.rolloverFrameLimit = rolloverFrameLimit
    }

    public func start(configuration: RealtimeTranslationConfiguration) async {
        await stop()
        activeConfiguration = configuration
        store.reset(targetLocale: configuration.targetLocale)
        status = .connecting
        do {
            try await startSession(configuration: configuration)
        } catch {
            status = .failed(Self.errorMessage(error))
        }
    }

    public func append(_ frames: [AudioFrame]) async {
        guard session != nil, !frames.isEmpty else { return }
        do {
            if shouldRollover(addingFrameCount: frames.count) {
                try await rolloverSession()
            }
            guard let activeSession = session else { return }
            try await activeSession.append(frames)
            appendedFrameCount += frames.count
        } catch {
            status = .degraded(Self.errorMessage(error))
        }
    }

    public func consumeRealtimeFrames(_ frames: [AudioFrame]) {
        Task { [weak self] in
            await self?.append(frames)
        }
    }

    public func stop() async {
        eventTask?.cancel()
        eventTask = nil
        await session?.stop()
        session = nil
        activeConfiguration = nil
        appendedFrameCount = 0
        await playbackSink?.stop()
        status = .idle
    }

    private func startSession(configuration: RealtimeTranslationConfiguration) async throws {
        let startedSession = try await provider.start(configuration: configuration)
        session = startedSession
        appendedFrameCount = 0
        status = .connected
        eventTask = Task { [weak self, startedSession] in
            for await event in startedSession.events {
                await self?.handle(event)
            }
        }
    }

    private func shouldRollover(addingFrameCount frameCount: Int) -> Bool {
        guard let rolloverFrameLimit, rolloverFrameLimit > 0 else { return false }
        return appendedFrameCount > 0 && appendedFrameCount + frameCount > rolloverFrameLimit
    }

    private func rolloverSession() async throws {
        guard let configuration = activeConfiguration else { return }
        eventTask?.cancel()
        eventTask = nil
        await session?.stop()
        session = nil
        status = .connecting
        try await startSession(configuration: configuration)
    }

    private func handle(_ event: RealtimeTranslationEvent) async {
        switch event {
        case .connected:
            status = .connected
        case .targetAudioDelta(let data):
            do {
                try await playbackSink?.play(data, sampleRate: 24_000, channelCount: 1)
            } catch {
                status = .degraded("Live translation playback failed: \(Self.errorMessage(error))")
            }
        case .targetTextDelta(let delta):
            store.appendDelta(delta)
        case .targetTextFinal(let text):
            store.finalize(text)
        case .rateLimitsUpdated:
            break
        case .failed(let message):
            status = .failed(message)
        case .stopped:
            if status != .idle {
                status = .idle
            }
        }
    }

    private static func errorMessage(_ error: Error) -> String {
        if let probeError = error as? ProbeError {
            return probeError.description.replacingOccurrences(of: "Invalid arguments: ", with: "")
        }
        return String(describing: error)
    }
}
