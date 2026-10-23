import XCTest
@testable import Noty

final class AudioTimelineTests: XCTestCase {
    func testOrdersPacketsAndPreservesGapAsSilence() throws {
        var timeline = AudioTimeline(reorderWindow: 1)
        let late = packet(time: 6.0 / 48_000, frames: 2, left: 0.4, right: 0.4)
        let early = packet(time: 0, frames: 2, left: 0.2, right: 0.2)
        XCTAssertTrue(try timeline.append(late).isEmpty)
        XCTAssertTrue(try timeline.append(early).isEmpty)
        let chunks = try timeline.finish()
        let expected: [Float] = [0.2, 0.2, 0.2, 0.2] + Array(repeating: 0, count: 8) + [0.4, 0.4, 0.4, 0.4]
        XCTAssertEqual(flatten(chunks), expected)
        XCTAssertEqual(chunks.first?.presentationTime, 0)
        XCTAssertEqual(chunks.reduce(0) { $0 + $1.frameCount }, 8)
    }

    func testTrimsOverlapDeterministicallyAndMixesAlignedSources() throws {
        var timeline = AudioTimeline(origin: 0, reorderWindow: 1)
        _ = try timeline.append(packet(time: 0, frames: 4, left: 0.2, right: 0.2, source: .system))
        _ = try timeline.append(packet(time: 2.0 / 48_000, frames: 4, left: 0.3, right: -0.3, source: .microphone))
        let chunks = try timeline.finish()
        let samples = flatten(chunks)
        XCTAssertEqual(samples[0], 0.2, accuracy: 0.0001)
        XCTAssertEqual(samples[4], 0.5, accuracy: 0.0001)
        XCTAssertEqual(samples[5], -0.1, accuracy: 0.0001)
        XCTAssertEqual(samples[6], 0.5, accuracy: 0.0001)
        XCTAssertEqual(samples.count, 12)
    }

    func testGapOverQueueLimitFailsInsteadOfRetimingTheTimeline() throws {
        var timeline = AudioTimeline(reorderWindow: 0)
        _ = try timeline.append(packet(time: 1, frames: 2, left: 0.2, right: 0.2))
        XCTAssertThrowsError(try timeline.append(packet(time: 20, frames: 2, left: 0.3, right: 0.3))) { error in
            XCTAssertEqual(error as? AudioPipelineError, .queueOverflow)
        }
    }

    func testExplicitDiscontinuityResetsSourceClockAndKeepsOutputMonotonic() throws {
        var timeline = AudioTimeline(reorderWindow: 0)
        _ = try timeline.append(packet(time: 10, frames: 2, left: 0.2, right: 0.2))
        let reset = try timeline.append(packet(time: 1, frames: 2, left: 0.3, right: 0.3, isDiscontinuity: true))
        XCTAssertEqual(reset.first?.presentationTime ?? 0, 10 + 2.0 / 48_000, accuracy: 0.000_000_001)
        XCTAssertEqual(flatten(reset), [0.3, 0.3, 0.3, 0.3])
    }

    func testConfiguredOriginPreservesLeadingAndTrailingSilence() throws {
        var timeline = AudioTimeline(origin: 0, reorderWindow: 0)
        var chunks = try timeline.append(packet(time: 2.0 / 48_000, frames: 2, left: 0.5, right: 0.5))
        chunks.append(contentsOf: try timeline.finish(through: 6.0 / 48_000))
        XCTAssertEqual(flatten(chunks), [0, 0, 0, 0, 0.5, 0.5, 0.5, 0.5, 0, 0, 0, 0])
    }

    func testOneFrameSourceOffsetIsPreservedOnTheOutputTimeline() throws {
        var timeline = AudioTimeline(origin: 0, reorderWindow: 1)
        _ = try timeline.append(packet(time: 0, frames: 3, left: 0.1, right: 0.1, source: .system))
        _ = try timeline.append(packet(time: 1.0 / 48_000, frames: 2, left: 0.2, right: 0.2, source: .microphone))
        let samples = flatten(try timeline.finish())
        XCTAssertEqual(samples[0], 0.1, accuracy: 0.0001)
        XCTAssertEqual(samples[2], 0.3, accuracy: 0.0001)
        XCTAssertEqual(samples[4], 0.3, accuracy: 0.0001)
        XCTAssertEqual(samples.count, 6)
    }

    private func packet(time: Double, frames: Int, left: Float, right: Float, source: AudioSource = .system, isDiscontinuity: Bool = false) -> NormalizedAudioPacket {
        NormalizedAudioPacket(source: source, presentationTime: time, frameCount: frames,
                              samples: Array(repeating: [left, right], count: frames).flatMap { $0 }, isDiscontinuity: isDiscontinuity)
    }

    private func flatten(_ chunks: [MixedAudioChunk]) -> [Float] { chunks.flatMap(\.samples) }
}
