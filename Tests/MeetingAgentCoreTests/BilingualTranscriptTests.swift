import XCTest
@testable import MeetingAgentCore

final class BilingualTranscriptTests: XCTestCase {
    func testFormatterRendersSourceAndTargetBySpeakerTurn() {
        let transcript = BilingualTranscript(
            sourceLocale: "ko-KR",
            targetLocale: "zh-CN",
            segments: [
                BilingualSubtitleSegment(
                    id: "segment-1",
                    startTimeSeconds: 1.0,
                    endTimeSeconds: 2.0,
                    speaker: TranscriptSpeaker(identifier: "speaker-1"),
                    sourceText: "오늘 회의는 여기까지 하겠습니다.",
                    targetText: "今天的会议先到这里。",
                    confidence: 0.92,
                    status: .complete,
                    errorMessage: nil,
                    providerChain: ["whisper-local", "openai-translation"]
                )
            ],
            provenance: PipelineProvenance(profileID: "local-whisper-hosted-translation")
        )

        XCTAssertEqual(BilingualTranscriptFormatter.render(transcript), """
        User A:
        Source: 오늘 회의는 여기까지 하겠습니다.
        Target: 今天的会议先到这里。
        """)
    }

    func testFormatterPreservesSourceOnlyFailedTranslation() {
        let transcript = BilingualTranscript(
            sourceLocale: "en-US",
            targetLocale: "ja-JP",
            segments: [
                BilingualSubtitleSegment(
                    id: "segment-1",
                    speaker: .default,
                    sourceText: "Please review the contract.",
                    targetText: "",
                    status: .sourceOnly,
                    errorMessage: "translation timed out",
                    providerChain: ["whisper-local", "openai-translation"]
                )
            ],
            provenance: PipelineProvenance(profileID: "profile")
        )

        XCTAssertEqual(BilingualTranscriptFormatter.render(transcript), """
        User A:
        Source: Please review the contract.
        Target: [translation unavailable: translation timed out]
        """)
    }

    func testCodableRoundTripKeepsProviderChainAndStatus() throws {
        let transcript = BilingualTranscript(
            sourceLocale: "en-US",
            targetLocale: "zh-CN",
            segments: [
                BilingualSubtitleSegment(
                    id: "segment-1",
                    speaker: TranscriptSpeaker(identifier: "speaker-1", label: "Manager"),
                    sourceText: "hello",
                    targetText: "你好",
                    status: .complete,
                    providerChain: ["provider-a"]
                )
            ],
            provenance: PipelineProvenance(
                profileID: "profile",
                attemptedProviders: ["provider-a"],
                successfulProviders: ["provider-a"]
            )
        )

        let data = try JSONEncoder().encode(transcript)
        let decoded = try JSONDecoder().decode(BilingualTranscript.self, from: data)

        XCTAssertEqual(decoded, transcript)
    }
}
