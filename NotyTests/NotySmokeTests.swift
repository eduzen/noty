import XCTest
@testable import Noty

final class NotySmokeTests: XCTestCase {
    func testInitialRecordingStateIsIdle() {
        XCTAssertEqual(RecordingState.idle, .idle)
    }
}
