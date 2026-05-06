import XCTest

final class TranslationBackfillBoundaryTests: XCTestCase {
    func testLiveCaptionSourcesDoNotExposeLegacyTranslationSchedulerNames() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MeetingAgentCore")
        let sourceFiles = try FileManager.default
            .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }

        let combinedSource = try sourceFiles
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")

        XCTAssertFalse(combinedSource.contains("schedulePendingTranslations"))
        XCTAssertFalse(combinedSource.contains("CaptionTranslationScheduler"))
        XCTAssertFalse(combinedSource.contains("CaptionTranslationPlanner"))
        XCTAssertTrue(combinedSource.contains("ReplayTranslationBackfillScheduler"))
    }
}
