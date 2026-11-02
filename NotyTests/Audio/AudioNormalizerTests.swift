@testable import Noty
import XCTest

final class AudioNormalizerTests: XCTestCase {
    func testContinuous44100ConstantSurvives4096AndIrregularCallbacks() throws {
        let samples = [Float](repeating: 0.25, count: 20123)
        let reference = try normalize(samples, chunks: [samples.count])
        for chunks in [[4096], [1, 17, 511, 4096, 3, 887, 1024]] {
            let packets = try normalize(samples, chunks: chunks)
            assertContinuous(packets, anchor: 12.5, inputFrames: samples.count, rate: 44100)
            assertSamplesEqual(packets, reference)
            let output = flatten(packets)
            // The real stream's outer edges may ring; callback boundaries must never introduce zeros.
            for sample in output.dropFirst(256).dropLast(256) {
                XCTAssertEqual(sample, 0.25, accuracy: 0.0001)
            }
        }
    }

    func testContinuous44100SineMatchesUnsplitConversion() throws {
        let samples = (0 ..< 22051).map { Float(0.4 * sin(Double($0) * 2 * .pi * 997 / 44100)) }
        let reference = try normalize(samples, chunks: [samples.count])
        for chunks in [[4096], [7, 29, 4093, 2, 503, 1021]] {
            let packets = try normalize(samples, chunks: chunks)
            assertContinuous(packets, anchor: 12.5, inputFrames: samples.count, rate: 44100)
            assertSamplesEqual(packets, reference)
            for packet in packets {
                XCTAssertEqual(packet.source, .microphone)
                XCTAssertEqual(packet.sampleRate, 48000)
                XCTAssertEqual(packet.channelCount, 2)
                for frame in 0 ..< packet.frameCount {
                    XCTAssertEqual(packet.samples[frame * 2], packet.samples[frame * 2 + 1])
                }
            }
        }
    }

    func testQuantizedAndJitteredHostTimestampsKeepContinuousFilterHistory() throws {
        let samples = (0 ..< 22051).map { Float(0.4 * sin(Double($0) * 2 * .pi * 997 / 44100)) }
        let normalizer = AudioNormalizer()
        let chunks = [4096, 127, 17, 503, 1]
        let jitter = [-0.000004, 0.000003, -0.000002, 0.000004]
        var output: [NormalizedAudioPacket] = []
        var offset = 0
        var index = 0
        while offset < samples.count {
            let count = min(chunks[index % chunks.count], samples.count - offset)
            let nominalTime = 12.5 + Double(offset) / 44100
            // Ten-microsecond host-clock quantization plus bounded jitter remains below half a 48 kHz frame.
            let time = index == 0 ? 12.5 : (nominalTime / 0.00001).rounded() * 0.00001 + jitter[index % jitter.count]
            try output.append(contentsOf: normalizer.normalize(packet(
                samples: Array(samples[offset ..< (offset + count)]), time: time
            )))
            offset += count
            index += 1
        }
        try output.append(contentsOf: normalizer.finish())
        assertContinuous(output, anchor: 12.5, inputFrames: samples.count, rate: 44100)
        try assertSamplesEqual(output, normalize(samples, chunks: [samples.count]))
    }

    func testSmallClockDriftCannotAccumulateAcrossCallbacks() throws {
        let normalizer = AudioNormalizer()
        var output: [NormalizedAudioPacket] = []
        for index in 0 ..< 12 {
            try output.append(contentsOf: normalizer.normalize(packet(
                samples: .init(repeating: 0.25, count: 480),
                time: Double(index) * (0.01 + 0.000001), rate: 48000
            )))
        }
        // One microsecond per callback is tolerated only until cumulative drift exceeds half an output frame.
        XCTAssertEqual(output[10].presentationTime, 0.1, accuracy: 1e-12)
        XCTAssertEqual(output[11].presentationTime, 0.110011, accuracy: 1e-12)
        XCTAssertTrue(try normalizer.finish().isEmpty)
    }

