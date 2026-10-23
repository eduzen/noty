@testable import Noty
import XCTest

final class NotySmokeTests: XCTestCase {
    func testInitialRecordingStateIsIdle() {
        XCTAssertEqual(RecordingState.idle, .idle)
    }
}
