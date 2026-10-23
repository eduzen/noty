@testable import Noty
import XCTest

final class MenuBarViewTests: XCTestCase {
    func testStatusItemAccessibleLabelTracksEveryRecordingState() {
        let labels: [(RecordingState, String)] = [
            (.idle, "Noty is idle"),
            (.starting, "Noty is starting a recording"),
            (.recording, "Noty is recording, elapsed time 01:05"),
            (.stopping, "Noty is finalizing the recording"),
            (.interrupted, "Noty recording was interrupted"),
            (.failed, "Noty recording failed")
        ]

        for (state, expected) in labels {
            XCTAssertEqual(RecordingStatusView.accessibleLabel(for: state, elapsedDuration: 65), expected)
        }
    }

    func testElapsedTimeFormattingHandlesHoursAndNegativeInput() {
        XCTAssertEqual(RecordingStatusView.formatDuration(3661), "1:01:01")
        XCTAssertEqual(RecordingStatusView.formatDuration(9), "00:09")
        XCTAssertEqual(RecordingStatusView.formatDuration(-2), "00:00")
    }
}
