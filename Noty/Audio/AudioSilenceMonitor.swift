import Foundation

/// Detects a capture source that delivers only silence for too long.
///
/// macOS gives no public API to check System Audio Recording permission. When it is denied, the
/// tap keeps running and delivers zeros. A wrong or muted microphone (for example, the built-in mic
/// of a closed laptop) also delivers zeros. This monitor reports that once, so the controller can
/// warn the user without stopping the recording.
struct AudioSilenceMonitor {
    static let threshold: TimeInterval = 5
    /// Samples at or below this magnitude (about -80 dBFS) count as silence. A live microphone's
    /// noise floor sits above it.
    static let silenceLevel: Float = 0.0001

    let source: AudioSource
    private var firstTime: TimeInterval?
    private(set) var heardAudio = false
    private var reported = false

    init(source: AudioSource) {
        self.source = source
    }

    /// Returns `true` exactly once: when `threshold` seconds of `source` audio have passed with no signal.
    mutating func observe(_ packet: CapturedAudioPacket) -> Bool {
        guard packet.source == source, !heardAudio else { return false }
        if packet.samples.contains(where: { abs($0) > Self.silenceLevel }) {
            heardAudio = true
            return false
        }
        guard !reported else { return false }
        let start = firstTime ?? packet.presentationTime
        firstTime = start
        let end = packet.presentationTime + Double(packet.frameCount) / packet.sampleRate
        guard end - start >= Self.threshold else { return false }
        reported = true
        return true
    }
}
