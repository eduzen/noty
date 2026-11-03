import Foundation

/// Peak meter for live recording UI. Safe to update from the capture pipeline.
struct RecordingAudioMeter: Sendable {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var peak: Float = 0
    }

    private let state = State()

    func observe(samples: [Float]) {
        var peak: Float = 0
        for sample in samples {
            peak = max(peak, abs(sample))
        }
        state.lock.lock()
        state.peak = max(peak, state.peak * 0.9)
        state.lock.unlock()
    }

    /// Current peak for UI polling, then decays the held value between polls.
    func sampleAndDecay() -> Float {
        state.lock.lock()
        defer { state.lock.unlock() }
        let value = state.peak
        state.peak *= 0.78
        return min(1, value)
    }

    func reset() {
        state.lock.lock()
        state.peak = 0
        state.lock.unlock()
    }
}
