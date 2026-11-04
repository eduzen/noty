import AVFoundation
import CoreAudio
import Foundation

/// Captures the microphone chosen in Settings (or the macOS default input) with AVAudioEngine.
///
/// Packets are stamped on the host clock, the same clock as the system tap, so both sources
/// line up in `AudioTimeline`. Microphone access is still checked by `PermissionCoordinator`.
final class MicrophoneEngineBackend: AudioCaptureBackend {
    private static let bufferFrames: AVAudioFrameCount = 4096

    private let preference: () -> MicrophonePreference
    private let devices: any AudioInputDeviceListing
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var packetHandler: ((CapturedAudioPacket) -> Void)?
    private var terminationHandler: ((CaptureTermination) -> Void)?
    private var stopped = true
    private var observers: [NSObjectProtocol] = []

    init(
        preference: @escaping () -> MicrophonePreference = { .load() },
        devices: any AudioInputDeviceListing = CoreAudioInputDevices()
    ) {
        self.preference = preference
        self.devices = devices
    }

    func start(
        onPacket: @escaping (CapturedAudioPacket) -> Void,
        onTermination: @escaping (CaptureTermination) -> Void
    ) async throws {
        let microphone = try preference().resolve(in: devices)
        let engine = AVAudioEngine()
        // Bind explicitly even for the default input, so a later default change cannot swap the mic mid-recording.
        try engine.useInputDevice(microphone)
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureServiceError.microphoneUnavailable
        }
        // #region agent log
        let allInputs = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices.map { "\($0.localizedName) [\($0.uniqueID)]" }
        AgentDebugLog.log("MicrophoneEngineBackend.start", "mic start", hypothesis: "A,B", [
            "selectedMicrophone": microphone.name, "selectedMicrophoneID": microphone.id,
            "engineSampleRate": format.sampleRate, "engineChannels": format.channelCount,
            "allInputs": allInputs, "coreAudioDefaultInput": Self.agentDefaultInputName()
        ])
        // #endregion

        withLock {
            self.engine = engine
            packetHandler = onPacket
            terminationHandler = onTermination
            stopped = false
        }
        // The output bus can retain the previous device's format after rebinding the input.
        // Set the tap to the selected hardware's native format, including its sample rate.
        input.installTap(onBus: 0, bufferSize: Self.bufferFrames, format: format) { [weak self] buffer, time in
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
        installObservers(engine: engine, microphoneID: microphone.id)
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
            // #region agent log
            if AgentDebugLog.shouldEmit("mic.packet") {
                let levels = (0 ..< packet.channelCount).map {
                    AgentDebugLog.rms(packet.samples, channels: packet.channelCount, channel: $0)
                }
                AgentDebugLog.log("MicrophoneEngineBackend.handle", "mic packet", hypothesis: "B,C,D,E", [
                    "pts": packet.presentationTime,
                    "lagSec": AVAudioTime.seconds(forHostTime: mach_absolute_time()) - packet.presentationTime,
                    "hostTimeValid": time.isHostTimeValid, "frames": packet.frameCount,
                    "sampleRate": packet.sampleRate, "channels": packet.channelCount, "rmsPerChannel": levels
                ])
            }
            // #endregion
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
        // Device binding can deliver a delayed notification after startup. A real hardware
        // format change stops the engine; a still-running engine has not been interrupted.
        let configuration = center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self, weak engine] _ in
            guard let engine, !engine.isRunning else { return }
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

    /// #region agent log
    private static func agentDefaultInputName() -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) ==
            noErr
        else { return "unknown" }
        address.mSelector = kAudioObjectPropertyName
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name) == noErr,
              let value = name?.takeRetainedValue() else { return "id \(deviceID)" }
        return "\(value as String) (id \(deviceID))"
    }

    // #endregion

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}
