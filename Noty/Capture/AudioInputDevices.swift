import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// A Core Audio device with at least one input channel. `id` is the device UID, which survives
/// reconnects and restarts; `objectID` is valid only while the device stays connected.
struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let objectID: AudioObjectID
}

protocol AudioInputDeviceListing: Sendable {
    func inputDevices() -> [AudioInputDevice]
    func defaultInputDevice() -> AudioInputDevice?
    /// Calls `onChange` on the main queue when devices or the default input change. Returns a cancel closure.
    func observeChanges(_ onChange: @escaping @Sendable () -> Void) -> @Sendable () -> Void
}

/// The microphone chosen in Settings. A `nil` UID follows the macOS default input.
struct MicrophonePreference: Equatable, Sendable {
    static let uidKey = "microphoneDeviceUID"
    static let nameKey = "microphoneDeviceName"

    var uid: String?
    /// Last known name, so a disconnected choice can still be named in errors and Settings.
    var name: String?

    static func load(from defaults: UserDefaults = .standard) -> MicrophonePreference {
        MicrophonePreference(uid: defaults.string(forKey: uidKey), name: defaults.string(forKey: nameKey))
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(uid, forKey: Self.uidKey)
        defaults.set(uid == nil ? nil : name, forKey: Self.nameKey)
    }

    /// A chosen microphone that is missing fails instead of falling back, so Noty never records another mic silently.
    func resolve(in devices: any AudioInputDeviceListing) throws -> AudioInputDevice {
        if let uid {
            guard let device = devices.inputDevices().first(where: { $0.id == uid }) else {
                throw CaptureServiceError.selectedMicrophoneUnavailable(name ?? "The selected microphone")
            }
            return device
        }
        guard let device = devices.defaultInputDevice() else {
            throw CaptureServiceError.microphoneUnavailable
        }
        return device
    }
}

struct CoreAudioInputDevices: AudioInputDeviceListing {
    /// Noty's private system-audio aggregate exposes the tap as an input, but it is never a microphone.
    private static let excludedNames: Set<String> = ["Noty System Audio"]
    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    func inputDevices() -> [AudioInputDevice] {
        var address = Self.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(Self.systemObject, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(Self.systemObject, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap(Self.inputDevice)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func defaultInputDevice() -> AudioInputDevice? {
        var address = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(Self.systemObject, &address, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return Self.inputDevice(id)
    }

    func observeChanges(_ onChange: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        let addresses = [
            Self.address(kAudioHardwarePropertyDevices),
            Self.address(kAudioHardwarePropertyDefaultInputDevice)
        ]
        let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        for var address in addresses {
            AudioObjectAddPropertyListenerBlock(Self.systemObject, &address, .main, block)
        }
        return {
            for var address in addresses {
                AudioObjectRemovePropertyListenerBlock(Self.systemObject, &address, .main, block)
            }
        }
    }

    private static func inputDevice(_ id: AudioObjectID) -> AudioInputDevice? {
        guard inputChannelCount(id) > 0,
              let uid = string(id, kAudioDevicePropertyDeviceUID),
              let name = string(id, kAudioObjectPropertyName),
              !excludedNames.contains(name) else { return nil }
        return AudioInputDevice(id: uid, name: name, objectID: id)
    }

    private static func inputChannelCount(_ id: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, storage) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}

extension AVAudioEngine {
    /// Points the input node at `device`. Call before reading the input format or installing a tap;
    /// otherwise the engine records the macOS default input.
    func useInputDevice(_ device: AudioInputDevice) throws {
        guard let unit = inputNode.audioUnit else {
            throw CaptureServiceError.microphoneUnavailable
        }
        var objectID = device.objectID
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &objectID,
            UInt32(MemoryLayout<AudioObjectID>.size)
        )
        guard status == noErr else {
            throw CaptureServiceError.streamFailure(
                "Noty could not use the microphone “\(device.name)” (OSStatus \(status))."
            )
        }
    }
}
