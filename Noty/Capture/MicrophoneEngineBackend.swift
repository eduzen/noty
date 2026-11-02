import AVFoundation
import Foundation

/// Captures the default microphone with AVAudioEngine.
///
/// Packets are stamped on the host clock, the same clock as the system tap, so both sources
/// line up in `AudioTimeline`. Microphone access is still checked by `PermissionCoordinator`.
final class MicrophoneEngineBackend: AudioCaptureBackend {
    private static let bufferFrames: AVAudioFrameCount = 4096

    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var packetHandler: ((CapturedAudioPacket) -> Void)?
    private var terminationHandler: ((CaptureTermination) -> Void)?
    private var stopped = true
    private var observers: [NSObjectProtocol] = []

    func start(
        onPacket: @escaping (CapturedAudioPacket) -> Void,
        onTermination: @escaping (CaptureTermination) -> Void
    ) async throws {
        guard let microphone = AVCaptureDevice.default(for: .audio) else {
            throw CaptureServiceError.microphoneUnavailable
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureServiceError.microphoneUnavailable
        }

        withLock {
            self.engine = engine
            packetHandler = onPacket
            terminationHandler = onTermination
            stopped = false
        }
        // Let the input node use its native format. Passing a stale hardware format can make
        // AVAudioEngine fail with kAudioUnitErr_InvalidElement (-10877) during startup.
        input.installTap(onBus: 0, bufferSize: Self.bufferFrames, format: nil) { [weak self] buffer, time in
            self?.handle(buffer, time: time)
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            if engine.isRunning {
                engine.stop()
            }
            input.removeTap(onBus: 0)
            withLock {
                self.engine = nil
                stopped = true
                packetHandler = nil
                terminationHandler = nil
            }
            throw CaptureServiceError.streamFailure("The microphone could not start (\(error.localizedDescription)).")
        }
        installObservers(engine: engine, microphoneID: microphone.uniqueID)
    }

    func stop() async {
        let engine = withLock { () -> AVAudioEngine? in
            stopped = true
            packetHandler = nil
            terminationHandler = nil
            let engine = self.engine
            self.engine = nil
            return engine
        }
        removeObservers()
        guard let engine else { return }
        if engine.isRunning {
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)
    }

    private func handle(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        let handler = withLock { stopped ? nil : packetHandler }
        guard let handler else { return }
        let hostTime = time.isHostTimeValid ? time.hostTime : mach_absolute_time()
        do {
            let packet = try CapturedAudioPacket.copying(
                bufferList: buffer.audioBufferList,
                format: buffer.format.streamDescription.pointee,
                source: .microphone,
                presentationTime: AVAudioTime.seconds(forHostTime: hostTime)
            )
            handler(packet)
        } catch CaptureServiceError.queueOverflow {
            notify(.queueOverflow(RecordingIssue(
                code: "capture.queue-overflow",
                message: "Audio capture exceeded its bounded buffer.",
                isRetryAllowed: false
            )))
        } catch {
            notify(.unexpected(RecordingIssue(
                code: "capture.invalid-audio",
                message: "The microphone returned an unsupported audio buffer.",
                isRetryAllowed: false
            )))
        }
    }

    private func installObservers(engine: AVAudioEngine, microphoneID: String) {
        let center = NotificationCenter.default
        let disconnected = center.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let device = notification.object as? AVCaptureDevice, device.uniqueID == microphoneID else {
                return
            }
            self?.notify(.microphoneDisconnected(RecordingIssue(
                code: "capture.microphone-disconnected",
                message: "The microphone was disconnected.",
                isRetryAllowed: true
            )))
        }
        // Input device or format changes invalidate the running tap.
        let configuration = center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.notify(.interrupted(RecordingIssue(
                code: "capture.microphone-changed",
                message: "The microphone configuration changed, so microphone capture stopped.",
                isRetryAllowed: true
            )))
        }
        withLock { observers = [disconnected, configuration] }
    }

    private func removeObservers() {
        let current = withLock { () -> [NSObjectProtocol] in
            let current = observers
            observers = []
            return current
        }
        for observer in current {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func notify(_ termination: CaptureTermination) {
        let handler: ((CaptureTermination) -> Void)? = withLock {
            guard !stopped else { return nil }
            return terminationHandler
        }
        handler?(termination)
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}
