import XCTest
@testable import MeetingAgentCore

@available(macOS 14.2, *)
final class AudioCaptureSessionTests: XCTestCase {
    func testSessionStartsInactive() {
        let session = AudioCaptureSession()

        XCTAssertFalse(session.isRunning)
    }
}
