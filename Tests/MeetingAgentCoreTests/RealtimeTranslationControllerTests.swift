import XCTest
@testable import MeetingAgentCore

final class RealtimeTranslationControllerTests: XCTestCase {
    func testStartFailsWithoutAPIKey() async {
        let controller = RealtimeTranslationController(
            provider: FakeRealtimeSpeechTranslationProvider()
        )

        await controller.start(configuration: RealtimeTranslationConfiguration(apiKey: nil))

        XCTAssertEqual(controller.status, .failed("MEETING_AGENT_OPENAI_API_KEY is not configured"))
    }

    func testAppendFramesForwardsToSession() async {
        let provider = FakeRealtimeSpeechTranslationProvider()
        let controller = RealtimeTranslationController(provider: provider)
        await controller.start(configuration: RealtimeTranslationConfiguration(apiKey: "key"))
        let frame = AudioFrame(pcm: Data([1]), sampleRate: 24_000, channelCount: 1, timestampNanos: 0)

        await controller.append([frame])

        XCTAssertEqual(provider.session.appendedFrames, [frame])
    }

    func testEventsUpdateStoreAndPlayback() async throws {
        let provider = FakeRealtimeSpeechTranslationProvider()
        let playback = FakeAudioPlaybackSink()
        let controller = RealtimeTranslationController(provider: provider, playbackSink: playback)
        await controller.start(configuration: RealtimeTranslationConfiguration(apiKey: "key", targetLocale: "zh-CN"))

        try await Task.sleep(nanoseconds: 20_000_000)
        provider.session.emit(.targetTextDelta("你"))
        provider.session.emit(.targetTextFinal("你好。"))
        provider.session.emit(.targetAudioDelta(Data([1, 2, 3])))
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(controller.liveTranslationTurns.map(\.text), ["你好。"])
        XCTAssertEqual(controller.liveTranslationTurns.map(\.isFinal), [true])
        XCTAssertEqual(playback.playedAudio, [Data([1, 2, 3])])
    }

    func testStopStopsSessionAndPlayback() async {
        let provider = FakeRealtimeSpeechTranslationProvider()
        let playback = FakeAudioPlaybackSink()
        let controller = RealtimeTranslationController(provider: provider, playbackSink: playback)
        await controller.start(configuration: RealtimeTranslationConfiguration(apiKey: "key"))

        await controller.stop()

        XCTAssertTrue(provider.session.didStop)
        XCTAssertTrue(playback.didStop)
        XCTAssertEqual(controller.status, .idle)
    }
}

private final class FakeRealtimeSpeechTranslationProvider: RealtimeSpeechTranslationProvider {
    let descriptor = ProviderDescriptor(
        id: "fake-realtime",
        displayName: "Fake Realtime",
        capability: .speechTranslation,
        executionMode: .hosted,
        supportedSourceLocales: ["*"],
        supportedTargetLocales: ["*"],
        requiresNetwork: false,
        requiresAPIKey: false
    )
    let session = FakeRealtimeTranslationSession()

    func start(configuration: RealtimeTranslationConfiguration) async throws -> RealtimeTranslationSession {
        if let error = configuration.validationError {
            throw ProbeError.invalidArguments(error)
        }
        return session
    }
}

private final class FakeRealtimeTranslationSession: RealtimeTranslationSession {
    var appendedFrames: [AudioFrame] = []
    var didStop = false
    private var continuation: AsyncStream<RealtimeTranslationEvent>.Continuation?

    var events: AsyncStream<RealtimeTranslationEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func append(_ frames: [AudioFrame]) async throws {
        appendedFrames.append(contentsOf: frames)
    }

    func stop() async {
        didStop = true
        continuation?.finish()
    }

    func emit(_ event: RealtimeTranslationEvent) {
        continuation?.yield(event)
    }
}

private final class FakeAudioPlaybackSink: AudioPlaybackSink {
    var playedAudio: [Data] = []
    var didStop = false

    func play(_ pcmData: Data, sampleRate: Double, channelCount: Int) async throws {
        playedAudio.append(pcmData)
    }

    func stop() async {
        didStop = true
    }
}
