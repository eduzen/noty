import AppKit
import AVFoundation
import CoreAudio
import Foundation

/// Captures all system output with a Core Audio process tap.
///
/// Unlike ScreenCaptureKit, a tap needs only "System Audio Recording Only", not Screen Recording.
/// Noty excludes its own process, so the tap never records the app itself.
final class SystemAudioTapBackend: AudioCaptureBackend {
    private static let unknownObject = AudioObjectID(kAudioObjectUnknown)
    private static let outputDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private let queue = DispatchQueue(label: "noty.capture.system-audio", qos: .userInitiated)
    private let lock = NSLock()
    private var packetHandler: ((CapturedAudioPacket) -> Void)?
    private var terminationHandler: ((CaptureTermination) -> Void)?
    private var format: AudioStreamBasicDescription?
    private var stopped = true
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var sleepObserver: NSObjectProtocol?

    func start(
        onPacket: @escaping (CapturedAudioPacket) -> Void,
        onTermination: @escaping (CaptureTermination) -> Void
    ) async throws {
        withLock {
            packetHandler = onPacket
            terminationHandler = onTermination
            stopped = false
        }
        do {
            try createTapAndAggregateDevice()
            try startDevice()
            installObservers()
        } catch {
            teardown()
            withLock {
                stopped = true
                packetHandler = nil
                terminationHandler = nil
            }
            throw error
        }
    }

    func stop() async {
        withLock {
            stopped = true
            packetHandler = nil
            terminationHandler = nil
        }
        teardown()
    }

    // MARK: - Setup

    private func createTapAndAggregateDevice() throws {
        let ownProcess = try Self.currentProcessObject()
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProcess])
        tapDescription.uuid = UUID()
        tapDescription.name = "Noty System Audio"
        // The default mute behavior is unmuted, so system audio keeps playing while it is recorded.
        tapDescription.isPrivate = true

        tapID = try Self.createProcessTap(tapDescription)
        format = try Self.tapFormat(tapID)

        // Physical output devices can also have inputs (for example, a USB audio interface).
        // Adding one as a subdevice would prepend its input buffers to the tap's stereo buffer.
        // This aggregate must expose only the system tap; the microphone is captured separately.
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Noty System Audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapDescription.uuid.uuidString
            ]]
        ]
        var newAggregate = Self.unknownObject
        try Self.check(
            AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregate),
            "create aggregate device"
        )
        aggregateID = newAggregate
    }

    private func startDevice() throws {
        var procID: AudioDeviceIOProcID?
        let ioBlock: AudioDeviceIOBlock = { [weak self] _, inputData, inputTime, _, _ in
            self?.handleInput(inputData, inputTime: inputTime.pointee)
        }
        try Self.check(
            AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue, ioBlock),
            "create system audio IO proc"
        )
        ioProcID = procID
        try Self.check(AudioDeviceStart(aggregateID, procID), "start system audio device")
    }

    /// Stops the device before destroying anything it depends on: IO proc, aggregate device, then tap.
    private func teardown() {
        removeObservers()
        if aggregateID != Self.unknownObject {
            if let ioProcID {
                _ = AudioDeviceStop(aggregateID, ioProcID)
                _ = AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            _ = AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = Self.unknownObject
        }
        ioProcID = nil
        if tapID != Self.unknownObject {
            _ = AudioHardwareDestroyProcessTap(tapID)
            tapID = Self.unknownObject
        }
        withLock { format = nil }
    }

    // MARK: - Callbacks

    private func handleInput(_ inputData: UnsafePointer<AudioBufferList>, inputTime: AudioTimeStamp) {
        let (handler, streamFormat) = withLock { (stopped ? nil : packetHandler, format) }
        guard let handler, let streamFormat else { return }
        // A zero host time means the device did not stamp this buffer; fall back to "now" on the same clock.
        let hostTime = inputTime.mHostTime != 0 ? inputTime.mHostTime : mach_absolute_time()
        do {
            let packet = try CapturedAudioPacket.copying(
                bufferList: inputData,
                format: streamFormat,
                source: .system,
                presentationTime: AVAudioTime.seconds(forHostTime: hostTime)
            )
            // #region agent log
            if AgentDebugLog.shouldEmit("system.packet") {
                AgentDebugLog.log("SystemAudioTapBackend.handleInput", "system packet", hypothesis: "C,D", [
                    "pts": packet.presentationTime,
                    "lagSec": AVAudioTime.seconds(forHostTime: mach_absolute_time()) - packet.presentationTime,
                    "frames": packet.frameCount, "sampleRate": packet.sampleRate, "channels": packet.channelCount,
                    "rms0": AgentDebugLog.rms(packet.samples, channels: packet.channelCount, channel: 0)
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
                message: "System audio returned an unsupported audio buffer.",
                isRetryAllowed: false
            )))
        }
    }

    private func installObservers() {
        // Changing the default output device moves the tap's aggregate device, so the recording cannot continue.
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.notify(.interrupted(RecordingIssue(
                code: "capture.output-device-changed",
                message: "The default output device changed, so system audio capture stopped.",
                isRetryAllowed: true
            )))
        }
        var address = Self.outputDeviceAddress
        if AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, listener
        ) == noErr {
            outputListener = listener
        }

        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.notify(.interrupted(RecordingIssue(
                code: "capture.sleep",
                message: "Audio capture stopped because the Mac is going to sleep.",
                isRetryAllowed: true
            )))
        }
    }

    private func removeObservers() {
        if let outputListener {
            var address = Self.outputDeviceAddress
            _ = AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, queue, outputListener
            )
        }
        outputListener = nil
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
        }
        sleepObserver = nil
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

    // MARK: - Core Audio property helpers

    static func createProcessTap(
        _ description: CATapDescription,
        using create: (CATapDescription, UnsafeMutablePointer<AudioObjectID>)
            -> OSStatus = AudioHardwareCreateProcessTap
    ) throws -> AudioObjectID {
        var tap = unknownObject
        try check(create(description, &tap), "create process tap")
        return tap
    }

    private static func currentProcessObject() throws -> AudioObjectID {
        var pid = getpid()
        var object = unknownObject
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        try check(
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                &pid,
                &size,
                &object
            ),
            "translate process to audio object"
        )
        return object
    }

    private static func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &description), "read tap format")
        return description
    }

    private static func defaultOutputDeviceUID() throws -> String {
        var deviceID = unknownObject
        var address = outputDeviceAddress
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID),
            "read default output device"
        )

        var uid: Unmanaged<CFString>?
        address.mSelector = kAudioDevicePropertyDeviceUID
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid), "read output device UID")
        guard let uid else {
            throw CaptureServiceError.streamFailure(
                "System audio capture could not read output device UID (no value returned)."
            )
        }
        return uid.takeUnretainedValue() as String
    }

    private static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw CaptureServiceError.streamFailure("System audio capture could not \(operation) (OSStatus \(status)).")
        }
    }
}
