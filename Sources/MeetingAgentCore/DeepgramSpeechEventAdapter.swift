import Foundation

public enum DeepgramSpeechEventAdapter {
    public static func events(from data: Data, providerID: String) -> [SpeechRecognitionEvent] {
        guard let response = try? JSONDecoder.meetingAgent.decode(DeepgramStreamingResponse.self, from: data),
              let isFinal = response.isFinal,
              let alternative = response.channel?.alternatives.first
        else {
            return []
        }

        let words = alternative.words ?? []
        let runs = speakerRuns(from: words)
        if runs.isEmpty {
            let text = alternative.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            return [
                event(
                    isFinal: isFinal,
                    payload: SpeechUtterancePayload(
                        providerID: providerID,
                        providerResultID: response.metadata?.requestID,
                        providerUtteranceID: activeUtteranceID(providerID: providerID, words: words, responseStart: response.start),
                        speaker: nil,
                        startTimeSeconds: response.start,
                        endTimeSeconds: response.start.map { $0 + (response.duration ?? 0) },
                        text: text,
                        language: response.metadata?.detectedLanguage,
                        confidence: alternative.confidence,
                        boundary: SpeechBoundary(
                            speechFinal: response.speechFinal == true,
                            punctuationFinal: SpeechBoundary.detectsPunctuationFinal(in: text)
                        )
                    )
                )
            ]
        }

        return runs.enumerated().compactMap { index, run -> SpeechRecognitionEvent? in
            let text = run.words
                .map(\.displayText)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let isLastRun = index == runs.count - 1
            return event(
                isFinal: isFinal,
                payload: SpeechUtterancePayload(
                    providerID: providerID,
                    providerResultID: response.metadata?.requestID,
                    providerUtteranceID: activeUtteranceID(providerID: providerID, words: run.words, responseStart: response.start),
                    speaker: speaker(for: run.speaker),
                    startTimeSeconds: run.words.first?.start,
                    endTimeSeconds: run.words.last?.end,
                    text: text,
                    language: response.metadata?.detectedLanguage,
                    confidence: alternative.confidence,
                    boundary: SpeechBoundary(
                        speechFinal: response.speechFinal == true && isLastRun,
                        punctuationFinal: SpeechBoundary.detectsPunctuationFinal(in: text)
                    )
                )
            )
        }
    }

    private static func event(isFinal: Bool, payload: SpeechUtterancePayload) -> SpeechRecognitionEvent {
        isFinal ? .final(payload) : .hypothesis(payload)
    }

    private static func activeUtteranceID(
        providerID: String,
        words: [DeepgramStreamingResponse.Word],
        responseStart: Double?
    ) -> String {
        if let start = words.first?.start ?? responseStart {
            return "\(providerID)-stream-\(start)"
        }
        return "\(providerID)-stream-active"
    }

    private static func speakerRuns(from words: [DeepgramStreamingResponse.Word]) -> [SpeakerRun] {
        var runs: [SpeakerRun] = []
        for word in words where !word.displayText.isEmpty {
            if let lastIndex = runs.indices.last, runs[lastIndex].speaker == word.speaker {
                runs[lastIndex].words.append(word)
            } else {
                runs.append(SpeakerRun(speaker: word.speaker, words: [word]))
            }
        }
        return runs
    }

    private static func speaker(for deepgramSpeaker: Int?) -> TranscriptSpeaker? {
        guard let deepgramSpeaker else { return nil }
        return TranscriptSpeaker(identifier: "deepgram-speaker-\(deepgramSpeaker)")
    }

    private struct SpeakerRun {
        let speaker: Int?
        var words: [DeepgramStreamingResponse.Word]
    }
}
