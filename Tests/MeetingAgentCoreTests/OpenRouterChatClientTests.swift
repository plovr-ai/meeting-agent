import Foundation
import XCTest
@testable import MeetingAgentCore

final class OpenRouterChatClientTests: XCTestCase {
    override func tearDown() {
        OpenRouterURLProtocolStub.reset()
        super.tearDown()
    }

    func testCompleteBuildsAuthorizedJSONRequestAndReturnsContent() async throws {
        OpenRouterURLProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

            let body = try requestBodyData(from: request)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(object["model"] as? String, "openai/gpt-4.1-mini")
            XCTAssertEqual(object["temperature"] as? Double, 0.2)
            XCTAssertEqual((object["response_format"] as? [String: Any])?["type"] as? String, "json_object")
            let messages = try XCTUnwrap(object["messages"] as? [[String: String]])
            XCTAssertEqual(messages, [["role": "user", "content": "Summarize this."]])

            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"choices":[{"message":{"content":"Done"}}]}"#.utf8)
            )
        }
        let client = URLSessionOpenRouterChatClient(session: .openRouterStubbed)

        let content = try await client.complete(
            configuration: .available(apiKey: "test-key", model: "openai/gpt-4.1-mini"),
            messages: [OpenRouterChatMessage(role: "user", content: "Summarize this.")],
            responseFormat: OpenRouterResponseFormat(type: "json_object")
        )

        XCTAssertEqual(content, "Done")
    }

    func testCompleteRejectsUnavailableConfigurationBeforeSendingRequest() async {
        OpenRouterURLProtocolStub.handler = { _ in
            XCTFail("Unavailable configuration must not send a network request")
            throw ProbeError.invalidArguments("unexpected request")
        }
        let client = URLSessionOpenRouterChatClient(session: .openRouterStubbed)

        await XCTAssertThrowsErrorAsync(
            try await client.complete(
                configuration: .unavailable("missing key"),
                messages: [],
                responseFormat: nil
            )
        ) { error in
            XCTAssertEqual(String(describing: error), "OpenRouter configuration is unavailable")
        }
    }

    func testCompleteReportsHTTPErrorBody() async {
        OpenRouterURLProtocolStub.handler = { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(" rate limited \n".utf8)
            )
        }
        let client = URLSessionOpenRouterChatClient(session: .openRouterStubbed)

        await XCTAssertThrowsErrorAsync(
            try await client.complete(
                configuration: .available(apiKey: "key", model: "model"),
                messages: [],
                responseFormat: nil
            )
        ) { error in
            XCTAssertEqual(String(describing: error), "HTTP 429: rate limited")
        }
    }

    func testCompleteRejectsNonHTTPResponse() async {
        OpenRouterURLProtocolStub.handler = { request in
            (URLResponse(url: request.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil), Data())
        }
        let client = URLSessionOpenRouterChatClient(session: .openRouterStubbed)

        await XCTAssertThrowsErrorAsync(
            try await client.complete(
                configuration: .available(apiKey: "key", model: "model"),
                messages: [],
                responseFormat: nil
            )
        ) { error in
            XCTAssertEqual(String(describing: error), "invalid HTTP response")
        }
    }

    func testCompleteRejectsEmptyChoiceContent() async {
        OpenRouterURLProtocolStub.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"choices":[{"message":{"content":"  \n"}}]}"#.utf8)
            )
        }
        let client = URLSessionOpenRouterChatClient(session: .openRouterStubbed)

        await XCTAssertThrowsErrorAsync(
            try await client.complete(
                configuration: .available(apiKey: "key", model: "model"),
                messages: [],
                responseFormat: nil
            )
        ) { error in
            XCTAssertEqual(String(describing: error), "response content was empty")
        }
    }

    func testOpenRouterConfigurationNormalizesInputAndEnvironment() {
        XCTAssertEqual(
            OpenRouterChatConfiguration(apiKey: " key \n", model: " model ").apiKey,
            "key"
        )
        XCTAssertEqual(
            OpenRouterChatConfiguration.environment(
                model: "openai/test",
                environment: ["MEETING_AGENT_OPENROUTER_API_KEY": " env-key "]
            ),
            .available(apiKey: "env-key", model: "openai/test")
        )
        XCTAssertEqual(
            OpenRouterChatConfiguration(apiKey: " ", model: "model"),
            .unavailable("OpenRouter API key is not configured")
        )
        XCTAssertEqual(
            OpenRouterChatConfiguration(apiKey: "key", model: "\n"),
            .unavailable("OpenRouter model is not configured")
        )
    }
}

private extension URLSession {
    static var openRouterStubbed: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenRouterURLProtocolStub.self]
        return URLSession(configuration: configuration)
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> some Any,
    _ verify: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error to be thrown", file: file, line: line)
    } catch {
        verify(error)
    }
}

private func requestBodyData(from request: URLRequest) throws -> Data {
    if let httpBody = request.httpBody {
        return httpBody
    }
    let stream = try XCTUnwrap(request.httpBodyStream)
    stream.open()
    defer { stream.close() }

    var data = Data()
    let bufferSize = 1024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }

    while stream.hasBytesAvailable {
        let count = stream.read(buffer, maxLength: bufferSize)
        if count < 0 {
            throw stream.streamError ?? ProbeError.invalidArguments("Failed to read request body stream")
        }
        if count == 0 {
            break
        }
        data.append(buffer, count: count)
    }
    return data
}

private final class OpenRouterURLProtocolStub: URLProtocol {
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
            let handler = try XCTUnwrap(Self.handler)
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
