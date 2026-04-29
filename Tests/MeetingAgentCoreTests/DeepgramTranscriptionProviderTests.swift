import XCTest
@testable import MeetingAgentCore

final class DeepgramTranscriptionProviderTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        URLProtocolStub.reset()
    }

    func testConfigurationReportsUnavailableValues() {
        let missingKey = DeepgramTranscriptionConfiguration(apiKey: " ", model: "nova-3")
        let missingModel = DeepgramTranscriptionConfiguration(apiKey: "key", model: nil)

        XCTAssertEqual(missingKey.apiKey, "")
        XCTAssertEqual(missingKey.model, "")
        XCTAssertEqual(missingModel.apiKey, "")
        XCTAssertEqual(missingModel.model, "")
    }

    func testConfigurationFallsBackToEnvironmentAPIKey() {
        let configuration = SpeechTranscriptionConfiguration(
            provider: .whisper,
            localeIdentifier: "en-US",
            targetLocaleIdentifier: "zh-CN",
            bilingualPipelineProfileID: "local-whisper-hosted-translation",
            whisperBinaryPath: nil,
            whisperModelPath: nil,
            transcriptionExecutionMode: .hosted,
            translationExecutionMode: .hosted,
            localTranscriptionProviderID: "whisper-local",
            localTranslationProviderID: "placeholder-local-translation",
            hostedTranscriptionProviderID: "deepgram-transcribe",
            hostedTranslationProviderID: "openrouter-translation",
            hostedTranscriptionModelID: SpeechTranscriptionConfiguration.defaultHostedTranscriptionModelID,
            hostedTranslationModelID: SpeechTranscriptionConfiguration.defaultHostedTranslationModelID,
            openRouterAPIKey: nil,
            openAIRealtimeAPIKey: nil,
            deepgramAPIKey: nil,
            deepgramModelID: "nova-3"
        )

        let output = DeepgramTranscriptionConfiguration.app(
            configuration,
            environment: ["MEETING_AGENT_DEEPGRAM_API_KEY": "env-key"]
        )

        XCTAssertEqual(output.apiKey, "env-key")
        XCTAssertEqual(output.model, "nova-3")
    }

    func testURLSessionClientBuildsRequestAndReturnsData() async throws {
        let wavURL = try makeTemporaryWav()
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Token key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "audio/wav")
            XCTAssertEqual(request.httpBodyStreamData(), Data([0, 1, 2]))
            XCTAssertEqual(request.url?.query?.contains("model=nova-3"), true)
            XCTAssertEqual(request.url?.query?.contains("language="), false)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"ok":true}"#.utf8))
        }
        let client = URLSessionDeepgramTranscriptionClient(
            endpointURL: URL(string: "https://deepgram.test/v1/listen")!,
            session: .stubbed
        )

        let data = try await client.transcribe(
            configuration: DeepgramTranscriptionConfiguration(apiKey: "key", model: "nova-3"),
            wavURL: wavURL
        )

        XCTAssertEqual(String(data: data, encoding: .utf8), #"{"ok":true}"#)
    }

    func testURLSessionClientRejectsUnavailableConfiguration() async {
        let client = URLSessionDeepgramTranscriptionClient(session: .stubbed)

        do {
            _ = try await client.transcribe(
                configuration: DeepgramTranscriptionConfiguration(apiKey: nil, model: "nova-3"),
                wavURL: URL(fileURLWithPath: "/tmp/missing.wav")
            )
            XCTFail("Expected unavailable configuration")
        } catch {
            XCTAssertEqual(String(describing: error), "Deepgram configuration is unavailable")
        }
    }

    func testURLSessionClientRejectsNonHTTPResponse() async throws {
        let wavURL = try makeTemporaryWav()
        URLProtocolStub.handler = { request in
            (URLResponse(url: request.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil), Data())
        }
        let client = URLSessionDeepgramTranscriptionClient(session: .stubbed)

        do {
            _ = try await client.transcribe(
                configuration: DeepgramTranscriptionConfiguration(apiKey: "key", model: "nova-3"),
                wavURL: wavURL
            )
            XCTFail("Expected invalid response")
        } catch {
            XCTAssertEqual(String(describing: error), "invalid HTTP response")
        }
    }

    func testURLSessionClientReportsHTTPFailureBody() async throws {
        let wavURL = try makeTemporaryWav()
        URLProtocolStub.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(" denied \n".utf8))
        }
        let client = URLSessionDeepgramTranscriptionClient(session: .stubbed)

        do {
            _ = try await client.transcribe(
                configuration: DeepgramTranscriptionConfiguration(apiKey: "key", model: "nova-3"),
                wavURL: wavURL
            )
            XCTFail("Expected HTTP status error")
        } catch {
            XCTAssertEqual(String(describing: error), "HTTP 401: denied")
        }
    }

    func testProviderSendsConfiguredRequestAndMapsUtterances() async throws {
        let client = RecordingDeepgramClient(response: """
        {
          "results": {
            "utterances": [
              {
                "id": "utt-1",
                "start": 0.4,
                "end": 1.8,
                "confidence": 0.91,
                "transcript": "hello team",
                "speaker": 2
              }
            ],
            "channels": [
              {
                "alternatives": [
                  { "transcript": "hello team" }
                ]
              }
            ]
          }
        }
        """)
        let provider = DeepgramAudioTranscriptionProvider(
            configuration: DeepgramTranscriptionConfiguration(apiKey: "key", model: "nova-3"),
            client: client
        )
        let wavURL = URL(fileURLWithPath: "/tmp/capture.wav")

        let output = try await provider.transcribe(
            audio: AudioInput(wavURL: wavURL, localeIdentifier: "en-US"),
            options: TranscriptionOptions(sourceLocale: "en-US")
        )

        XCTAssertEqual(client.requests.first?.apiKey, "key")
        XCTAssertEqual(client.requests.first?.model, "nova-3")
        XCTAssertEqual(client.requests.first?.wavURL, wavURL)
        XCTAssertEqual(output.segments.first?.id, "utt-1")
        XCTAssertEqual(output.segments.first?.text, "hello team")
        XCTAssertEqual(output.segments.first?.speakerID, "deepgram-speaker-2")
        XCTAssertNil(output.segments.first?.language)
        XCTAssertNil(output.segments.first?.speakerLabel)
        XCTAssertEqual(output.segments.first?.sourceProvider, "deepgram-transcribe")
    }

    func testProviderLogsRawDeepgramResponseBeforeMapping() async throws {
        let response = """
        {
          "results": {
            "utterances": [
              { "id": "utt-raw", "transcript": "raw hello", "speaker": 1 }
            ]
          }
        }
        """
        let logger = RecordingDeepgramRawResponseLogger()
        let provider = DeepgramAudioTranscriptionProvider(
            configuration: DeepgramTranscriptionConfiguration(apiKey: "key", model: "nova-3"),
            client: RecordingDeepgramClient(response: response),
            rawResponseLogger: logger
        )

        let output = try await provider.transcribe(
            audio: AudioInput(wavURL: URL(fileURLWithPath: "/tmp/capture.wav"), localeIdentifier: "en-US"),
            options: TranscriptionOptions(sourceLocale: "en-US")
        )

        XCTAssertEqual(output.segments.first?.text, "raw hello")
        XCTAssertEqual(logger.entries.count, 1)
        XCTAssertEqual(logger.entries.first?.context.providerID, "deepgram-transcribe")
        XCTAssertEqual(logger.entries.first?.context.transport, .http)
        XCTAssertEqual(String(data: try XCTUnwrap(logger.entries.first?.data), encoding: .utf8), response)
    }

    func testProviderWritesDeepgramSpeakersIntoUserLabelsThroughTranscriptWriter() async throws {
        let transcriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("deepgram-users-\(UUID().uuidString)")
            .appendingPathExtension("txt")
        defer {
            try? FileManager.default.removeItem(at: transcriptURL)
            try? FileManager.default.removeItem(at: transcriptURL.deletingPathExtension().appendingPathExtension("json"))
        }
        let client = RecordingDeepgramClient(response: """
        {
          "results": {
            "utterances": [
              { "id": "utt-1", "start": 0.0, "end": 1.0, "confidence": 0.91, "transcript": "hello", "speaker": 2 },
              { "id": "utt-2", "start": 1.1, "end": 2.0, "confidence": 0.89, "transcript": "hi", "speaker": 7 },
              { "id": "utt-3", "start": 2.1, "end": 3.0, "confidence": 0.90, "transcript": "again", "speaker": 2 }
            ]
          }
        }
        """)
        let provider = DeepgramAudioTranscriptionProvider(
            configuration: DeepgramTranscriptionConfiguration(apiKey: "key", model: "nova-3"),
            client: client
        )

        let output = try await provider.transcribe(
            audio: AudioInput(wavURL: URL(fileURLWithPath: "/tmp/capture.wav"), localeIdentifier: "en-US"),
            options: TranscriptionOptions(sourceLocale: "en-US")
        )
        try TranscriptFileWriter(url: transcriptURL).replace(with: output.segments)

        let document = try TranscriptFileWriter.readDocument(
            from: transcriptURL.deletingPathExtension().appendingPathExtension("json")
        )
        XCTAssertEqual(document.segments.map(\.speakerID), [
            "deepgram-speaker-2",
            "deepgram-speaker-7",
            "deepgram-speaker-2"
        ])
        XCTAssertEqual(document.segments.map(\.speakerLabel), ["User A", "User B", "User A"])
        XCTAssertEqual(
            try String(contentsOf: transcriptURL, encoding: .utf8),
            """
            User A:
            hello

            User B:
            hi

            User A:
            again

            """
        )
    }

    func testProviderFallsBackToChannelTranscriptWhenUtterancesAreAbsent() async throws {
        let client = RecordingDeepgramClient(response: """
        {
          "results": {
            "channels": [
              {
                "alternatives": [
                  {
                    "transcript": "whole transcript",
                    "confidence": 0.8
                  }
                ]
              }
            ]
          }
        }
        """)
        let provider = DeepgramAudioTranscriptionProvider(
            configuration: DeepgramTranscriptionConfiguration(apiKey: "key", model: "nova-3"),
            client: client
        )

        let output = try await provider.transcribe(
            audio: AudioInput(wavURL: URL(fileURLWithPath: "/tmp/capture.wav"), localeIdentifier: "en-US"),
            options: TranscriptionOptions(sourceLocale: "en-US")
        )

        XCTAssertEqual(output.segments.map(\.text), ["whole transcript"])
        XCTAssertEqual(output.segments.first?.confidence, 0.8)
    }

    func testProviderRejectsMissingAudioURL() async {
        let provider = DeepgramAudioTranscriptionProvider(
            configuration: DeepgramTranscriptionConfiguration(apiKey: "key", model: "nova-3"),
            client: RecordingDeepgramClient(response: "{}")
        )

        do {
            _ = try await provider.transcribe(
                audio: AudioInput(wavURL: nil, localeIdentifier: "en-US"),
                options: TranscriptionOptions(sourceLocale: "en-US")
            )
            XCTFail("Expected missing audio URL failure")
        } catch {
            XCTAssertEqual(String(describing: error), "Deepgram transcription requires a WAV file URL")
        }
    }

    func testProviderRejectsUnavailableConfiguration() async {
        let provider = DeepgramAudioTranscriptionProvider(
            configuration: DeepgramTranscriptionConfiguration(apiKey: nil, model: "nova-3"),
            client: RecordingDeepgramClient(response: "{}")
        )

        do {
            _ = try await provider.transcribe(
                audio: AudioInput(wavURL: URL(fileURLWithPath: "/tmp/capture.wav"), localeIdentifier: "en-US"),
                options: TranscriptionOptions(sourceLocale: "en-US")
            )
            XCTFail("Expected unavailable configuration")
        } catch {
            XCTAssertEqual(String(describing: error), "Deepgram configuration is unavailable")
        }
    }

    func testProviderOmitsBlankUtterancesAndUsesGeneratedID() async throws {
        let client = RecordingDeepgramClient(response: """
        {
          "results": {
            "utterances": [
              { "id": " ", "transcript": "   ", "speaker": null },
              { "id": null, "transcript": "kept", "speaker": null }
            ]
          }
        }
        """)
        let provider = DeepgramAudioTranscriptionProvider(
            configuration: DeepgramTranscriptionConfiguration(apiKey: "key", model: "nova-3"),
            client: client
        )

        let output = try await provider.transcribe(
            audio: AudioInput(wavURL: URL(fileURLWithPath: "/tmp/capture.wav"), localeIdentifier: "en-US"),
            options: TranscriptionOptions(sourceLocale: "en-US")
        )

        XCTAssertEqual(output.segments.map(\.text), ["kept"])
        XCTAssertNil(output.segments.first?.speakerID)
        XCTAssertEqual(output.segments.first?.timingSource, .unavailable)
        XCTAssertFalse(output.segments.first?.id.isEmpty ?? true)
    }

    func testProviderReturnsEmptySegmentsWhenNoResultsExist() async throws {
        let provider = DeepgramAudioTranscriptionProvider(
            configuration: DeepgramTranscriptionConfiguration(apiKey: "key", model: "nova-3"),
            client: RecordingDeepgramClient(response: "{}")
        )

        let output = try await provider.transcribe(
            audio: AudioInput(wavURL: URL(fileURLWithPath: "/tmp/capture.wav"), localeIdentifier: "en-US"),
            options: TranscriptionOptions(sourceLocale: "en-US")
        )

        XCTAssertEqual(output.segments, [])
    }

    func testStreamingMapperHandlesNonFinalAndTranscriptFallback() {
        let nonFinal = DeepgramStreamingResponseMapper.segments(
            from: Data(#"{"is_final":false}"#.utf8),
            providerID: "deepgram"
        )
        let fallback = DeepgramStreamingResponseMapper.segments(
            from: Data("""
            {
              "is_final": true,
              "channel": {
                "alternatives": [
                  { "transcript": " fallback text ", "confidence": 0.7, "words": [] }
                ]
              }
            }
            """.utf8),
            providerID: "deepgram"
        )
        let blank = DeepgramStreamingResponseMapper.segments(
            from: Data("""
            {
              "is_final": true,
              "channel": {
                "alternatives": [
                  { "transcript": "   ", "words": [] }
                ]
              }
            }
            """.utf8),
            providerID: "deepgram"
        )

        XCTAssertEqual(nonFinal, [])
        XCTAssertEqual(fallback.map(\.text), ["fallback text"])
        XCTAssertEqual(fallback.first?.confidence, 0.7)
        XCTAssertEqual(blank, [])
    }

    func testStreamingMapperHandlesDefaultSpeakerAndUntimedWords() {
        let output = DeepgramStreamingResponseMapper.segments(
            from: Data("""
            {
              "is_final": true,
              "metadata": { "detected_language": "ja" },
              "channel": {
                "alternatives": [
                  {
                    "transcript": "",
                    "confidence": 0.5,
                    "words": [
                      { "word": "hello", "punctuated_word": null, "speaker": null },
                      { "word": " team ", "punctuated_word": "team.", "speaker": null }
                    ]
                  }
                ]
              }
            }
            """.utf8),
            providerID: "deepgram"
        )

        XCTAssertEqual(output.count, 1)
        XCTAssertEqual(output.first?.text, "hello team.")
        XCTAssertEqual(output.first?.language, "ja")
        XCTAssertNil(output.first?.speakerID)
        XCTAssertEqual(output.first?.timingSource, .unavailable)
    }

    func testStreamingProviderRejectsUnavailableConfiguration() async {
        let provider = DeepgramStreamingSpeechTranscriptionProvider(
            configuration: DeepgramTranscriptionConfiguration(apiKey: nil, model: "nova-3"),
            client: RecordingDeepgramStreamingClient()
        )

        do {
            _ = try await provider.start(context: SpeechTranscriptionStreamContext(
                transcriptURL: URL(fileURLWithPath: "/tmp/transcript.txt"),
                localeIdentifier: "en-US",
                sampleRate: 16_000,
                channelCount: 1
            ))
            XCTFail("Expected unavailable configuration")
        } catch {
            XCTAssertEqual(String(describing: error), "Deepgram configuration is unavailable")
        }
    }

    func testErrorDescriptions() {
        XCTAssertEqual(String(describing: DeepgramTranscriptionError.invalidRequest), "invalid Deepgram request")
        XCTAssertEqual(String(describing: DeepgramTranscriptionError.invalidResponse), "invalid HTTP response")
        XCTAssertEqual(String(describing: DeepgramTranscriptionError.httpStatus(500, nil)), "HTTP 500")
        XCTAssertEqual(String(describing: DeepgramTranscriptionError.unavailable("missing")), "missing")
    }

    private func makeTemporaryWav() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("deepgram-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        try Data([0, 1, 2]).write(to: url)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}

private final class RecordingDeepgramClient: DeepgramTranscriptionClient {
    struct Request: Equatable {
        let apiKey: String
        let model: String
        let wavURL: URL
    }

    private(set) var requests: [Request] = []
    private let response: String

    init(response: String) {
        self.response = response
    }

    func transcribe(
        configuration: DeepgramTranscriptionConfiguration,
        wavURL: URL
    ) async throws -> Data {
        requests.append(Request(
            apiKey: configuration.apiKey,
            model: configuration.model,
            wavURL: wavURL
        ))
        return Data(response.utf8)
    }
}

private final class RecordingDeepgramRawResponseLogger: DeepgramRawResponseLogger {
    struct Entry {
        let data: Data
        let context: DeepgramRawResponseContext
    }

    private(set) var entries: [Entry] = []

    func logRawResponse(_ data: Data, context: DeepgramRawResponseContext) {
        entries.append(Entry(data: data, context: context))
    }
}

private final class RecordingDeepgramStreamingClient: DeepgramStreamingTranscriptionClient {
    func connect(
        configuration: DeepgramTranscriptionConfiguration,
        sampleRate: Double,
        channelCount: Int
    ) async throws -> DeepgramStreamingTranscriptionSession {
        RecordingDeepgramStreamingSession()
    }
}

private final class RecordingDeepgramStreamingSession: DeepgramStreamingTranscriptionSession {
    var segments: AsyncStream<TranscriptSegment> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func send(_ frame: AudioFrame) async throws {}
    func close() async {}
}

private extension URLSession {
    static var stubbed: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }
}

private final class URLProtocolStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (URLResponse, Data))?

    static func reset() {
        handler = nil
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            guard let handler = Self.handler else {
                throw ProbeError.invalidArguments("Missing URLProtocolStub handler")
            }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension URLRequest {
    func httpBodyStreamData() -> Data? {
        guard let stream = httpBodyStream else { return httpBody }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
