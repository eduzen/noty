import Foundation

/// Capture source for a copied interleaved Float32 packet.
enum AudioSource: String, Equatable, Sendable {
    case system
    case microphone
}

/// Audio callback data. `presentationTime` is seconds on the capture host timeline.
struct CapturedAudioPacket: Sendable {
    let source: AudioSource
    let presentationTime: TimeInterval
    let sampleRate: Double
    let channelCount: Int
    let frameCount: Int
    let samples: [Float]
    let isDiscontinuity: Bool

    init(
        source: AudioSource,
        presentationTime: TimeInterval,
        sampleRate: Double,
        channelCount: Int,
        frameCount: Int,
        samples: [Float],
        isDiscontinuity: Bool = false
    ) {
        self.source = source
        self.presentationTime = presentationTime
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.frameCount = frameCount
        self.samples = samples
        self.isDiscontinuity = isDiscontinuity
    }
}

/// Canonical 48 kHz stereo interleaved Float32 packet; time is seconds.
struct NormalizedAudioPacket: Sendable {
    let source: AudioSource
    let presentationTime: TimeInterval
    let sampleRate: Double
    let channelCount: Int
    let frameCount: Int
    let samples: [Float]
    let isDiscontinuity: Bool

    init(
        source: AudioSource,
        presentationTime: TimeInterval,
        frameCount: Int,
        samples: [Float],
        isDiscontinuity: Bool = false
    ) {
        self.source = source
        self.presentationTime = presentationTime
        sampleRate = AudioFormat.sampleRate
        channelCount = AudioFormat.channelCount
        self.frameCount = frameCount
        self.samples = samples
        self.isDiscontinuity = isDiscontinuity
    }
}

enum AudioFormat {
    static let sampleRate = 48000.0
    static let channelCount = 2
}

/// Interleaved stereo Float32 samples at the exact output `presentationTime`.
struct MixedAudioChunk: Sendable {
    let presentationTime: TimeInterval
    let sampleRate: Double
    let channelCount: Int
    let frameCount: Int
    let samples: [Float]

    init(presentationTime: TimeInterval, frameCount: Int, samples: [Float]) {
        self.presentationTime = presentationTime
        sampleRate = AudioFormat.sampleRate
        channelCount = AudioFormat.channelCount
        self.frameCount = frameCount
        self.samples = samples
    }
}

enum AudioPipelineError: Error, Equatable, Sendable {
    case malformedPacket(String)
    case unsupportedFormat(String)
    case conversionFailed(String)
    case timingDiscontinuity(String)
    case queueOverflow
}
