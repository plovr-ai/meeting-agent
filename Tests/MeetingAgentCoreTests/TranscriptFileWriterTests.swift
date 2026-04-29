import XCTest
@testable import MeetingAgentCore

final class TranscriptFileWriterTests: XCTestCase {
    func testTranscriptSegmentDecodesMissingSpeechFinalAsFalse() throws {
        let data = Data("""
        {
          "version": 1,
          "segments": [
            {
              "id": "segment-1",
              "text": "hello",
              "sourceProvider": "deepgram-transcribe",
              "isFinal": true,
              "createdAt": "2026-04-28T00:00:00Z",
              "timingSource": "unavailable"
            }
          ]
        }
        """.utf8)

        let document = try JSONDecoder.meetingAgent.decode(TranscriptDocument.self, from: data)

        XCTAssertEqual(document.segments.first?.speechFinal, false)
    }

    func testTranscriptWriterReplacesPartialTextWithLatestText() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("probe-transcript-\(UUID().uuidString).txt")
        let jsonURL = url.deletingPathExtension().appendingPathExtension("json")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: jsonURL)
        }

        let writer = try TranscriptFileWriter(url: url)
        try writer.replace(with: "hello")
        try writer.replace(with: "hello world")
        try writer.close()

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "hello world\n")
        XCTAssertEqual(try TranscriptFileWriter.readDocument(from: jsonURL), TranscriptDocument())
    }

    func testTranscriptWriterPlainTextReplaceClearsStructuredSegments() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("probe-transcript-\(UUID().uuidString).txt")
        let jsonURL = url.deletingPathExtension().appendingPathExtension("json")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: jsonURL)
        }

        let writer = try TranscriptFileWriter(url: url)
        try writer.replace(with: [TranscriptSegment(id: "segment-1", text: "structured text")])
        try writer.replace(with: "Speech recognition unavailable")

        XCTAssertEqual(TranscriptFileWriter.renderedTranscript(textURL: url, structuredURL: jsonURL), "Speech recognition unavailable\n")
        XCTAssertEqual(try TranscriptFileWriter.readDocument(from: jsonURL), TranscriptDocument())
    }

    func testTranscriptWriterRendersTextFromStructuredSegments() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("probe-transcript-\(UUID().uuidString).txt")
        let jsonURL = url.deletingPathExtension().appendingPathExtension("json")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: jsonURL)
        }

        let writer = try TranscriptFileWriter(url: url)
        try writer.replace(with: [
            TranscriptSegment(
                id: "segment-1",
                startTimeSeconds: 0,
                endTimeSeconds: 1.25,
                text: "hello",
                language: "en-US",
                sourceProvider: "whisper",
                isFinal: true,
                confidence: 0.87,
                createdAt: Date(timeIntervalSince1970: 1_777_000_000),
                timingSource: .approximate
            )
        ])
        try writer.close()

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "User A:\nhello\n")
        let document = try TranscriptFileWriter.readDocument(from: jsonURL)
        XCTAssertEqual(document.version, 1)
        XCTAssertEqual(document.segments.first?.id, "segment-1")
        XCTAssertEqual(document.segments.first?.speakerID, "speaker-1")
        XCTAssertEqual(document.segments.first?.speakerLabel, "User A")
        XCTAssertEqual(document.segments.first?.startTimeSeconds, 0)
        XCTAssertEqual(document.segments.first?.endTimeSeconds, 1.25)
        XCTAssertEqual(document.segments.first?.language, "en-US")
        XCTAssertEqual(document.segments.first?.sourceProvider, "whisper")
        XCTAssertEqual(document.segments.first?.isFinal, true)
        XCTAssertEqual(document.segments.first?.confidence, 0.87)
        XCTAssertEqual(document.segments.first?.timingSource, .approximate)
    }

    func testRenderedTranscriptPrefersStructuredSegmentsAndFallsBackToPlainText() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("probe-transcript-\(UUID().uuidString).txt")
        let jsonURL = url.deletingPathExtension().appendingPathExtension("json")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: jsonURL)
        }

        try "legacy text\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(TranscriptFileWriter.renderedTranscript(textURL: url, structuredURL: jsonURL), "legacy text\n")

        let writer = try TranscriptFileWriter(url: url)
        try writer.replace(with: [TranscriptSegment(id: "segment-1", text: "structured text")])

        XCTAssertEqual(TranscriptFileWriter.renderedTranscript(textURL: url, structuredURL: jsonURL), "User A:\nstructured text")
    }

    func testUpsertReplacesExistingSegmentWithSameID() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("probe-transcript-\(UUID().uuidString).txt")
        let jsonURL = url.deletingPathExtension().appendingPathExtension("json")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: jsonURL)
        }
        let writer = try TranscriptFileWriter(url: url)

        try writer.upsert(TranscriptSegment(id: "active", text: "hello", isFinal: false))
        try writer.upsert(TranscriptSegment(id: "active", text: "hello world", isFinal: true))

        let document = try TranscriptFileWriter.readDocument(from: jsonURL)
        XCTAssertEqual(document.segments.map(\.id), ["active"])
        XCTAssertEqual(document.segments.map(\.text), ["hello world"])
        XCTAssertEqual(document.segments.map(\.isFinal), [true])
        XCTAssertEqual(
            try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
            "User A:\nhello world"
        )
    }

    func testUpsertFinalSegmentReplacesOverlappingInterimWithShiftedID() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("probe-transcript-\(UUID().uuidString).txt")
        let jsonURL = url.deletingPathExtension().appendingPathExtension("json")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: jsonURL)
        }
        let writer = try TranscriptFileWriter(url: url)

        try writer.upsert(TranscriptSegment(
            id: "deepgram-transcribe-stream-7.59",
            startTimeSeconds: 7.59,
            endTimeSeconds: 11.67,
            text: "to give it a like as it really does help the channel. Thank you very much for your support.",
            sourceProvider: "deepgram-transcribe",
            isFinal: false,
            timingSource: .precise
        ))
        try writer.upsert(TranscriptSegment(
            id: "deepgram-transcribe-stream-7.51",
            startTimeSeconds: 7.51,
            endTimeSeconds: 11.75,
            text: "to give it a like as it really does help the channel. Thank you very much for your support.",
            sourceProvider: "deepgram-transcribe",
            isFinal: true,
            timingSource: .precise
        ))

        let document = try TranscriptFileWriter.readDocument(from: jsonURL)
        XCTAssertEqual(document.segments.map(\.id), ["deepgram-transcribe-stream-7.51"])
        XCTAssertEqual(document.segments.map(\.isFinal), [true])
    }

    func testUpsertInterimSegmentDoesNotDuplicateOverlappingFinalWithShiftedID() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("probe-transcript-\(UUID().uuidString).txt")
        let jsonURL = url.deletingPathExtension().appendingPathExtension("json")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: jsonURL)
        }
        let writer = try TranscriptFileWriter(url: url)

        try writer.upsert(TranscriptSegment(
            id: "deepgram-transcribe-stream-28.77",
            startTimeSeconds: 28.77,
            endTimeSeconds: 32.53,
            text: "look at all the different languages, nine of them that we shared earlier.",
            sourceProvider: "deepgram-transcribe",
            isFinal: true,
            timingSource: .precise
        ))
        try writer.upsert(TranscriptSegment(
            id: "deepgram-transcribe-stream-28.69",
            startTimeSeconds: 28.69,
            endTimeSeconds: 32.53,
            text: "look at all the different languages, nine of them that we shared earlier.",
            sourceProvider: "deepgram-transcribe",
            isFinal: false,
            timingSource: .precise
        ))

        let document = try TranscriptFileWriter.readDocument(from: jsonURL)
        XCTAssertEqual(document.segments.map(\.id), ["deepgram-transcribe-stream-28.77"])
        XCTAssertEqual(document.segments.map(\.isFinal), [true])
    }

    func testUpsertFinalSegmentReplacesPartiallyOverlappingInterimWithSameUtteranceText() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("probe-transcript-\(UUID().uuidString).txt")
        let jsonURL = url.deletingPathExtension().appendingPathExtension("json")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: jsonURL)
        }
        let writer = try TranscriptFileWriter(url: url)
        let speaker = TranscriptSpeaker(identifier: "deepgram-speaker-0")

        try writer.upsert(TranscriptSegment(
            id: "deepgram-transcribe-stream-0.0",
            speaker: speaker,
            startTimeSeconds: 0,
            endTimeSeconds: 10,
            text: "this is a partially overlapping streaming utterance",
            sourceProvider: "deepgram-transcribe",
            isFinal: false,
            timingSource: .precise
        ))
        try writer.upsert(TranscriptSegment(
            id: "deepgram-transcribe-stream-5.0",
            speaker: speaker,
            startTimeSeconds: 5,
            endTimeSeconds: 15,
            text: "this is a partially overlapping streaming utterance",
            sourceProvider: "deepgram-transcribe",
            isFinal: true,
            timingSource: .precise
        ))

        let document = try TranscriptFileWriter.readDocument(from: jsonURL)
        XCTAssertEqual(document.segments.map(\.id), ["deepgram-transcribe-stream-5.0"])
        XCTAssertEqual(document.segments.map(\.isFinal), [true])
    }

    func testUpsertInterimSegmentReplacesPartiallyOverlappingInterimWithSameUtteranceText() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("probe-transcript-\(UUID().uuidString).txt")
        let jsonURL = url.deletingPathExtension().appendingPathExtension("json")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: jsonURL)
        }
        let writer = try TranscriptFileWriter(url: url)
        let speaker = TranscriptSpeaker(identifier: "deepgram-speaker-0")

        try writer.upsert(TranscriptSegment(
            id: "deepgram-transcribe-stream-0.0",
            speaker: speaker,
            startTimeSeconds: 0,
            endTimeSeconds: 10,
            text: "this is a partially overlapping streaming utterance",
            sourceProvider: "deepgram-transcribe",
            isFinal: false,
            timingSource: .precise
        ))
        try writer.upsert(TranscriptSegment(
            id: "deepgram-transcribe-stream-5.0",
            speaker: speaker,
            startTimeSeconds: 5,
            endTimeSeconds: 15,
            text: "this is a partially overlapping streaming utterance",
            sourceProvider: "deepgram-transcribe",
            isFinal: false,
            timingSource: .precise
        ))

        let document = try TranscriptFileWriter.readDocument(from: jsonURL)
        XCTAssertEqual(document.segments.map(\.id), ["deepgram-transcribe-stream-5.0"])
        XCTAssertEqual(document.segments.map(\.isFinal), [false])
    }

    func testUpsertInterimSegmentDoesNotDuplicateCoveredFinalWhenInterimArrivesAfterFinal() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("probe-transcript-\(UUID().uuidString).txt")
        let jsonURL = url.deletingPathExtension().appendingPathExtension("json")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: jsonURL)
        }
        let writer = try TranscriptFileWriter(url: url)
        let speaker = TranscriptSpeaker(identifier: "deepgram-speaker-0", label: "User A")

        try writer.upsert(TranscriptSegment(
            id: "deepgram-transcribe-stream-0.0",
            speaker: speaker,
            startTimeSeconds: 0,
            endTimeSeconds: 4.1800003,
            text: "Hear your voice, but it really uses your intonation. Your voice.",
            sourceProvider: "deepgram-transcribe",
            isFinal: true,
            timingSource: .precise
        ))
        try writer.upsert(TranscriptSegment(
            id: "deepgram-transcribe-stream-0.08",
            speaker: speaker,
            startTimeSeconds: 0.08,
            endTimeSeconds: 4.08,
            text: "Hear your voice, but it really uses your intonation, your voice.",
            sourceProvider: "deepgram-transcribe",
            isFinal: false,
            timingSource: .precise
        ))

        let document = try TranscriptFileWriter.readDocument(from: jsonURL)
        XCTAssertEqual(document.segments.map(\.id), ["deepgram-transcribe-stream-0.0"])
        XCTAssertEqual(document.segments.map(\.isFinal), [true])
    }

    func testUpsertFinalSegmentReplacesCoveredDeepgramInterimsEvenWhenTextDrifts() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("probe-transcript-\(UUID().uuidString).txt")
        let jsonURL = url.deletingPathExtension().appendingPathExtension("json")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: jsonURL)
        }
        let writer = try TranscriptFileWriter(url: url)
        let speaker = TranscriptSpeaker(identifier: "deepgram-speaker-0")

        try writer.upsert(TranscriptSegment(
            id: "deepgram-transcribe-stream-4.97",
            speaker: speaker,
            startTimeSeconds: 4.97,
            endTimeSeconds: 7.85,
            text: "You I think you selected a female. What was",
            sourceProvider: "deepgram-transcribe",
            isFinal: false,
            timingSource: .precise
        ))
        try writer.upsert(TranscriptSegment(
            id: "deepgram-transcribe-stream-13.1",
            speaker: speaker,
            startTimeSeconds: 13.1,
            endTimeSeconds: 17.18,
            text: "just just go to settings Yes. And just have it use your own voice. Absolutely.",
            sourceProvider: "deepgram-transcribe",
            isFinal: false,
            timingSource: .precise
        ))
        try writer.upsert(TranscriptSegment(
            id: "deepgram-transcribe-stream-0.0",
            speaker: speaker,
            startTimeSeconds: 0,
            endTimeSeconds: 27.52,
            text: "Like, you're really speaking in Spanish. It's incredible. Danny So Danny. You I think you selected a female voice. Maybe yeah. That's what I'm hearing. I'm hearing the female voice. So just just go to settings Yes. And just have it use your own voice. Absolutely.",
            sourceProvider: "deepgram-transcribe",
            isFinal: true,
            speechFinal: true,
            timingSource: .precise
        ))

        let document = try TranscriptFileWriter.readDocument(from: jsonURL)
        XCTAssertEqual(document.segments.map(\.id), ["deepgram-transcribe-stream-0.0"])
        XCTAssertEqual(document.segments.map(\.isFinal), [true])
    }

    func testUpsertFinalSegmentReplacesCoveredDeepgramInterimWhenSpeakerDrifts() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("probe-transcript-\(UUID().uuidString).txt")
        let jsonURL = url.deletingPathExtension().appendingPathExtension("json")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: jsonURL)
        }
        let writer = try TranscriptFileWriter(url: url)

        try writer.upsert(TranscriptSegment(
            id: "deepgram-transcribe-stream-8.92",
            speaker: TranscriptSpeaker(identifier: "deepgram-speaker-0", label: "User A"),
            startTimeSeconds: 8.92,
            endTimeSeconds: 12.12,
            text: "and I actually couldn't believe that something like this existed because",
            sourceProvider: "deepgram-transcribe",
            isFinal: false,
            timingSource: .precise
        ))
        try writer.upsert(TranscriptSegment(
            id: "deepgram-transcribe-stream-9.0",
            speaker: TranscriptSpeaker(identifier: "deepgram-speaker-1", label: "User B"),
            startTimeSeconds: 9,
            endTimeSeconds: 21.670002,
            text: "and I actually couldn't believe that something like this existed because it reminded me of the United Nations meetings that I used to watch where there was an interpreter, and this was a human interpreter, but now that's being replaced with AI",
            sourceProvider: "deepgram-transcribe",
            isFinal: true,
            speechFinal: true,
            timingSource: .precise
        ))

        let document = try TranscriptFileWriter.readDocument(from: jsonURL)
        XCTAssertEqual(document.segments.map(\.id), ["deepgram-transcribe-stream-9.0"])
        XCTAssertEqual(document.segments.map(\.isFinal), [true])
    }

    func testExpandingFinalSegmentWithSameIDRemovesNewlyCoveredInterims() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("probe-transcript-\(UUID().uuidString).txt")
        let jsonURL = url.deletingPathExtension().appendingPathExtension("json")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: jsonURL)
        }
        let writer = try TranscriptFileWriter(url: url)
        let speaker = TranscriptSpeaker(identifier: "deepgram-speaker-0", label: "User A")

        try writer.upsert(TranscriptSegment(
            id: "deepgram-transcribe-stream-4.96",
            speaker: speaker,
            startTimeSeconds: 4.96,
            endTimeSeconds: 9.44,
            text: "Hi there. Welcome to Collaboration Simplified. My name is Sherwin Chaffee, and I work at my",
            sourceProvider: "deepgram-transcribe",
            isFinal: true,
            timingSource: .precise
        ))
        try writer.upsert(TranscriptSegment(
            id: "deepgram-transcribe-stream-12.63",
            speaker: speaker,
            startTimeSeconds: 12.63,
            endTimeSeconds: 17.11,
            text: "Now in this channel, we often build our own autonomous agents, but today,",
            sourceProvider: "deepgram-transcribe",
            isFinal: false,
            timingSource: .precise
        ))
        try writer.upsert(TranscriptSegment(
            id: "deepgram-transcribe-stream-4.96",
            speaker: speaker,
            startTimeSeconds: 4.96,
            endTimeSeconds: 31.230001,
            text: "Hi there. Welcome to Collaboration Simplified. My name is Sherwin Chaffee, and I work at my Microsoft as a copilot principal technical specialist. Now in this channel, we often build our own autonomous agents, but today, I'm very excited to share an agent that Microsoft has built and that is the interpreter agent. So I I just It works.",
            sourceProvider: "deepgram-transcribe",
            isFinal: true,
            timingSource: .precise
        ))

        let document = try TranscriptFileWriter.readDocument(from: jsonURL)
        XCTAssertEqual(document.segments.map(\.id), ["deepgram-transcribe-stream-4.96"])
        XCTAssertEqual(document.segments.map(\.isFinal), [true])
    }

    func testAdjacentFinalSegmentsRemoveInterimSpanningTheirBoundary() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("probe-transcript-\(UUID().uuidString).txt")
        let jsonURL = url.deletingPathExtension().appendingPathExtension("json")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: jsonURL)
        }
        let writer = try TranscriptFileWriter(url: url)
        let speaker = TranscriptSpeaker(identifier: "deepgram-speaker-0", label: "User A")

        try writer.upsert(TranscriptSegment(
            id: "deepgram-transcribe-stream-0.08",
            speaker: speaker,
            startTimeSeconds: 0.08,
            endTimeSeconds: 25.04,
            text: "And simplified. My name is Sherwin Shaffee, and I work at Micro Microsoft as a copilot principal technical specialist. Now on this channel, we often build our own autonomous agents, but today, I'm very excited to share an agent that Microsoft has built and that is the interpreter agent. So I I just No. It works. It",
            sourceProvider: "deepgram-transcribe",
            isFinal: true,
            timingSource: .precise
        ))
        try writer.upsert(TranscriptSegment(
            id: "deepgram-transcribe-stream-23.36",
            speaker: speaker,
            startTimeSeconds: 23.36,
            endTimeSeconds: 25.84,
            text: "No. It works. It works very well.",
            sourceProvider: "deepgram-transcribe",
            isFinal: false,
            timingSource: .precise
        ))
        try writer.upsert(TranscriptSegment(
            id: "deepgram-transcribe-stream-25.04",
            speaker: TranscriptSpeaker(identifier: "deepgram-speaker-1", label: "User B"),
            startTimeSeconds: 25.04,
            endTimeSeconds: 28.48,
            text: "works very well. It works very very well. Oh,",
            sourceProvider: "deepgram-transcribe",
            isFinal: true,
            timingSource: .precise
        ))

        let document = try TranscriptFileWriter.readDocument(from: jsonURL)
        XCTAssertEqual(document.segments.map(\.id), [
            "deepgram-transcribe-stream-0.08",
            "deepgram-transcribe-stream-25.04"
        ])
        XCTAssertEqual(document.segments.map(\.isFinal), [true, true])
    }

    func testInterimSegmentKeepsOnlyTextBeyondExistingFinalPrefixOverlap() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("probe-transcript-\(UUID().uuidString).txt")
        let jsonURL = url.deletingPathExtension().appendingPathExtension("json")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: jsonURL)
        }
        let writer = try TranscriptFileWriter(url: url)
        let speaker = TranscriptSpeaker(identifier: "deepgram-speaker-1", label: "User B")

        try writer.upsert(TranscriptSegment(
            id: "deepgram-transcribe-stream-15.309999",
            speaker: speaker,
            startTimeSeconds: 15.309999,
            endTimeSeconds: 21.630001,
            text: "No. It works. It works very well. It works very, very well. Oh, wow. That's awesome.",
            sourceProvider: "deepgram-transcribe",
            isFinal: true,
            timingSource: .precise
        ))
        try writer.upsert(TranscriptSegment(
            id: "deepgram-transcribe-stream-18.11",
            speaker: speaker,
            startTimeSeconds: 18.11,
            endTimeSeconds: 22.35,
            text: "It works very, very well. Oh, wow. That's awesome. Now this",
            sourceProvider: "deepgram-transcribe",
            isFinal: false,
            timingSource: .precise
        ))

        let document = try TranscriptFileWriter.readDocument(from: jsonURL)
        XCTAssertEqual(document.segments.map(\.id), [
            "deepgram-transcribe-stream-15.309999",
            "deepgram-transcribe-stream-18.11"
        ])
        XCTAssertEqual(document.segments.map(\.text), [
            "No. It works. It works very well. It works very, very well. Oh, wow. That's awesome.",
            "Now this"
        ])
        XCTAssertEqual(document.segments.last?.startTimeSeconds, 21.630001)
    }

    func testAdjacentFinalSegmentsTogetherPruneCoveredInterim() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("probe-transcript-\(UUID().uuidString).txt")
        let jsonURL = url.deletingPathExtension().appendingPathExtension("json")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: jsonURL)
        }
        let writer = try TranscriptFileWriter(url: url)
        let speaker = TranscriptSpeaker(identifier: "deepgram-speaker-0", label: "User A")

        try writer.upsert(TranscriptSegment(
            id: "deepgram-transcribe-stream-0.0",
            speaker: speaker,
            startTimeSeconds: 0,
            endTimeSeconds: 2,
            text: "Alpha beta",
            sourceProvider: "deepgram-transcribe",
            isFinal: true,
            timingSource: .precise
        ))
        try writer.upsert(TranscriptSegment(
            id: "deepgram-transcribe-stream-2.0",
            speaker: speaker,
            startTimeSeconds: 2,
            endTimeSeconds: 4,
            text: "gamma delta",
            sourceProvider: "deepgram-transcribe",
            isFinal: true,
            timingSource: .precise
        ))
        try writer.upsert(TranscriptSegment(
            id: "deepgram-transcribe-stream-0.1",
            speaker: speaker,
            startTimeSeconds: 1.5,
            endTimeSeconds: 2.5,
            text: "beta gamma",
            sourceProvider: "deepgram-transcribe",
            isFinal: false,
            timingSource: .precise
        ))

        let document = try TranscriptFileWriter.readDocument(from: jsonURL)
        XCTAssertEqual(document.segments.map(\.id), [
            "deepgram-transcribe-stream-0.0",
            "deepgram-transcribe-stream-2.0"
        ])
    }

    func testUpdateSpeakerLabelRewritesStructuredAndRenderedTranscript() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("probe-transcript-\(UUID().uuidString).txt")
        let jsonURL = url.deletingPathExtension().appendingPathExtension("json")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: jsonURL)
        }
        let writer = try TranscriptFileWriter(url: url)
        try writer.replace(with: [
            TranscriptSegment(speaker: TranscriptSpeaker(identifier: "speaker-1", label: "User A"), text: "Hello"),
            TranscriptSegment(speaker: TranscriptSpeaker(identifier: "speaker-2", label: "User B"), text: "Hi"),
            TranscriptSegment(speaker: TranscriptSpeaker(identifier: "speaker-1", label: "User A"), text: "Next")
        ])

        try TranscriptFileWriter.updateSpeakerLabel(
            speakerID: "speaker-1",
            label: "Allan",
            textURL: url,
            structuredURL: jsonURL
        )

        let document = try TranscriptFileWriter.readDocument(from: jsonURL)
        XCTAssertEqual(document.segments.map(\.speakerLabel), ["Allan", "User B", "Allan"])
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Allan:\nHello\n\nUser B:\nHi\n\nAllan:\nNext\n")
    }

    func testAppendingSpeakerAfterRenameKeepsOriginalGenericSpeakerSlots() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("probe-transcript-\(UUID().uuidString).txt")
        let jsonURL = url.deletingPathExtension().appendingPathExtension("json")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: jsonURL)
        }
        let writer = try TranscriptFileWriter(url: url)
        try writer.replace(with: [
            TranscriptSegment(speaker: TranscriptSpeaker(identifier: "speaker-1", label: "User A"), text: "Hello")
        ])

        try TranscriptFileWriter.updateSpeakerLabel(
            speakerID: "speaker-1",
            label: "Allan",
            textURL: url,
            structuredURL: jsonURL
        )
        try writer.append(TranscriptSegment(speaker: TranscriptSpeaker(identifier: "speaker-2"), text: "Hi"))

        let document = try TranscriptFileWriter.readDocument(from: jsonURL)
        XCTAssertEqual(document.segments.map(\.speakerLabel), ["Allan", "User B"])
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Allan:\nHello\n\nUser B:\nHi\n")
    }

    func testUpdateSegmentTextRewritesStructuredAndRenderedTranscript() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("probe-transcript-\(UUID().uuidString).txt")
        let jsonURL = url.deletingPathExtension().appendingPathExtension("json")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: jsonURL)
        }
        let writer = try TranscriptFileWriter(url: url)
        try writer.replace(with: [
            TranscriptSegment(id: "segment-1", speaker: TranscriptSpeaker(identifier: "speaker-1", label: "Allan"), text: "Old text"),
            TranscriptSegment(id: "segment-2", speaker: TranscriptSpeaker(identifier: "speaker-1", label: "Allan"), text: "Next")
        ])

        try TranscriptFileWriter.updateSegmentText(
            segmentID: "segment-1",
            text: "Corrected text",
            textURL: url,
            structuredURL: jsonURL
        )

        let document = try TranscriptFileWriter.readDocument(from: jsonURL)
        XCTAssertEqual(document.segments.map(\.text), ["Corrected text", "Next"])
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Allan:\nCorrected text Next\n")
    }
}
