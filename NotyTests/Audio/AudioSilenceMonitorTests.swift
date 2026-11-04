import Foundation
@testable import Noty
import XCTest

final class AudioSilenceMonitorTests: XCTestCase {
    func testReportsOnceAfterThresholdOfSilentSystemAudio() {
        var monitor = AudioSilenceMonitor(source: .system)

        XCTAssertFalse(monitor.observe(packet(.system, time: 0, seconds: 2, value: 0)))
        XCTAssertFalse(monitor.observe(packet(.system, time: 2, seconds: 2, value: 0)))
        XCTAssertTrue(monitor.observe(packet(.system, time: 4, seconds: 2, value: 0)))
        XCTAssertFalse(monitor.observe(packet(.system, time: 6, seconds: 2, value: 0)))
    }

    func testAudibleSystemAudioNeverReports() {
        var monitor = AudioSilenceMonitor(source: .system)

        XCTAssertFalse(monitor.observe(packet(.system, time: 0, seconds: 1, value: 0.5)))
        XCTAssertFalse(monitor.observe(packet(.system, time: 1, seconds: 10, value: 0)))
    }

    func testMicrophoneSilenceDoesNotCountAsMissingSystemAudio() {
        var monitor = AudioSilenceMonitor(source: .system)

        XCTAssertFalse(monitor.observe(packet(.microphone, time: 0, seconds: 10, value: 0)))
    }

    func testLowLevelNoiseCountsAsSilence() {
        var monitor = AudioSilenceMonitor(source: .system)

        XCTAssertTrue(monitor.observe(packet(.system, time: 0, seconds: 6, value: 0.00001)))
    }

    func testReportsSilentMicrophoneAndIgnoresSystemAudio() {
        var monitor = AudioSilenceMonitor(source: .microphone)

        XCTAssertFalse(monitor.observe(packet(.system, time: 0, seconds: 10, value: 0)))
        XCTAssertFalse(monitor.observe(packet(.microphone, time: 0, seconds: 3, value: 0)))
        XCTAssertTrue(monitor.observe(packet(.microphone, time: 3, seconds: 3, value: 0)))
    }

    private func packet(_ source: AudioSource, time: TimeInterval, seconds: Double,
                        value: Float) -> CapturedAudioPacket {
        let frames = Int(seconds * 48000)
        return CapturedAudioPacket(
            source: source,
            presentationTime: time,
            sampleRate: 48000,
            channelCount: 2,
            frameCount: frames,
            samples: Array(repeating: value, count: frames * 2)
        )
    }
}
