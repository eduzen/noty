import XCTest
@testable import Noty

final class AudioMixerTests: XCTestCase {
    func testNormalizesAndMixesMonoMicrophoneWithStereoSystemAudio() throws {
        let microphone = try AudioNormalizer().normalize(CapturedAudioPacket(
            source: .microphone, presentationTime: 0, sampleRate: 44_100, channelCount: 1,
            frameCount: 441, samples: Array(repeating: 0.4, count: 441)
        ))
        let system = try AudioNormalizer().normalize(CapturedAudioPacket(
            source: .system, presentationTime: 0, sampleRate: 48_000, channelCount: 2,
            frameCount: 480, samples: Array(repeating: [0.5, -0.5], count: 480).flatMap { $0 }
        ))
        var mixer = AudioMixer(origin: 0, reorderWindow: 1)
        _ = try mixer.append(microphone)
        _ = try mixer.append(system)
        let chunks = try mixer.finish()
        let sample = try XCTUnwrap(chunks.first?.samples)
        XCTAssertLessThanOrEqual(abs(chunks.reduce(0) { $0 + $1.frameCount } - 480), 1)
        XCTAssertGreaterThan(sample[0], 0)
        XCTAssertLessThan(sample[1], 0)
        XCTAssertGreaterThan(sample.max() ?? 0, 0.4)
        XCTAssertLessThanOrEqual(sample.map(abs).max() ?? 0, 0.891251)
    }

    func testLimiterBoundsPeakAndLeavesSilenceSilent() throws {
        var mixer = AudioMixer(origin: 0, reorderWindow: 1)
        _ = try mixer.append(NormalizedAudioPacket(source: .system, presentationTime: 0,
                                                   frameCount: 3, samples: [4, -4, 0, 0, 1, -1]))
        let chunk = try XCTUnwrap(mixer.finish().first)
        XCTAssertLessThanOrEqual(chunk.samples.map(abs).max() ?? 0, 0.891251)
        XCTAssertEqual(Array(chunk.samples[2...3]), [Float(0), 0])
        XCTAssertEqual(chunk.frameCount, 3)
        XCTAssertEqual(chunk.presentationTime, 0)
    }
}
