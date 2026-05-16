import XCTest
@testable import MeetingAgentCore

final class TranscriptConsumptionViewTests: XCTestCase {
    func testProjectorUsesFinalTurnsAndPreservesSpeakerSectionsAndSourceIDs() {
        let document = CaptionDocument(
            speakers: [
                CaptionSpeaker(id: "speaker-1", label: "Allan", providerSpeakerID: "deepgram-speaker-0")
            ],
            turns: [
                CaptionTurn(
                    id: "turn-draft",
                    speakerID: "speaker-1",
                    speakerLabel: "Allan",
                    startTimeSeconds: 0,
                    endTimeSeconds: 1,
                    sections: [CaptionSection(id: "draft-section", text: "draft text", utteranceIDs: ["draft-utt"])],
                    state: .draft,
                    source: CaptionTurnSource(providerID: "deepgram-transcribe", utteranceIDs: ["draft-utt"])
                ),
                CaptionTurn(
                    id: "turn-final",
                    speakerID: "speaker-1",
                    speakerLabel: "Allan",
                    startTimeSeconds: 2,
                    endTimeSeconds: 8,
                    sections: [
                        CaptionSection(id: "section-1", text: "我们确认负责人。", utteranceIDs: ["utt-1"], startTimeSeconds: 2, endTimeSeconds: 4),
                        CaptionSection(id: "section-2", text: "下周一上线。", utteranceIDs: ["utt-2"], startTimeSeconds: 5, endTimeSeconds: 8)
                    ],
                    state: .final,
                    source: CaptionTurnSource(providerID: "deepgram-transcribe", streamID: "stream-1", resultIDs: ["result-1"], utteranceIDs: ["utt-1", "utt-2"])
                )
            ],
            provider: CaptionProviderInfo(id: "deepgram-transcribe", model: "nova-3", locale: "zh-CN")
        )

        let view = TranscriptConsumptionView.project(meetingID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, document: document)

        XCTAssertEqual(view.language, "zh-CN")
        XCTAssertEqual(view.provider?.id, "deepgram-transcribe")
        XCTAssertEqual(view.finalTurns.count, 1)
        XCTAssertEqual(view.finalTurns.first?.turnID, "turn-final")
        XCTAssertEqual(view.finalTurns.first?.speakerID, "speaker-1")
        XCTAssertEqual(view.finalTurns.first?.speakerLabel, "Allan")
        XCTAssertEqual(view.finalTurns.first?.text, "我们确认负责人。\n下周一上线。")
        XCTAssertEqual(view.finalTurns.first?.sourceIDs, ["utt-1", "utt-2"])
        XCTAssertEqual(view.finalTurns.first?.sections.map(\.text), ["我们确认负责人。", "下周一上线。"])
        XCTAssertEqual(view.quality.finalTurnCount, 1)
        XCTAssertEqual(view.quality.draftTurnCount, 1)
        XCTAssertEqual(view.quality.unknownSpeakerTurnCount, 0)
        XCTAssertEqual(view.quality.source, .liveOnly)
        XCTAssertNil(view.quality.fallbackReason)
    }

    func testProjectorFiltersEmptySectionsAndFallsBackToSpeakerID() {
        let document = CaptionDocument(turns: [
            CaptionTurn(
                id: "turn-1",
                speakerID: "speaker-unknown",
                speakerLabel: nil,
                startTimeSeconds: nil,
                endTimeSeconds: nil,
                sections: [
                    CaptionSection(id: "empty", text: "   "),
                    CaptionSection(id: "kept", text: "Needs follow-up.", utteranceIDs: ["utt-3"])
                ],
                state: .final,
                source: CaptionTurnSource(providerID: "provider", utteranceIDs: ["utt-3"])
            )
        ])

        let view = TranscriptConsumptionView.project(meetingID: UUID(), document: document)

        XCTAssertEqual(view.finalTurns.first?.speakerLabel, "speaker-unknown")
        XCTAssertEqual(view.finalTurns.first?.sections.map(\.id), ["kept"])
        XCTAssertEqual(view.quality.emptyFinalTurnCount, 0)
        XCTAssertEqual(view.quality.unknownSpeakerTurnCount, 1)
    }

    func testProjectorPreservesMeSpeakerLabel() {
        let document = CaptionDocument(turns: [
            CaptionTurn(
                id: "turn-me",
                speakerID: "local-user",
                speakerLabel: "Me",
                startTimeSeconds: 1,
                endTimeSeconds: 3,
                sections: [
                    CaptionSection(id: "me-section", text: "I will follow up.", utteranceIDs: ["mic-utt-1"])
                ],
                state: .final,
                source: CaptionTurnSource(providerID: "deepgram-transcribe", utteranceIDs: ["mic-utt-1"])
            )
        ])

        let view = TranscriptConsumptionView.project(meetingID: UUID(), document: document)

        XCTAssertEqual(view.finalTurns.first?.speakerID, "local-user")
        XCTAssertEqual(view.finalTurns.first?.speakerLabel, "Me")
        XCTAssertEqual(view.quality.unknownSpeakerTurnCount, 0)
    }

    func testProjectorPreservesQualitySourceAndRecomputesMetrics() {
        let document = CaptionDocument(
            turns: [
                CaptionTurn(
                    id: "unknown-final",
                    speakerID: nil,
                    speakerLabel: nil,
                    sections: [CaptionSection(id: "kept", text: "Fallback text.")],
                    state: .final,
                    source: CaptionTurnSource(providerID: "deepgram")
                ),
                CaptionTurn(
                    id: "empty-final",
                    sections: [CaptionSection(id: "empty", text: " ")],
                    state: .final,
                    source: CaptionTurnSource(providerID: "deepgram")
                ),
                CaptionTurn(
                    id: "draft",
                    sections: [CaptionSection(id: "draft-section", text: "draft")],
                    state: .draft,
                    source: CaptionTurnSource(providerID: "deepgram")
                )
            ],
            qualityMetadata: TranscriptQualityMetadata(
                source: .refinementFailed,
                fallbackReason: "Transcript refinement failed: timeout",
                metrics: TranscriptQualityMetrics(finalTurnCount: 99),
                updatedAt: Date(timeIntervalSince1970: 10)
            )
        )

        let view = TranscriptConsumptionView.project(meetingID: UUID(), document: document)

        XCTAssertEqual(view.quality.source, .refinementFailed)
        XCTAssertEqual(view.quality.fallbackReason, "Transcript refinement failed: timeout")
        XCTAssertEqual(view.quality.finalTurnCount, 1)
        XCTAssertEqual(view.quality.draftTurnCount, 1)
        XCTAssertEqual(view.quality.unknownSpeakerTurnCount, 1)
        XCTAssertEqual(view.quality.emptyFinalTurnCount, 1)
    }
}
