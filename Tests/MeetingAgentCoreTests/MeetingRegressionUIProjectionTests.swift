import XCTest
@testable import MeetingAgentCore

final class MeetingRegressionUIProjectionTests: XCTestCase {
    @MainActor
    func testGoldenFixturesMatchExpectedDisplayState() throws {
        for fixtureURL in try RegressionFixtureFiles.allFixtureDirectories() {
            let manifest = try RegressionFixtureFiles.loadManifest(in: fixtureURL)
            guard manifest.purpose == .golden else { continue }
            let expected = try RegressionFixtureFiles.loadExpectedUI(in: fixtureURL)
            let turns = try RegressionFixtureFiles.projectStableTranslationTurns(in: fixtureURL, manifest: manifest)

            try assertDisplayMode("both", expected: expected, turns: turns, displayMode: .both, fixtureID: manifest.id)
            try assertDisplayMode("translationOnly", expected: expected, turns: turns, displayMode: .translationOnly, fixtureID: manifest.id)
        }
    }

    func testKnownFailureFixturesCarryExpectedUIForPromotion() throws {
        for fixtureURL in try RegressionFixtureFiles.allFixtureDirectories() {
            let manifest = try RegressionFixtureFiles.loadManifest(in: fixtureURL)
            guard manifest.purpose == .knownFailure else { continue }
            let expected = try RegressionFixtureFiles.loadExpectedUI(in: fixtureURL)

            XCTAssertFalse(expected.displayModes["both", default: []].isEmpty, "\(manifest.id) should carry provisional both-mode expected UI")
            XCTAssertFalse(expected.displayModes["translationOnly", default: []].isEmpty, "\(manifest.id) should carry provisional translation-only expected UI")
        }
    }

    private func assertDisplayMode(
        _ key: String,
        expected: RegressionExpectedUI,
        turns: [LiveCaptionTurn],
        displayMode: LiveCaptionDisplayMode,
        fixtureID: String
    ) throws {
        let expectedRows = expected.displayModes[key, default: []]
        XCTAssertEqual(turns.count, expectedRows.count, "\(fixtureID) \(key) turn count")
        for (turn, row) in zip(turns, expectedRows) {
            XCTAssertEqual(turn.sourceSegmentIDs, row.sourceSegmentIDs, "\(fixtureID) \(key) sourceSegmentIDs")
            let state = LiveCaptionDisplayState(turn: turn, secondLanguageEnabled: true, displayMode: displayMode)
            switch state {
            case .translated(let primaryText, let sourceText):
                XCTAssertEqual(primaryText, row.primaryText, "\(fixtureID) \(key) primary")
                XCTAssertEqual(sourceText, row.sourceText, "\(fixtureID) \(key) source")
            case .originalOnly(let text):
                XCTAssertEqual(text, row.primaryText, "\(fixtureID) \(key) originalOnly")
            case .pending(let sourceText):
                XCTFail("\(fixtureID) \(key) unexpectedly pending for \(sourceText)")
            case .failed(let sourceText, let message):
                XCTFail("\(fixtureID) \(key) unexpectedly failed for \(sourceText): \(message)")
            }
        }
    }
}