    func testSourcesRetainIndependentConversionStateAndTiming() throws {
        let normalizer = AudioNormalizer()
        let anchor = 1_000_000.0
        let microphone = (0 ..< 4410).map { Float(sin(Double($0) * 0.04)) }
        let system = (0 ..< 3200).map { Float(cos(Double($0) * 0.06)) }
        var packets: [NormalizedAudioPacket] = []
        var microphoneOffset = 0
        var systemOffset = 0
        for index in 0 ..< 10 {
            let microphoneCount = index.isMultiple(of: 2) ? 439 : 443
            let systemCount = index.isMultiple(of: 2) ? 319 : 321
            let microphoneTime = ((anchor + Double(microphoneOffset) / 44100) * 1_000_000).rounded() / 1_000_000
            let systemTime = ((anchor + 0.0125 + Double(systemOffset) / 32000) * 1_000_000).rounded() / 1_000_000
            try packets.append(contentsOf: normalizer.normalize(packet(
                samples: Array(microphone[microphoneOffset ..< (microphoneOffset + microphoneCount)]),
                time: microphoneTime
            )))
            try packets.append(contentsOf: normalizer.normalize(packet(
                samples: Array(system[systemOffset ..< (systemOffset + systemCount)]),
                source: .system, time: systemTime, rate: 32000
            )))
            microphoneOffset += microphoneCount
            systemOffset += systemCount
        }
        let tails = try normalizer.finish()
        XCTAssertEqual(tails.map(\.presentationTime), tails.map(\.presentationTime).sorted())
        packets += tails
        let microphoneOutput = packets.filter { $0.source == .microphone }
        let systemOutput = packets.filter { $0.source == .system }
        assertContinuous(microphoneOutput, anchor: anchor, inputFrames: microphone.count, rate: 44100)
        assertContinuous(systemOutput, anchor: anchor + 0.0125, inputFrames: system.count, rate: 32000)
        try assertSamplesEqual(microphoneOutput, normalize(microphone, chunks: [4410], anchor: anchor))
        try assertSamplesEqual(systemOutput, normalize(system, chunks: [3200], source: .system,
                                                       anchor: anchor + 0.0125, rate: 32000))
    }

    func testPreservesExact48000StereoAndMonoMapping() throws {
        let normalizer = AudioNormalizer()
        let stereo: [Float] = [0.25, -0.5, 0.1, -0.2, 0, 0.75]
        let output = try XCTUnwrap(normalizer.normalize(packet(
            samples: stereo, source: .system, time: 1, rate: 48000, channels: 2
        )).first)
        XCTAssertEqual(output.samples, stereo)
        XCTAssertEqual(output.frameCount, 3)
        XCTAssertEqual(output.presentationTime, 1)
        let mono = try XCTUnwrap(normalizer.normalize(packet(
            samples: [0.1, -0.2, 0.3], time: 1.5, rate: 48000
        )).first)
        XCTAssertEqual(mono.samples, [0.1, 0.1, -0.2, -0.2, 0.3, 0.3])
        XCTAssertTrue(try normalizer.finish().isEmpty)
    }

    func testWider48000InputUsesFirstTwoChannels() throws {
        let normalizer = AudioNormalizer()
        let output = try XCTUnwrap(normalizer.normalize(packet(
            samples: [0.25, -0.5, 9, 0.1, -0.2, 8], rate: 48000, channels: 3
        )).first)
        XCTAssertEqual(output.samples, [0.25, -0.5, 0.1, -0.2])
        XCTAssertEqual(output.frameCount, 2)
    }

    func testRealGapDrainsOldSegmentAndRemainsSilence() throws {
        let normalizer = AudioNormalizer()
        var packets = try normalizer.normalize(packet(samples: .init(repeating: 0.25, count: 4410)))
        try packets.append(contentsOf: normalizer.normalize(packet(
            samples: .init(repeating: -0.25, count: 4410), time: 0.15
        )))
        try packets.append(contentsOf: normalizer.finish())
        let second = try XCTUnwrap(packets.first { $0.presentationTime >= 0.15 })
        XCTAssertEqual(second.presentationTime, 0.15)
        XCTAssertFalse(packets.contains(where: \.isDiscontinuity))
        var mixer = AudioMixer(origin: 0, reorderWindow: 1)
        var chunks: [MixedAudioChunk] = []
        for packet in packets {
            try chunks.append(contentsOf: mixer.append(packet))
        }
        try chunks.append(contentsOf: mixer.finish())
        let mixed = chunks.flatMap(\.samples)
        XCTAssertEqual(mixed.count / 2, 12000)
        XCTAssertTrue(mixed[(4800 * 2) ..< (7200 * 2)].allSatisfy { $0 == 0 })
        XCTAssertGreaterThan(mixed[2400 * 2], 0)
        XCTAssertLessThan(mixed[9600 * 2], 0)
    }

    func testOverlapAndClockDriftBeyondOutputFrameKeepCaptureTimestamps() throws {
        for secondTime in [0.075, 0.10005] {
            let normalizer = AudioNormalizer()
            _ = try normalizer.normalize(packet(samples: .init(repeating: 0.4, count: 4410)))
            let output = try normalizer.normalize(packet(
                samples: .init(repeating: -0.4, count: 4410), time: secondTime
            ))
            let second = try XCTUnwrap(output.first { abs($0.presentationTime - secondTime) < 1e-10 })
            XCTAssertEqual(second.presentationTime, secondTime)
            XCTAssertFalse(second.isDiscontinuity)
            _ = try normalizer.finish()
        }
    }

