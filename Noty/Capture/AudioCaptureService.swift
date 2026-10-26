import Foundation

/// One audio source (system tap or microphone). Backends deliver packets on their own threads and
/// report unrecoverable failures through `onTermination`.
protocol AudioCaptureBackend: AnyObject {
    func start(
        onPacket: @escaping (CapturedAudioPacket) -> Void,
        onTermination: @escaping (CaptureTermination) -> Void
    ) async throws
    func stop() async
}

/// Runs every backend as one capture session. If any source fails, the whole recording ends,
/// so a recording never silently continues with only one source.
final class AudioCaptureService: CaptureService {
    let packets: AsyncThrowingStream<CapturedAudioPacket, Error>
    let terminations: AsyncStream<CaptureTermination>

    private let packetContinuation: AsyncThrowingStream<CapturedAudioPacket, Error>.Continuation
    private let terminationContinuation: AsyncStream<CaptureTermination>.Continuation
    private let backends: [any AudioCaptureBackend]
    private let lock = NSLock()
    private var started = false
    private var stopped = false
    private var startupTask: Task<Void, Error>?
    private var backendStopTask: Task<Void, Never>?

    init(backends: [any AudioCaptureBackend] = [SystemAudioTapBackend(), MicrophoneEngineBackend()]) {
        let (packets, packetContinuation) = AsyncThrowingStream<CapturedAudioPacket, Error>
            .makeStream(bufferingPolicy: .bufferingOldest(3))
        let (terminations, terminationContinuation) = AsyncStream<CaptureTermination>
            .makeStream(bufferingPolicy: .bufferingNewest(1))
        self.packets = packets
        self.packetContinuation = packetContinuation
        self.terminations = terminations
        self.terminationContinuation = terminationContinuation
        self.backends = backends
    }

    func start() async throws {
        let task: Task<Void, Error>? = withLock {
            guard !started, !stopped else { return nil }
            started = true
            let task = Task { [weak self] in
                guard let self else { return }
                let onPacket: (CapturedAudioPacket) -> Void = { [weak self] packet in
                    guard let self else { return }
                    switch packetContinuation.yield(packet) {
                    case .enqueued: break
                    case .dropped:
                        terminate(with: .queueOverflow(RecordingIssue(
                            code: "capture.queue-overflow",
                            message: "Audio capture exceeded its bounded buffer.",
                            isRetryAllowed: false
                        )))
                    case .terminated: break
                    @unknown default: break
                    }
                }
                let onTermination: (CaptureTermination) -> Void = { [weak self] termination in
                    self?.terminate(with: termination)
                }
                // Backends start in order. A failure here stops any backend already running.
                for backend in backends {
                    try await backend.start(onPacket: onPacket, onTermination: onTermination)
                }
            }
            startupTask = task
            return task
        }
        guard let task else { return }

        do {
            try await task.value
        } catch {
            let shouldFinish = withLock {
                let shouldFinish = !stopped
                stopped = true
                return shouldFinish
            }
            await stopBackendsOnce()
            if shouldFinish {
                packetContinuation.finish(throwing: error)
                terminationContinuation.yield(Self.termination(for: error))
                terminationContinuation.finish()
            }
            throw error
        }
    }

    func stop() async {
        let state: (shouldFinish: Bool, shouldStopBackends: Bool, startupTask: Task<Void, Error>?) = withLock {
            let shouldFinish = !stopped
            let shouldStopBackends = started
            stopped = true
            return (shouldFinish, shouldStopBackends, startupTask)
        }
        state.startupTask?.cancel()
        if state.shouldStopBackends {
            if let startupTask = state.startupTask {
                _ = try? await startupTask.value
            }
            await stopBackendsOnce()
        }
        guard state.shouldFinish else { return }
        packetContinuation.finish()
        terminationContinuation.yield(.userStopped)
        terminationContinuation.finish()
    }

    private func stopBackendsOnce() async {
        let task: Task<Void, Never> = withLock {
            if let existingTask = backendStopTask {
                return existingTask
            }
            let backends = backends
            let task = Task {
                for backend in backends {
                    await backend.stop()
                }
            }
            backendStopTask = task
            return task
        }
        await task.value
    }

    private func terminate(with termination: CaptureTermination) {
        let state = withLock {
            let shouldFinish = !stopped
            stopped = true
            return (shouldFinish, startupTask)
        }
        guard state.0 else { return }
        state.1?.cancel()
        packetContinuation.finish(throwing: Self.error(for: termination))
        terminationContinuation.yield(termination)
        terminationContinuation.finish()
        Task {
            if let startupTask = state.1 {
                _ = try? await startupTask.value
            }
            await stopBackendsOnce()
        }
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }

    private static func termination(for error: Error) -> CaptureTermination {
        if let captureError = error as? CaptureServiceError {
            switch captureError {
            case .systemAudioDenied:
                return .systemAudioDenied(RecordingIssue(
                    code: "capture.system-audio-denied",
                    message: """
                    Noty cannot capture system audio. Allow Noty under System Settings → Privacy & Security → \
                    System Audio Recording Only, then try again.
                    """,
                    recoveryURL: CaptureSettingsLinks.systemAudio,
                    isRetryAllowed: true
                ))
            case .microphoneUnavailable:
                return .microphoneDisconnected(RecordingIssue(
                    code: "capture.microphone-unavailable",
                    message: "No default microphone is available.",
                    isRetryAllowed: true
                ))
            case let .streamFailure(message):
                return .unexpected(RecordingIssue(
                    code: "capture.stream-failed",
                    message: message,
                    isRetryAllowed: true
                ))
            case .queueOverflow:
                return .queueOverflow(RecordingIssue(
                    code: "capture.queue-overflow",
                    message: "Audio capture exceeded its bounded buffer.",
                    isRetryAllowed: false
                ))
            case .alreadyStarted, .notStarted, .invalidAudioFormat:
                return .unexpected(RecordingIssue(
                    code: "capture.setup-failed",
                    message: error.localizedDescription,
                    isRetryAllowed: true
                ))
            }
        }
        return .unexpected(RecordingIssue(
            code: "capture.stream-failed",
            message: error.localizedDescription,
            isRetryAllowed: true
        ))
    }

    private static func error(for termination: CaptureTermination) -> Error {
        switch termination {
        case .userStopped: return CancellationError()
        case let .systemAudioDenied(issue), let .interrupted(issue), let .microphoneDisconnected(issue),
             let .unexpected(issue),
             let .queueOverflow(issue): return issue
        }
    }
}
