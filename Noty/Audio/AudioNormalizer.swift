import AVFoundation
import Foundation

/// Session-owned streaming conversion. Each source keeps its own filter history and capture-time anchor.
final class AudioNormalizer {
    private var segments: [AudioSource: Segment] = [:]
    private var isFinished = false

    func normalize(_ packet: CapturedAudioPacket) throws -> [NormalizedAudioPacket] {
        try validate(packet)
        guard !isFinished else {
            throw AudioPipelineError.conversionFailed("Audio normalization has already finished.")
        }

        var result: [NormalizedAudioPacket] = []
        if let previous = segments[packet.source] {
            if previous.isContiguous(with: packet) {
                return try previous.append(packet)
            }
            // #region agent log
            if AgentDebugLog.shouldEmit("normalizer.restart.\(packet.source.rawValue)", interval: 1) {
                AgentDebugLog.log("AudioNormalizer.normalize", "segment restart", hypothesis: "E", [
                    "source": packet.source.rawValue, "pts": packet.presentationTime,
                    "sampleRate": packet.sampleRate, "discontinuity": packet.isDiscontinuity
                ])
            }
            // #endregion
            result = try previous.finish()
            segments.removeValue(forKey: packet.source)
        }
        let segment = try Segment(packet: packet)
        segments[packet.source] = segment
        try result.append(contentsOf: segment.append(packet))
        return result
    }

    /// Sends end-of-stream exactly once, then returns all source tails in capture-time order.
    func finish() throws -> [NormalizedAudioPacket] {
        guard !isFinished else { return [] }
        isFinished = true
        let remaining = segments.values
        segments.removeAll()
        var result: [NormalizedAudioPacket] = []
        for segment in remaining {
            try result.append(contentsOf: segment.finish())
        }
        return result.sorted {
            if $0.presentationTime != $1.presentationTime {
                return $0.presentationTime < $1.presentationTime
            }
            return $0.source.rawValue < $1.source.rawValue
        }
    }

    private func validate(_ packet: CapturedAudioPacket) throws {
        guard packet.presentationTime.isFinite, packet.presentationTime >= 0,
              packet.sampleRate.isFinite, packet.sampleRate > 0,
              (1 ... 32).contains(packet.channelCount), packet.frameCount > 0,
              packet.frameCount <= Int.max / packet.channelCount,
              packet.frameCount <= Int(AVAudioFrameCount.max),
              Double(packet.frameCount) / packet.sampleRate <= 5,
              packet.samples.count <= (64 * 1024 * 1024) / MemoryLayout<Float>.size,
              packet.samples.count == packet.frameCount * packet.channelCount,
              packet.samples.allSatisfy(\.isFinite)
        else {
            throw AudioPipelineError
                .malformedPacket("Audio packet has invalid timing, format, frame count, or samples.")
        }
    }

    private final class Segment {
        private static let bufferFrames: AVAudioFrameCount = 4096
        private static let maximumDrainFrames = 5 * 48000

        private let source: AudioSource
        private let anchor: TimeInterval
        private let sampleRate: Double
        private let channelCount: Int
        private let rightChannelIndex: Int
        private let converter: AVAudioConverter?
        private let input: AVAudioPCMBuffer?
        private let output: AVAudioPCMBuffer?
        private var inputFrames: Int64 = 0
        private var emittedFrames: Int64 = 0
        private var marksDiscontinuity: Bool
        private var isFinished = false

