import Foundation

public struct CaptionReducer {
    public private(set) var document: CaptionDocument

    private var finalizedUtteranceKeys = Set<String>()
    private var utteranceLocations: [String: Location] = [:]
    private var sectionContinuationPrefixesByUtteranceKey: [String: String] = [:]
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
        if let location = openDraftReplacementLocation(in: turnIndex, for: payload) {
            updateSection(at: location, with: payload, state: .draft)
            utteranceLocations[key] = location
            return
        }
        if let location = continuationLocation(in: turnIndex, for: payload) {
            startSectionContinuation(at: location, for: payload, key: key, state: .draft)
            utteranceLocations[key] = location
            return
        }

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
            if sectionContinuationPrefixesByUtteranceKey[key] != nil {
                updateSection(at: location, with: payload, state: .final)
                finalizedUtteranceKeys.insert(key)
                if payload.boundary.endsTurn {
                    sectionClosedByTurnID[document.turns[location.turnIndex].id] = true
                }
                return
            }
            if shouldMergeFinalWithoutReplacingVisibleDraft(payload, at: location) {
                mergeCoveredFinal(payload, intoSectionAt: location)
                finalizedUtteranceKeys.insert(key)
                if payload.boundary.endsTurn {
                    sectionClosedByTurnID[document.turns[location.turnIndex].id] = true
                    document.turns[location.turnIndex].state = .final
                }
                return
            }
            updateSection(at: location, with: payload, state: .final)
            finalizedUtteranceKeys.insert(key)
            if payload.boundary.endsTurn {
                sectionClosedByTurnID[document.turns[location.turnIndex].id] = true
            }
            return
        }

        let turnIndex = targetTurnIndex(for: payload, state: .final)
        if let location = openDraftCoveredFinalLocation(in: turnIndex, for: payload) {
            mergeCoveredFinal(payload, intoSectionAt: location)
            utteranceLocations[key] = location
            finalizedUtteranceKeys.insert(key)
            if payload.boundary.endsTurn {
                sectionClosedByTurnID[document.turns[location.turnIndex].id] = true
                document.turns[location.turnIndex].state = .final
            }
            return
        }

        if let location = continuationLocation(in: turnIndex, for: payload) {
            startSectionContinuation(at: location, for: payload, key: key, state: .final)
            utteranceLocations[key] = location
            finalizedUtteranceKeys.insert(key)
            document.turns[turnIndex].state = .final
            sectionClosedByTurnID[document.turns[turnIndex].id] = payload.boundary.endsTurn
            return
        }

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

    private func openDraftReplacementLocation(in turnIndex: Int, for payload: SpeechUtterancePayload) -> Location? {
        guard document.turns.indices.contains(turnIndex),
              let sectionIndex = document.turns[turnIndex].sections.indices.last,
              sectionClosedByTurnID[document.turns[turnIndex].id] != true
        else {
            return nil
        }
        let section = document.turns[turnIndex].sections[sectionIndex]
        guard !sectionIsFullyFinalized(section, providerID: payload.providerID) else {
            return nil
        }
        guard shouldReplaceOpenDraftSection(section, with: payload) else {
            return nil
        }
        return Location(turnIndex: turnIndex, sectionIndex: sectionIndex)
    }

    private func continuationLocation(in turnIndex: Int, for payload: SpeechUtterancePayload) -> Location? {
        guard !payload.boundary.endsTurn,
              document.turns.indices.contains(turnIndex),
              let sectionIndex = document.turns[turnIndex].sections.indices.last,
              sectionClosedByTurnID[document.turns[turnIndex].id] != true
        else {
            return nil
        }
        let section = document.turns[turnIndex].sections[sectionIndex]
        guard sectionIsFullyFinalized(section, providerID: payload.providerID),
              timingsAreNear(section, payload: payload)
        else {
            return nil
        }
        return Location(turnIndex: turnIndex, sectionIndex: sectionIndex)
    }

    private func openDraftCoveredFinalLocation(in turnIndex: Int, for payload: SpeechUtterancePayload) -> Location? {
        guard document.turns.indices.contains(turnIndex),
              let sectionIndex = document.turns[turnIndex].sections.indices.last,
              sectionClosedByTurnID[document.turns[turnIndex].id] != true
        else {
            return nil
        }
        let section = document.turns[turnIndex].sections[sectionIndex]
        guard !sectionIsFullyFinalized(section, providerID: payload.providerID),
              finalPayloadIsCoveredByOpenDraft(payload, section: section)
        else {
            return nil
        }
        return Location(turnIndex: turnIndex, sectionIndex: sectionIndex)
    }

    private func sectionIsFullyFinalized(_ section: CaptionSection, providerID: String) -> Bool {
        !section.utteranceIDs.isEmpty
            && section.utteranceIDs.allSatisfy { finalizedUtteranceKeys.contains("\(providerID):utterance:\($0)") }
    }

    private func finalPayloadIsCoveredByOpenDraft(_ payload: SpeechUtterancePayload, section: CaptionSection) -> Bool {
        return timingsAreNear(section, payload: payload) || payload.startTimeSeconds == nil || section.startTimeSeconds == nil
    }

    private func shouldReplaceOpenDraftSection(_ section: CaptionSection, with payload: SpeechUtterancePayload) -> Bool {
        return timingsAreNear(section, payload: payload)
    }

    private func shouldMergeFinalWithoutReplacingVisibleDraft(
        _ payload: SpeechUtterancePayload,
        at location: Location
    ) -> Bool {
        guard document.turns.indices.contains(location.turnIndex),
              document.turns[location.turnIndex].state == .draft,
              document.turns[location.turnIndex].sections.indices.contains(location.sectionIndex)
        else {
            return false
        }
        let section = document.turns[location.turnIndex].sections[location.sectionIndex]
        guard section.utteranceIDs.count > 1,
              !sectionIsFullyFinalized(section, providerID: payload.providerID)
        else {
            return false
        }
        return timingsAreNear(section, payload: payload) || payload.startTimeSeconds == nil || section.startTimeSeconds == nil
    }

    private func timingsAreNear(_ section: CaptionSection, payload: SpeechUtterancePayload) -> Bool {
        guard let sectionStart = section.startTimeSeconds,
              let sectionEnd = section.endTimeSeconds,
              let payloadStart = payload.startTimeSeconds,
              let payloadEnd = payload.endTimeSeconds
        else {
            return false
        }
        guard payloadEnd >= sectionStart else { return false }
        let tolerance = 2.0
        return payloadStart <= sectionEnd + tolerance
    }

    private mutating func updateSection(at location: Location, with payload: SpeechUtterancePayload, state: CaptionTurnState) {
        guard document.turns.indices.contains(location.turnIndex),
              document.turns[location.turnIndex].sections.indices.contains(location.sectionIndex) else {
            return
        }
        let key = utteranceKey(for: payload)
        if let prefix = sectionContinuationPrefixesByUtteranceKey[key] {
            document.turns[location.turnIndex].sections[location.sectionIndex].text = joinedSectionText(prefix, payload.text)
        } else {
            document.turns[location.turnIndex].sections[location.sectionIndex].text = payload.text
        }
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

    private mutating func startSectionContinuation(
        at location: Location,
        for payload: SpeechUtterancePayload,
        key: String,
        state: CaptionTurnState
    ) {
        guard document.turns.indices.contains(location.turnIndex),
              document.turns[location.turnIndex].sections.indices.contains(location.sectionIndex) else {
            return
        }
        sectionContinuationPrefixesByUtteranceKey[key] = document.turns[location.turnIndex].sections[location.sectionIndex].text
        updateSection(at: location, with: payload, state: state)
    }

    private mutating func mergeCoveredFinal(_ payload: SpeechUtterancePayload, intoSectionAt location: Location) {
        guard document.turns.indices.contains(location.turnIndex),
              document.turns[location.turnIndex].sections.indices.contains(location.sectionIndex) else {
            return
        }
        document.turns[location.turnIndex].sections[location.sectionIndex].utteranceIDs = mergedIDs(
            document.turns[location.turnIndex].sections[location.sectionIndex].utteranceIDs,
            payload.providerUtteranceID
        )
        if let payloadEndTimeSeconds = payload.endTimeSeconds {
            if let sectionEndTimeSeconds = document.turns[location.turnIndex].sections[location.sectionIndex].endTimeSeconds {
                document.turns[location.turnIndex].sections[location.sectionIndex].endTimeSeconds = max(
                    sectionEndTimeSeconds,
                    payloadEndTimeSeconds
                )
            } else {
                document.turns[location.turnIndex].sections[location.sectionIndex].endTimeSeconds = payloadEndTimeSeconds
            }
        }
        document.turns[location.turnIndex].source = mergedSource(document.turns[location.turnIndex].source, payload: payload)
        if let payloadEndTimeSeconds = payload.endTimeSeconds {
            if let turnEndTimeSeconds = document.turns[location.turnIndex].endTimeSeconds {
                document.turns[location.turnIndex].endTimeSeconds = max(turnEndTimeSeconds, payloadEndTimeSeconds)
            } else {
                document.turns[location.turnIndex].endTimeSeconds = payloadEndTimeSeconds
            }
        }
        document.turns[location.turnIndex].updatedAt = Date()
        rememberSpeaker(from: payload)
    }

    private mutating func append(_ payload: SpeechUtterancePayload, toSectionAt location: Location) {
        let existingText = document.turns[location.turnIndex].sections[location.sectionIndex].text
        document.turns[location.turnIndex].sections[location.sectionIndex].text = joinedSectionText(existingText, payload.text)
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

    private func joinedSectionText(_ first: String, _ second: String) -> String {
        let first = first.trimmingCharacters(in: .whitespacesAndNewlines)
        let second = second.trimmingCharacters(in: .whitespacesAndNewlines)
        if first.isEmpty { return second }
        if second.isEmpty { return first }
        let overlap = suffixPrefixOverlapCount(first, second)
        if overlap > 0 {
            let remainder = droppingFirstTokens(overlap, from: second)
            if remainder.isEmpty {
                return first
            }
            return joinedSectionText(first, remainder)
        }
        if shouldJoinWithoutSpace(first, second) {
            return "\(first)\(second)"
        }
        return "\(first) \(second)"
    }

    private func suffixPrefixOverlapCount(_ first: String, _ second: String) -> Int {
        let firstTokens = normalizedTokens(first)
        let secondTokens = normalizedTokens(second)
        let maxOverlap = min(firstTokens.count, secondTokens.count)
        guard maxOverlap > 0 else { return 0 }
        for candidate in stride(from: maxOverlap, through: 1, by: -1) {
            if Array(firstTokens.suffix(candidate)) == Array(secondTokens.prefix(candidate)) {
                return candidate
            }
        }
        return 0
    }

    private func normalizedTokens(_ text: String) -> [String] {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private func droppingFirstTokens(_ count: Int, from text: String) -> String {
        guard count > 0 else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        var remaining = count
        var index = text.startIndex
        var insideToken = false
        while index < text.endIndex {
            let scalar = text[index].unicodeScalars.first
            let isToken = scalar.map { CharacterSet.alphanumerics.contains($0) } ?? false
            if isToken {
                insideToken = true
            } else if insideToken {
                remaining -= 1
                insideToken = false
                if remaining == 0 {
                    return trimmingLeadingBoundary(from: String(text[index...]))
                }
            }
            index = text.index(after: index)
        }
        if remaining <= 1, insideToken {
            return ""
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func trimmingLeadingBoundary(from text: String) -> String {
        let boundary = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.;:!?"))
        var start = text.startIndex
        while start < text.endIndex {
            let scalar = text[start].unicodeScalars.first
            guard scalar.map({ boundary.contains($0) }) == true else { break }
            start = text.index(after: start)
        }
        return String(text[start...])
    }

    private func shouldJoinWithoutSpace(_ first: String, _ second: String) -> Bool {
        guard let lhs = first.last?.unicodeScalars.first,
              let rhs = second.first?.unicodeScalars.first
        else {
            return false
        }
        return isCJK(lhs) && isCJK(rhs)
    }

    private func isCJK(_ scalar: UnicodeScalar) -> Bool {
        let value = Int(scalar.value)
        return (0x4E00...0x9FFF).contains(value)
            || (0x3040...0x30FF).contains(value)
            || (0xAC00...0xD7AF).contains(value)
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
