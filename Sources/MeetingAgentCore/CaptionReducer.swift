import Foundation

public struct CaptionReducer {
    public private(set) var document: CaptionDocument

    private var finalizedUtteranceKeys = Set<String>()
    private var utteranceLocations: [String: Location] = [:]
    private var sectionClosedByTurnID: [String: Bool] = [:]
    private var nextTurnIndex = 0
    private var nextSectionIndex = 0

    public init(document: CaptionDocument = CaptionDocument(), provider: CaptionProviderInfo? = nil) {
        self.document = CaptionDocument(
            version: document.version,
            speakers: document.speakers,
            turns: document.turns,
            provider: provider ?? document.provider,
            createdAt: document.createdAt,
            updatedAt: document.updatedAt,
            finalizedAt: document.finalizedAt
        )
    }

    @discardableResult
    public mutating func apply(_ event: SpeechRecognitionEvent) -> CaptionDocument {
        switch event {
        case .hypothesis(let payload):
            applyHypothesis(payload)
        case .final(let payload):
            applyFinal(payload)
        case .providerStatus:
            break
        }
        return document
    }

    private mutating func applyHypothesis(_ payload: SpeechUtterancePayload) {
        guard !payload.text.isEmpty else { return }
        let key = utteranceKey(for: payload)
        guard !finalizedUtteranceKeys.contains(key) else { return }

        if let location = utteranceLocations[key], document.turns.indices.contains(location.turnIndex) {
            updateSection(at: location, with: payload, state: .draft)
            return
        }

        let turnIndex = targetTurnIndex(for: payload, state: .draft)
        let section = makeSection(for: payload)
        document.turns[turnIndex].sections.append(section)
        document.turns[turnIndex].state = .draft
        document.turns[turnIndex].source = mergedSource(document.turns[turnIndex].source, payload: payload)
        document.turns[turnIndex].endTimeSeconds = payload.endTimeSeconds
        document.turns[turnIndex].updatedAt = Date()
        utteranceLocations[key] = Location(turnIndex: turnIndex, sectionIndex: document.turns[turnIndex].sections.count - 1)
        rememberSpeaker(from: payload)
    }

    private mutating func applyFinal(_ payload: SpeechUtterancePayload) {
        guard !payload.text.isEmpty else { return }
        let key = utteranceKey(for: payload)
        guard !finalizedUtteranceKeys.contains(key) else { return }

        if let location = utteranceLocations[key], document.turns.indices.contains(location.turnIndex) {
            updateSection(at: location, with: payload, state: .final)
            finalizedUtteranceKeys.insert(key)
            if payload.boundary.endsTurn {
                sectionClosedByTurnID[document.turns[location.turnIndex].id] = true
            }
            return
        }

        let turnIndex = targetTurnIndex(for: payload, state: .final)
        if shouldAppendToExistingSection(turnIndex: turnIndex, payload: payload),
           let sectionIndex = document.turns[turnIndex].sections.indices.last {
            append(payload, toSectionAt: Location(turnIndex: turnIndex, sectionIndex: sectionIndex))
            utteranceLocations[key] = Location(turnIndex: turnIndex, sectionIndex: sectionIndex)
        } else {
            let section = makeSection(for: payload)
            document.turns[turnIndex].sections.append(section)
            utteranceLocations[key] = Location(turnIndex: turnIndex, sectionIndex: document.turns[turnIndex].sections.count - 1)
        }

        document.turns[turnIndex].state = .final
        document.turns[turnIndex].source = mergedSource(document.turns[turnIndex].source, payload: payload)
        document.turns[turnIndex].endTimeSeconds = payload.endTimeSeconds
        document.turns[turnIndex].updatedAt = Date()
        finalizedUtteranceKeys.insert(key)
        sectionClosedByTurnID[document.turns[turnIndex].id] = payload.boundary.endsTurn
        rememberSpeaker(from: payload)
    }

    private mutating func targetTurnIndex(for payload: SpeechUtterancePayload, state: CaptionTurnState) -> Int {
        if let lastIndex = document.turns.indices.last,
           sameSpeaker(document.turns[lastIndex], payload: payload) {
            return lastIndex
        }

        let turn = CaptionTurn(
            id: nextTurnID(),
            speakerID: payload.speaker?.identifier,
            speakerLabel: payload.speaker?.label,
            startTimeSeconds: payload.startTimeSeconds,
            endTimeSeconds: payload.endTimeSeconds,
            sections: [],
            state: state,
            source: CaptionTurnSource(
                providerID: payload.providerID,
                resultIDs: payload.providerResultID.map { [$0] } ?? [],
                utteranceIDs: payload.providerUtteranceID.map { [$0] } ?? []
            ),
            createdAt: Date(),
            updatedAt: Date()
        )
        document.turns.append(turn)
        sectionClosedByTurnID[turn.id] = false
        return document.turns.count - 1
    }

