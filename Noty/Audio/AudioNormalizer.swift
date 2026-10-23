import AVFoundation
import Foundation

struct AudioNormalizer {
    func normalize(_ packet: CapturedAudioPacket) throws -> NormalizedAudioPacket {
        guard packet.presentationTime.isFinite, packet.presentationTime >= 0,
              packet.sampleRate.isFinite, packet.sampleRate > 0,
              (1...32).contains(packet.channelCount), packet.frameCount > 0,
              packet.frameCount <= Int.max / packet.channelCount,
              packet.frameCount <= Int(AVAudioFrameCount.max),
              Double(packet.frameCount) / packet.sampleRate <= 5,
              packet.samples.count <= (64 * 1_024 * 1_024) / MemoryLayout<Float>.size,
              packet.samples.count == packet.frameCount * packet.channelCount,
              packet.samples.allSatisfy(\.isFinite) else {
            throw AudioPipelineError.malformedPacket("Audio packet has invalid timing, format, frame count, or samples.")
        }
        guard let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: packet.sampleRate, channels: 2, interleaved: false),
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioFormat.sampleRate, channels: 2, interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(packet.frameCount)),
              let left = input.floatChannelData?[0], let right = input.floatChannelData?[1] else {
            throw AudioPipelineError.unsupportedFormat("Could not create a supported Float32 audio format.")
        }

        input.frameLength = AVAudioFrameCount(packet.frameCount)
        // Mono is duplicated; wider inputs use the first two explicitly mapped channels.
        for frame in 0..<packet.frameCount {
            left[frame] = packet.samples[frame * packet.channelCount]
            right[frame] = packet.channelCount == 1 ? left[frame] : packet.samples[frame * packet.channelCount + 1]
        }
        guard let converter = AVAudioConverter(from: sourceFormat, to: outputFormat) else {
            throw AudioPipelineError.unsupportedFormat("Could not create an audio sample-rate converter.")
        }
        let requiredFrames = ceil(Double(packet.frameCount) * AudioFormat.sampleRate / packet.sampleRate) + 128
        guard requiredFrames.isFinite, requiredFrames > 0, requiredFrames <= Double(AVAudioFrameCount.max) else {
            throw AudioPipelineError.unsupportedFormat("The source sample rate requires an unsupported conversion buffer.")
        }
        let capacity = AVAudioFrameCount(requiredFrames)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
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
              let convertedLeft = output.floatChannelData?[0], let convertedRight = output.floatChannelData?[1] else {
            throw AudioPipelineError.conversionFailed(conversionError?.localizedDescription ?? "Audio sample-rate conversion failed.")
        }

        let frames = Int(output.frameLength)
        guard frames > 0 else {
            throw AudioPipelineError.conversionFailed("Audio sample-rate conversion produced no frames.")
        }
        var samples = [Float](repeating: 0, count: frames * AudioFormat.channelCount)
        for frame in 0..<frames {
            samples[frame * 2] = convertedLeft[frame]
            samples[frame * 2 + 1] = convertedRight[frame]
        }
        return NormalizedAudioPacket(source: packet.source, presentationTime: packet.presentationTime, frameCount: frames, samples: samples, isDiscontinuity: packet.isDiscontinuity)
    }
}
