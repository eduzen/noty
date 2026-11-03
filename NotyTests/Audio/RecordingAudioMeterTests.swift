@testable import Noty
import XCTest

final class RecordingAudioMeterTests: XCTestCase {
    func testObserveTracksPeakAndSampleDecays() {
        let meter = RecordingAudioMeter()
        meter.observe(samples: [0, 0.25, -0.5, 0.1])
        let first = meter.sampleAndDecay()
        XCTAssertEqual(first, 0.5, accuracy: 0.0001)
        let second = meter.sampleAndDecay()
        XCTAssertLessThan(second, first)
        XCTAssertGreaterThan(second, 0)
    }

    func testResetClearsHeldPeak() {
        let meter = RecordingAudioMeter()
        meter.observe(samples: [0.8])
        meter.reset()
        XCTAssertEqual(meter.sampleAndDecay(), 0)
    }

    func testQuietSamplesStillLeaveRoomForUIShimmerFloor() {
        let height = RecordingWaveformView.barHeight(for: 0, at: Date(timeIntervalSinceReferenceDate: 0))
        XCTAssertGreaterThan(height, 0.04)
        XCTAssertLessThan(height, 0.2)
    }

    func testLouderLevelsGrowBarHeight() {
        let quiet = RecordingWaveformView.barHeight(for: 0.05, at: .distantPast)
        let loud = RecordingWaveformView.barHeight(for: 0.8, at: .distantPast)
        XCTAssertGreaterThan(loud, quiet)
        XCTAssertLessThanOrEqual(loud, 1)
    }
}
