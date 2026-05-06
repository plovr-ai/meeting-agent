import XCTest

final class MeetingRegressionFixtureAnalyzerTests: XCTestCase {
    func testRegressionFixturesMatchAnalyzerExpectations() throws {
        for fixtureURL in try RegressionFixtureFiles.allFixtureDirectories() {
            let manifest = try RegressionFixtureFiles.loadManifest(in: fixtureURL)
            let result = try RegressionFixtureFiles.runAnalyzer(fixtureURL)

            switch manifest.expectedAnalyzerStatus {
            case .pass:
                XCTAssertEqual(result.status, 0, "\(manifest.id) analyzer output:\n\(result.stdout)\n\(result.stderr)")
            case .fail:
                XCTAssertNotEqual(result.status, 0, "\(manifest.id) should remain known-failure until promoted")
                for failure in manifest.expectedFailures {
                    XCTAssertTrue(
                        result.stdout.contains(failure) || result.stderr.contains(failure),
                        "\(manifest.id) missing expected failure \(failure)\nstdout:\n\(result.stdout)\nstderr:\n\(result.stderr)"
                    )
                }
            }
        }
    }
}
