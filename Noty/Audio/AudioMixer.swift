import Foundation

/// Mixes timestamp-aligned normalized sources with -6 dB fixed headroom and a -1 dBFS peak ceiling.
struct AudioMixer {
    private var timeline: AudioTimeline
    private let headroom: Float = 0.5011872
    private let peakLimit: Float = 0.8912509

    init(origin: TimeInterval? = nil, reorderWindow: TimeInterval = 0.25) {
        timeline = AudioTimeline(origin: origin, reorderWindow: reorderWindow)
    }

    mutating func append(_ packet: NormalizedAudioPacket) throws -> [MixedAudioChunk] {
        try timeline.append(packet).map(limit)
    }

    mutating func finish() throws -> [MixedAudioChunk] {
        try timeline.finish().map(limit)
    }

    private func limit(_ chunk: MixedAudioChunk) -> MixedAudioChunk {
        let knee = peakLimit * 0.8
        let width = peakLimit - knee
        var samples = chunk.samples
        for index in samples.indices {
            let level = samples[index] * headroom
            let magnitude = abs(level)
            if magnitude <= knee {
                samples[index] = level
            } else {
                let compressed = knee + width * (1 - Float(Foundation.exp(-Double(magnitude - knee) / Double(width))))
                samples[index] = level.sign == .minus ? -compressed : compressed
            }
        }
        return MixedAudioChunk(presentationTime: chunk.presentationTime, frameCount: chunk.frameCount, samples: samples)
    }
}
