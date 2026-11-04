import AVFoundation
import Foundation

/// Clock for capture timestamps, pause boundaries, and elapsed time. Same host timeline as capture packets.
enum RecordingClock {
    static func now() -> TimeInterval {
        AVAudioTime.seconds(forHostTime: mach_absolute_time())
    }
}

/// Decides which capture timestamps are written while a recording is paused.
///
/// Decisions are made per timestamp, not per arrival, so audio captured before a pause is kept even when it
/// is delivered late. Audio inside a pause is dropped. Audio after a pause is shifted back by the total paused
/// time, so the written timeline is continuous and contains no silence gap.
final class RecordingPauseGate: @unchecked Sendable {
    enum Disposition: Equatable, Sendable {
        case keep(shift: TimeInterval)
        case drop
    }

    private struct Span: Equatable {
        let start: TimeInterval
        let end: TimeInterval
    }

    private let lock = NSLock()
    private var completedSpans: [Span] = []
    private var openStart: TimeInterval?

    func pause(at time: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        guard openStart == nil else { return }
        openStart = time
    }

    func resume(at time: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        guard let start = openStart else { return }
        openStart = nil
        completedSpans.append(Span(start: start, end: max(start, time)))
    }

    func disposition(for time: TimeInterval) -> Disposition {
        lock.lock()
        defer { lock.unlock() }
        if let openStart, time >= openStart {
            return .drop
        }
        var shift: TimeInterval = 0
        for span in completedSpans {
            if time < span.start {
                break
            }
            if time < span.end {
                return .drop
            }
            shift += span.end - span.start
        }
        return .keep(shift: shift)
    }
}

extension CapturedAudioPacket {
    func shifted(by shift: TimeInterval) -> CapturedAudioPacket {
        CapturedAudioPacket(
            source: source,
            presentationTime: presentationTime - shift,
            sampleRate: sampleRate,
            channelCount: channelCount,
            frameCount: frameCount,
            samples: samples,
            isDiscontinuity: isDiscontinuity
        )
    }
}

extension NormalizedAudioPacket {
    func shifted(by shift: TimeInterval) -> NormalizedAudioPacket {
        NormalizedAudioPacket(
            source: source,
            presentationTime: presentationTime - shift,
            frameCount: frameCount,
            samples: samples,
            isDiscontinuity: isDiscontinuity
        )
    }
}
