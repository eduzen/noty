@testable import Noty
import XCTest

final class RecordingPauseGateTests: XCTestCase {
    func testKeepsEverythingWithoutAPause() {
        let gate = RecordingPauseGate()

        XCTAssertEqual(gate.disposition(for: 0), .keep(shift: 0))
        XCTAssertEqual(gate.disposition(for: 100), .keep(shift: 0))
    }

    func testDropsAudioFromThePauseStartOnward() {
        let gate = RecordingPauseGate()
        gate.pause(at: 2)

        XCTAssertEqual(gate.disposition(for: 1.9), .keep(shift: 0))
        XCTAssertEqual(gate.disposition(for: 2), .drop)
        XCTAssertEqual(gate.disposition(for: 5), .drop)
    }

    func testShiftsAudioAfterResumeAndDropsLateAudioCapturedDuringThePause() {
        let gate = RecordingPauseGate()
        gate.pause(at: 2)
        gate.resume(at: 5)

        XCTAssertEqual(gate.disposition(for: 1.99), .keep(shift: 0))
        XCTAssertEqual(gate.disposition(for: 2), .drop)
        XCTAssertEqual(gate.disposition(for: 4.9), .drop)
        XCTAssertEqual(gate.disposition(for: 5), .keep(shift: 3))
        XCTAssertEqual(gate.disposition(for: 6), .keep(shift: 3))
    }

    func testAccumulatesShiftAcrossSeveralPauses() {
        let gate = RecordingPauseGate()
        gate.pause(at: 2)
        gate.resume(at: 3)
        gate.pause(at: 5)
        gate.resume(at: 6)

        XCTAssertEqual(gate.disposition(for: 4), .keep(shift: 1))
        XCTAssertEqual(gate.disposition(for: 5.5), .drop)
        XCTAssertEqual(gate.disposition(for: 7), .keep(shift: 2))
    }

    func testRepeatedPauseAndResumeCallsAreIgnored() {
        let gate = RecordingPauseGate()
        gate.pause(at: 2)
        gate.pause(at: 3)
        gate.resume(at: 4)
        gate.resume(at: 6)

        XCTAssertEqual(gate.disposition(for: 2.5), .drop)
        XCTAssertEqual(gate.disposition(for: 4.5), .keep(shift: 2))
    }

    func testShiftedPacketsKeepTheirSamplesAndMoveEarlier() {
        let packet = CapturedAudioPacket(
            source: .system, presentationTime: 7, sampleRate: 48000,
            channelCount: 2, frameCount: 2, samples: [0.1, 0.2, 0.3, 0.4]
        )

        let shifted = packet.shifted(by: 3)

        XCTAssertEqual(shifted.presentationTime, 4)
        XCTAssertEqual(shifted.samples, packet.samples)
        XCTAssertEqual(shifted.frameCount, packet.frameCount)
    }
}
