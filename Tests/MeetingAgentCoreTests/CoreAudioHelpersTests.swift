import XCTest
@testable import MeetingAgentCore

final class CoreAudioHelpersTests: XCTestCase {
    func testBundleMatcherIncludesMainBundleAndHelpers() {
        XCTAssertTrue(CoreAudioHelpers.bundleID("com.google.Chrome", matchesCaptureBundleID: "com.google.Chrome"))
        XCTAssertTrue(CoreAudioHelpers.bundleID("com.google.Chrome.helper", matchesCaptureBundleID: "com.google.Chrome"))
        XCTAssertTrue(CoreAudioHelpers.bundleID("com.electron.lark.helper", matchesCaptureBundleID: "com.electron.lark"))
    }

    func testBundleMatcherRejectsUnrelatedBundles() {
        XCTAssertFalse(CoreAudioHelpers.bundleID("com.apple.Safari", matchesCaptureBundleID: "com.google.Chrome"))
        XCTAssertFalse(CoreAudioHelpers.bundleID("com.google.ChromeCanary", matchesCaptureBundleID: "com.google.Chrome"))
    }
}