        init(packet: CapturedAudioPacket) throws {
            source = packet.source
            anchor = packet.presentationTime
            sampleRate = packet.sampleRate
            channelCount = packet.channelCount
            rightChannelIndex = packet.channelCount == 1 ? 0 : 1
            marksDiscontinuity = packet.isDiscontinuity
            guard sampleRate != AudioFormat.sampleRate else {
                converter = nil
                input = nil
                output = nil
                return
            }
            guard let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                                   channels: 2, interleaved: false),
                let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioFormat.sampleRate,
                                                 channels: 2, interleaved: false),
                let converter = AVAudioConverter(from: sourceFormat, to: outputFormat),
                let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: Self.bufferFrames),
                let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: Self.bufferFrames),
                input.floatChannelData != nil, output.floatChannelData != nil
            else {
                throw AudioPipelineError.unsupportedFormat("Could not create a supported audio sample-rate converter.")
            }
            // Normal priming reads ahead for the filter, but removes its latency from the output.
            // .none would instead insert that latency at the beginning of every segment.
            converter.primeMethod = .normal
            self.converter = converter
            self.input = input
            self.output = output
        }

        func isContiguous(with packet: CapturedAudioPacket) -> Bool {
            guard !packet.isDiscontinuity, packet.sampleRate == sampleRate, packet.channelCount == channelCount else {
                return false
            }
            let expected = anchor + Double(inputFrames) / sampleRate
            // Host-clock quantization below half an output frame cannot be represented by the timeline.
            // Compare against the original anchor so that small per-callback drift cannot accumulate unseen.
            let tolerance = max(0.5 / AudioFormat.sampleRate, 8 * max(expected.ulp, packet.presentationTime.ulp))
            return abs(packet.presentationTime - expected) <= tolerance
        }

        func append(_ packet: CapturedAudioPacket) throws -> [NormalizedAudioPacket] {
            let total = inputFrames.addingReportingOverflow(Int64(packet.frameCount))
            let outputPosition = Double(total.partialValue) * AudioFormat.sampleRate / sampleRate
            guard !total.overflow, outputPosition.isFinite, outputPosition < Double(Int64.max) - 8192,
                  (anchor + Double(total.partialValue) / sampleRate).isFinite
            else {
                throw AudioPipelineError
                    .timingDiscontinuity("Audio timestamps exceed the supported conversion timeline.")
            }
            inputFrames = total.partialValue
            guard let converter, let input, let output else {
                let samples: [Float]
                if channelCount == 2 {
                    samples = packet.samples
                } else {
                    var mapped = [Float](repeating: 0, count: packet.frameCount * 2)
                    for frame in 0 ..< packet.frameCount {
                        let sourceIndex = frame * channelCount
                        mapped[frame * 2] = packet.samples[sourceIndex]
                        mapped[frame * 2 + 1] = packet.samples[sourceIndex + rightChannelIndex]
                    }
                    samples = mapped
                }
                return [makePacket(samples: samples, frames: packet.frameCount)]
            }

            var offset = 0
            var result: [NormalizedAudioPacket] = []
            while true {
                let previousOffset = offset
                output.frameLength = 0
                var error: NSError?
                let status = converter.convert(to: output, error: &error) { requestedFrames, inputStatus in
                    guard offset < packet.frameCount else {
                        inputStatus.pointee = .noDataNow
                        return nil
                    }
                    let count = min(Int(requestedFrames), Int(input.frameCapacity), packet.frameCount - offset)
                    guard count > 0 else {
                        inputStatus.pointee = .noDataNow
                        return nil
                    }
                    input.frameLength = AVAudioFrameCount(count)
                    let channels = input.floatChannelData!
                    for frame in 0 ..< count {
                        let index = (offset + frame) * self.channelCount
                        channels[0][frame] = packet.samples[index]
                        channels[1][frame] = packet.samples[index + self.rightChannelIndex]
                    }
                    offset += count
                    inputStatus.pointee = .haveData
                    return input
                }
                try checkConversion(status, error: error)
                if output.frameLength > 0 {
                    try result.append(makePacket(from: output, frames: Int(output.frameLength)))
                }
                switch status {
                case .inputRanDry:
                    guard offset == packet.frameCount else {
                        throw AudioPipelineError.conversionFailed("Audio converter did not consume all callback input.")
                    }
                    return result
                case .haveData:
                    guard output.frameLength > 0 || offset > previousOffset else {
                        throw AudioPipelineError.conversionFailed("Audio sample-rate conversion made no progress.")
                    }
                default:
                    throw AudioPipelineError.conversionFailed("Audio converter ended before the source stream.")
                }
            }
        }

        func finish() throws -> [NormalizedAudioPacket] {
            guard !isFinished else { return [] }
            isFinished = true
            guard let converter, let output else { return [] }
            let expectedFrames = Double(inputFrames) * AudioFormat.sampleRate / sampleRate
            let targetFrames = Int64(expectedFrames.rounded())
            var drainedFrames = 0
            var result: [NormalizedAudioPacket] = []
            while true {
                output.frameLength = 0
                var error: NSError?
                let status = converter.convert(to: output, error: &error) { _, inputStatus in
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                try checkConversion(status, error: error)
                drainedFrames += Int(output.frameLength)
                guard drainedFrames <= Self.maximumDrainFrames else {
                    throw AudioPipelineError
                        .conversionFailed("Audio converter exceeded the bounded end-of-stream drain.")
                }
                // Priming can synthesize trailing silence for the filter, not additional recording time.
                let frames = min(Int(output.frameLength), Int(max(0, targetFrames - emittedFrames)))
                if frames > 0 {
                    try result.append(makePacket(from: output, frames: frames))
                }
                if status == .endOfStream {
                    guard abs(Double(emittedFrames) - expectedFrames) <= 1 else {
                        throw AudioPipelineError
                            .conversionFailed("Audio converter did not preserve the source duration.")
                    }
                    return result
                }
                guard status == .haveData, output.frameLength > 0 else {
                    throw AudioPipelineError.conversionFailed("Audio converter did not finish draining the source.")
                }
            }
        }

        private func checkConversion(_ status: AVAudioConverterOutputStatus, error: NSError?) throws {
            guard error == nil, status != .error else {
                throw AudioPipelineError
                    .conversionFailed(error?.localizedDescription ?? "Audio sample-rate conversion failed.")
            }
        }

        private func makePacket(from buffer: AVAudioPCMBuffer, frames: Int) throws -> NormalizedAudioPacket {
            guard let channels = buffer.floatChannelData else {
                throw AudioPipelineError.conversionFailed("Audio sample-rate conversion produced no channels.")
            }
            var samples = [Float](repeating: 0, count: frames * 2)
            for frame in 0 ..< frames {
                samples[frame * 2] = channels[0][frame]
                samples[frame * 2 + 1] = channels[1][frame]
            }
            guard samples.allSatisfy(\.isFinite) else {
                throw AudioPipelineError.conversionFailed("Audio sample-rate conversion produced nonfinite samples.")
            }
            return makePacket(samples: samples, frames: frames)
        }

        private func makePacket(samples: [Float], frames: Int) -> NormalizedAudioPacket {
            let packet = NormalizedAudioPacket(
                source: source, presentationTime: anchor + Double(emittedFrames) / AudioFormat.sampleRate,
                frameCount: frames, samples: samples, isDiscontinuity: marksDiscontinuity
            )
            emittedFrames += Int64(frames)
            marksDiscontinuity = false
            return packet
        }
    }
}
