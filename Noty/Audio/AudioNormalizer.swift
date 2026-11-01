import AVFoundation
import Foundation

struct AudioNormalizer {
    func normalize(_ packet: CapturedAudioPacket) throws -> NormalizedAudioPacket {
        try validate(packet)
        let (sourceFormat, outputFormat) = try makeFormats(for: packet.sampleRate)
        let input = try makeInputBuffer(for: packet, format: sourceFormat)
        let output = try convert(input, from: sourceFormat, to: outputFormat)
        return try makePacket(from: output, source: packet.source, presentationTime: packet.presentationTime,
                              isDiscontinuity: packet.isDiscontinuity)
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

    private func makeFormats(for sampleRate: Double) throws -> (AVAudioFormat, AVAudioFormat) {
        guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 2, interleaved: false),
            let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioFormat.sampleRate,
                                       channels: 2, interleaved: false)
        else {
            throw AudioPipelineError.unsupportedFormat("Could not create a supported Float32 audio format.")
        }
        return (source, output)
    }

    private func makeInputBuffer(
        for packet: CapturedAudioPacket,
        format: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        guard let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(packet.frameCount)),
              let left = input.floatChannelData?[0], let right = input.floatChannelData?[1]
        else {
            throw AudioPipelineError.unsupportedFormat("Could not create a supported Float32 audio format.")
        }

        input.frameLength = AVAudioFrameCount(packet.frameCount)
        // Mono is duplicated; wider inputs use the first two explicitly mapped channels.
        for frame in 0 ..< packet.frameCount {
            left[frame] = packet.samples[frame * packet.channelCount]
            right[frame] = packet.channelCount == 1 ? left[frame] : packet.samples[frame * packet.channelCount + 1]
        }
        return input
    }

    private func convert(
        _ input: AVAudioPCMBuffer,
        from sourceFormat: AVAudioFormat,
        to outputFormat: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        guard let converter = AVAudioConverter(from: sourceFormat, to: outputFormat) else {
            throw AudioPipelineError.unsupportedFormat("Could not create an audio sample-rate converter.")
        }
        let requiredFrames = ceil(Double(input.frameLength) * AudioFormat.sampleRate / sourceFormat.sampleRate) + 128
        guard requiredFrames.isFinite, requiredFrames > 0, requiredFrames <= Double(AVAudioFrameCount.max) else {
            throw AudioPipelineError
                .unsupportedFormat("The source sample rate requires an unsupported conversion buffer.")
        }
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: AVAudioFrameCount(requiredFrames)
        ) else {
            throw AudioPipelineError.conversionFailed("Could not allocate converted audio buffer.")
        }
        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard !suppliedInput else {
                inputStatus.pointee = .endOfStream
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return input
        }
        guard conversionError == nil, status != .error,
              output.floatChannelData?[0] != nil, output.floatChannelData?[1] != nil else {
            throw AudioPipelineError
                .conversionFailed(conversionError?.localizedDescription ?? "Audio sample-rate conversion failed.")
        }
        return output
    }

    private func makePacket(
        from output: AVAudioPCMBuffer,
        source: AudioSource,
        presentationTime: TimeInterval,
        isDiscontinuity: Bool
    ) throws -> NormalizedAudioPacket {
        guard let left = output.floatChannelData?[0], let right = output.floatChannelData?[1] else {
            throw AudioPipelineError.conversionFailed("Audio sample-rate conversion produced no channels.")
        }
        let frames = Int(output.frameLength)
        guard frames > 0 else {
            throw AudioPipelineError.conversionFailed("Audio sample-rate conversion produced no frames.")
        }
        var samples = [Float](repeating: 0, count: frames * AudioFormat.channelCount)
        for frame in 0 ..< frames {
            samples[frame * 2] = left[frame]
            samples[frame * 2 + 1] = right[frame]
        }
        return NormalizedAudioPacket(source: source, presentationTime: presentationTime, frameCount: frames,
                                     samples: samples, isDiscontinuity: isDiscontinuity)
    }
}
