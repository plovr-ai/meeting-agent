import XCTest
@testable import MeetingAgentCore

final class SpeakerEmbeddingProviderTests: XCTestCase {
    func testParsesSuccessfulSidecarResponse() throws {
        let data = """
        {
          "modelID": "speechbrain/spkrec-ecapa-voxceleb",
          "embedding": [0.1, 0.2, 0.3],
          "durationSeconds": 3.5,
          "sampleRate": 16000,
          "quality": {"frames": "42"}
        }
        """.data(using: .utf8)!

        let embedding = try SidecarSpeakerEmbeddingProvider.parseResponse(
            data,
            sourceMeetingID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        )

        XCTAssertEqual(embedding.modelID, "speechbrain/spkrec-ecapa-voxceleb")
        XCTAssertEqual(embedding.vector, [0.1, 0.2, 0.3])
        XCTAssertEqual(embedding.durationSeconds, 3.5)
        XCTAssertEqual(embedding.quality["sampleRate"], "16000")
        XCTAssertEqual(embedding.quality["frames"], "42")
    }

    func testParsesRecoverableSidecarError() throws {
        let data = #"{"error":"speechbrain is not installed"}"#.data(using: .utf8)!

        XCTAssertThrowsError(try SidecarSpeakerEmbeddingProvider.parseResponse(data, sourceMeetingID: nil)) { error in
            XCTAssertEqual(String(describing: error), "Sidecar error: speechbrain is not installed")
        }
    }

    func testRejectsEmptyEmbeddingVector() throws {
        let data = #"{"modelID":"fake","embedding":[],"durationSeconds":1,"sampleRate":16000}"#.data(using: .utf8)!

        XCTAssertThrowsError(try SidecarSpeakerEmbeddingProvider.parseResponse(data, sourceMeetingID: nil)) { error in
            XCTAssertEqual(String(describing: error), "Malformed sidecar response: empty embedding")
        }
    }

    func testEmbeddingReportsProcessFailure() async throws {
        let provider = SidecarSpeakerEmbeddingProvider(
            pythonExecutableURL: URL(fileURLWithPath: "/usr/bin/false"),
            scriptURL: URL(fileURLWithPath: "/tmp/missing-speaker-sidecar.py")
        )
        let request = SpeakerEmbeddingRequest(wavURL: URL(fileURLWithPath: "/tmp/missing.wav"), modelID: "fake")

        do {
            _ = try await provider.embedding(for: request)
            XCTFail("Expected sidecar process failure")
        } catch {
            XCTAssertTrue(String(describing: error).contains("Sidecar process failed"))
        }
    }

    func testRequestDefaultsAndErrorDescriptions() {
        let request = SpeakerEmbeddingRequest(wavURL: URL(fileURLWithPath: "/tmp/audio.wav"))

        XCTAssertEqual(request.modelID, "speechbrain/spkrec-ecapa-voxceleb")
        XCTAssertEqual(
            SpeakerEmbeddingProviderError.malformedResponse("bad").description,
            "Malformed sidecar response: bad"
        )
        XCTAssertEqual(
            SpeakerEmbeddingProviderError.processFailed(2, "boom").description,
            "Sidecar process failed (2): boom"
        )
    }
}
