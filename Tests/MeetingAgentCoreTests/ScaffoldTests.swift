import XCTest

final class ScaffoldTests: XCTestCase {
    func testScaffoldLoads() {
        XCTAssertTrue(true)
    }

    func testPackageManifestDoesNotExposeCoreAudioTapProbe() throws {
        let manifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Package.swift")
        let manifest = try String(contentsOf: manifestURL)

        XCTAssertFalse(manifest.contains("CoreAudioTapProbe"))
    }
}