    func testDiscontinuityDrainsOnceThenStartsWithoutOldFilterHistory() throws {
        let normalizer = AudioNormalizer()
        let first = try normalizer.normalize(packet(
            samples: .init(repeating: 0.75, count: 4410), time: 10
        ))
        let reset = try normalizer.normalize(packet(
            samples: [0], time: 1, discontinuity: true
        ))
        let oldTail = reset.filter { $0.presentationTime >= 10 }
        XCTAssertFalse(oldTail.isEmpty)
        XCTAssertLessThanOrEqual(abs((first + oldTail).reduce(0) { $0 + $1.frameCount } - 4800), 1)
        var newSegment = reset.filter { $0.presentationTime < 10 }
        try newSegment.append(contentsOf: normalizer.normalize(packet(
            samples: .init(repeating: 0, count: 4409), time: 1 + 1.0 / 44100
        )))
        try newSegment.append(contentsOf: normalizer.finish())
        XCTAssertEqual(newSegment.first?.presentationTime, 1)
        XCTAssertEqual(newSegment.filter(\.isDiscontinuity).count, 1)
        XCTAssertTrue(flatten(newSegment).allSatisfy { $0 == 0 })
        assertContinuous(newSegment, anchor: 1, inputFrames: 4410, rate: 44100)
        XCTAssertTrue(try normalizer.finish().isEmpty)
    }

    func testFormatAndChannelChangesStartFreshSegments() throws {
        for change in [(rate: 32000.0, channels: 1), (rate: 44100.0, channels: 2), (rate: 48000.0, channels: 1)] {
            let normalizer = AudioNormalizer()
            var old = try normalizer.normalize(packet(samples: .init(repeating: 0.75, count: 4410)))
            let count = Int(change.rate / 10)
            let newSamples = [Float](repeating: 0, count: count * change.channels)
            let output = try normalizer.normalize(packet(
                samples: newSamples, time: 0.1, rate: change.rate, channels: change.channels
            ))
            old += output.filter { $0.presentationTime < 0.1 }
            let new = try output.filter { $0.presentationTime >= 0.1 } + (normalizer.finish())
            XCTAssertLessThanOrEqual(abs(old.reduce(0) { $0 + $1.frameCount } - 4800), 1)
            assertContinuous(new, anchor: 0.1, inputFrames: count, rate: change.rate)
            XCTAssertFalse(new.contains(where: \.isDiscontinuity))
            XCTAssertTrue(flatten(new).allSatisfy { $0 == 0 })
        }
    }

    func testTinyCallbacksDrainTrailingAudioOnlyOnce() throws {
        let normalizer = AudioNormalizer()
        var packets = try normalizer.normalize(packet(samples: [0.5]))
        for index in 1 ..< 441 {
            try packets.append(contentsOf: normalizer.normalize(packet(samples: [0.5], time: Double(index) / 44100)))
        }
        let tail = try normalizer.finish()
        XCTAssertFalse(tail.isEmpty)
        XCTAssertGreaterThan(tail.flatMap(\.samples).map(abs).max() ?? 0, 0.1)
        packets += tail
        assertContinuous(packets, anchor: 0, inputFrames: 441, rate: 44100)
        XCTAssertTrue(try normalizer.finish().isEmpty)
        XCTAssertThrowsError(try normalizer.normalize(packet(samples: [0.5], time: 1))) {
            guard let issue = $0 as? AudioPipelineError, case .conversionFailed = issue else {
                return XCTFail("Expected explicit finalized-stream error; got \($0)")
            }
        }
    }

    func testFinishWithoutInputIsIdempotent() throws {
        let normalizer = AudioNormalizer()
        XCTAssertTrue(try normalizer.finish().isEmpty)
        XCTAssertTrue(try normalizer.finish().isEmpty)
    }

