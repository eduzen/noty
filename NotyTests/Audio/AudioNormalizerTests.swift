import XCTest
@testable import Noty

final class AudioNormalizerTests: XCTestCase {
    func testConvertsMono44100ToStereo48000() throws {
        let frames = 4_410
        let input = (0..<frames).map { Float(sin(Double($0) * 0.04)) }
        let normalized = try AudioNormalizer().normalize(CapturedAudioPacket(
            source: .microphone, presentationTime: 12.5, sampleRate: 44_100,
            channelCount: 1, frameCount: frames, samples: input
        ))

        XCTAssertEqual(normalized.source, .microphone)
        XCTAssertEqual(normalized.presentationTime, 12.5)
        XCTAssertEqual(normalized.sampleRate, 48_000)
        XCTAssertEqual(normalized.channelCount, 2)
        XCTAssertLessThanOrEqual(abs(normalized.frameCount - 4_800), 2)
        XCTAssertEqual(normalized.samples.count, normalized.frameCount * 2)
        for frame in 0..<normalized.frameCount {
            XCTAssertEqual(normalized.samples[frame * 2], normalized.samples[frame * 2 + 1], accuracy: 0.0001)
        }
        XCTAssertGreaterThan(normalized.samples.map(abs).max() ?? 0, 0.5)
    }

    func testPreservesStereoChannelsAt48000() throws {
        let normalized = try AudioNormalizer().normalize(CapturedAudioPacket(
            source: .system, presentationTime: 1, sampleRate: 48_000,
            channelCount: 2, frameCount: 3, samples: [0.25, -0.5, 0.1, -0.2, 0, 0.75]
        ))
        XCTAssertEqual(normalized.frameCount, 3)
        XCTAssertEqual(normalized.samples[0], 0.25, accuracy: 0.0001)
        XCTAssertEqual(normalized.samples[1], -0.5, accuracy: 0.0001)
        XCTAssertEqual(normalized.samples[2], 0.1, accuracy: 0.0001)
        XCTAssertEqual(normalized.samples[3], -0.2, accuracy: 0.0001)
        XCTAssertEqual(normalized.samples[4], 0, accuracy: 0.0001)
        XCTAssertEqual(normalized.samples[5], 0.75, accuracy: 0.0001)
    }

    func testRejectsMalformedPacketWithTypedError() {
        let packet = CapturedAudioPacket(source: .system, presentationTime: 0, sampleRate: 48_000,
                                         channelCount: 2, frameCount: 2, samples: [0, 0])
        XCTAssertThrowsError(try AudioNormalizer().normalize(packet)) { error in
            guard let issue = error as? AudioPipelineError, case .malformedPacket = issue else {
                return XCTFail("Expected malformed packet error; got \(error)")
            }
        }
    }
}