    private func sameSpeaker(_ turn: CaptionTurn, payload: SpeechUtterancePayload) -> Bool {
        turn.speakerID == payload.speaker?.identifier && turn.speakerLabel == payload.speaker?.label
    }

    private func shouldAppendToExistingSection(turnIndex: Int, payload: SpeechUtterancePayload) -> Bool {
        guard document.turns.indices.contains(turnIndex),
              !document.turns[turnIndex].sections.isEmpty else {
            return false
        }
        return sectionClosedByTurnID[document.turns[turnIndex].id] != true
    }

    private mutating func updateSection(at location: Location, with payload: SpeechUtterancePayload, state: CaptionTurnState) {
        guard document.turns.indices.contains(location.turnIndex),
              document.turns[location.turnIndex].sections.indices.contains(location.sectionIndex) else {
            return
        }
        document.turns[location.turnIndex].sections[location.sectionIndex].text = payload.text
        document.turns[location.turnIndex].sections[location.sectionIndex].utteranceIDs = mergedIDs(
            document.turns[location.turnIndex].sections[location.sectionIndex].utteranceIDs,
            payload.providerUtteranceID
        )
        document.turns[location.turnIndex].sections[location.sectionIndex].endTimeSeconds = payload.endTimeSeconds
        document.turns[location.turnIndex].state = state
        document.turns[location.turnIndex].source = mergedSource(document.turns[location.turnIndex].source, payload: payload)
        document.turns[location.turnIndex].endTimeSeconds = payload.endTimeSeconds
        document.turns[location.turnIndex].updatedAt = Date()
        rememberSpeaker(from: payload)
    }

    private mutating func append(_ payload: SpeechUtterancePayload, toSectionAt location: Location) {
        let existingText = document.turns[location.turnIndex].sections[location.sectionIndex].text
        document.turns[location.turnIndex].sections[location.sectionIndex].text = [existingText, payload.text]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        document.turns[location.turnIndex].sections[location.sectionIndex].utteranceIDs = mergedIDs(
            document.turns[location.turnIndex].sections[location.sectionIndex].utteranceIDs,
            payload.providerUtteranceID
        )
        document.turns[location.turnIndex].sections[location.sectionIndex].endTimeSeconds = payload.endTimeSeconds
    }

    private mutating func makeSection(for payload: SpeechUtterancePayload) -> CaptionSection {
        CaptionSection(
            id: nextSectionID(),
            text: payload.text,
            utteranceIDs: payload.providerUtteranceID.map { [$0] } ?? [],
            startTimeSeconds: payload.startTimeSeconds,
            endTimeSeconds: payload.endTimeSeconds
        )
    }

    private func mergedSource(_ source: CaptionTurnSource, payload: SpeechUtterancePayload) -> CaptionTurnSource {
        CaptionTurnSource(
            providerID: source.providerID.isEmpty ? payload.providerID : source.providerID,
            streamID: source.streamID,
            resultIDs: mergedIDs(source.resultIDs, payload.providerResultID),
            utteranceIDs: mergedIDs(source.utteranceIDs, payload.providerUtteranceID)
        )
    }

    private func mergedIDs(_ existing: [String], _ newValue: String?) -> [String] {
        Array(Set(existing + (newValue.map { [$0] } ?? []))).sorted()
    }

    private func utteranceKey(for payload: SpeechUtterancePayload) -> String {
        if let providerUtteranceID = payload.providerUtteranceID {
            return "\(payload.providerID):utterance:\(providerUtteranceID)"
        }
        let start = payload.fallbackKey.startTimeSeconds.map { String($0) } ?? "no-start"
        return "\(payload.fallbackKey.providerID):fallback:\(payload.fallbackKey.speakerID ?? "unknown"):\(start)"
    }

    private mutating func rememberSpeaker(from payload: SpeechUtterancePayload) {
        guard let speaker = payload.speaker, let speakerID = speaker.identifier else { return }
        guard !document.speakers.contains(where: { $0.id == speakerID }) else { return }
        document.speakers.append(
            CaptionSpeaker(
                id: speakerID,
                label: speaker.label,
                providerSpeakerID: speakerID
            )
        )
    }

    private mutating func nextTurnID() -> String {
        nextTurnIndex += 1
        return "turn-\(nextTurnIndex)"
    }

    private mutating func nextSectionID() -> String {
        nextSectionIndex += 1
        return "section-\(nextSectionIndex)"
    }

    private struct Location {
        let turnIndex: Int
        let sectionIndex: Int
    }
}