    func testRejectsMalformedPacketsWithTypedErrorsBeforeChangingHistory() throws {
        let normalizer = AudioNormalizer()
        let malformed = [
            packet(samples: [0], time: -1),
            packet(samples: [0], time: .nan),
            packet(samples: [0], time: .infinity),
            packet(samples: [0], rate: 0),
            packet(samples: [0], rate: -.infinity),
            packet(samples: [0], rate: .nan),
            packet(samples: [0], rate: 0.1),
            packet(samples: [], channels: 0, frames: 1),
            packet(samples: .init(repeating: 0, count: 33), channels: 33),
            packet(samples: [], frames: 0),
            packet(samples: [], frames: -1),
            packet(samples: [], frames: Int(UInt32.max) + 1),
            packet(samples: [], channels: 32, frames: Int.max),
            packet(samples: [0, 0], channels: 2, frames: 2),
            packet(samples: [.nan]),
            packet(samples: [.infinity])
        ]
        var output = try normalizer.normalize(packet(samples: .init(repeating: 0.25, count: 441)))
        for malformedPacket in malformed {
            XCTAssertThrowsError(try normalizer.normalize(malformedPacket)) {
                guard let issue = $0 as? AudioPipelineError, case .malformedPacket = issue else {
                    return XCTFail("Expected malformed packet error; got \($0)")
                }
            }
        }
        try output.append(contentsOf: normalizer.normalize(packet(
            samples: .init(repeating: 0.25, count: 441), time: 0.01
        )))
        try output.append(contentsOf: normalizer.finish())
        assertContinuous(output, anchor: 0, inputFrames: 882, rate: 44100)
        try assertSamplesEqual(output, normalize(.init(repeating: 0.25, count: 882), chunks: [882], anchor: 0))
    }

    func testUnsupportedConverterRateHasExplicitTypedError() {
        XCTAssertThrowsError(try AudioNormalizer().normalize(packet(
            samples: [0], rate: .greatestFiniteMagnitude
        ))) {
            guard let issue = $0 as? AudioPipelineError, case .unsupportedFormat = issue else {
                return XCTFail("Expected unsupported format error; got \($0)")
            }
        }
    }

    func testAcceptsMaximumChannelCountWithExplicitMapping() throws {
        let output = try XCTUnwrap(AudioNormalizer().normalize(packet(
            samples: (0 ..< 32).map { Float($0) / 32 }, rate: 48000, channels: 32
        )).first)
        XCTAssertEqual(output.samples, [0, 1.0 / 32])
    }

    private func packet(
        samples: [Float], source: AudioSource = .microphone, time: Double = 0,
        rate: Double = 44100, channels: Int = 1, frames: Int? = nil, discontinuity: Bool = false
    ) -> CapturedAudioPacket {
        CapturedAudioPacket(source: source, presentationTime: time, sampleRate: rate, channelCount: channels,
                            frameCount: frames ?? samples.count / max(1, channels), samples: samples,
                            isDiscontinuity: discontinuity)
    }

    private func normalize(
        _ samples: [Float], chunks: [Int], source: AudioSource = .microphone,
        anchor: Double = 12.5, rate: Double = 44100
    ) throws -> [NormalizedAudioPacket] {
        let normalizer = AudioNormalizer()
        var output: [NormalizedAudioPacket] = []
        var offset = 0
        var index = 0
        while offset < samples.count {
            let count = min(chunks[index % chunks.count], samples.count - offset)
            try output.append(contentsOf: normalizer.normalize(packet(
                samples: Array(samples[offset ..< (offset + count)]), source: source,
                time: anchor + Double(offset) / rate, rate: rate
            )))
            offset += count
            index += 1
        }
        try output.append(contentsOf: normalizer.finish())
        return output
    }

    private func flatten(_ packets: [NormalizedAudioPacket]) -> [Float] {
        packets.flatMap(\.samples)
    }

    private func assertContinuous(
        _ packets: [NormalizedAudioPacket], anchor: Double, inputFrames: Int, rate: Double,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        var emitted = 0
        for packet in packets {
            XCTAssertGreaterThan(packet.frameCount, 0, file: file, line: line)
            XCTAssertEqual(packet.samples.count, packet.frameCount * 2, file: file, line: line)
            XCTAssertEqual(packet.presentationTime, anchor + Double(emitted) / 48000,
                           accuracy: 1e-10, file: file, line: line)
            emitted += packet.frameCount
        }
        XCTAssertLessThanOrEqual(abs(Double(emitted) - Double(inputFrames) * 48000 / rate), 1,
                                 file: file, line: line)
    }

    private func assertSamplesEqual(
        _ actual: [NormalizedAudioPacket], _ expected: [NormalizedAudioPacket],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let actualSamples = flatten(actual)
        let expectedSamples = flatten(expected)
        XCTAssertEqual(actualSamples.count, expectedSamples.count, file: file, line: line)
        let maximumError = zip(actualSamples, expectedSamples).reduce(Float(0)) { max($0, abs($1.0 - $1.1)) }
        XCTAssertLessThanOrEqual(maximumError, 0.00002, file: file, line: line)
    }
}
