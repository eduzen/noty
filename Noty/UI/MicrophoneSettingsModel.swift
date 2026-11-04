import AVFoundation
import Foundation

/// Microphone picker and level test for Settings. The choice is read when a recording starts.
@MainActor
final class MicrophoneSettingsModel: ObservableObject {
    @Published private(set) var devices: [AudioInputDevice] = []
    @Published private(set) var defaultDevice: AudioInputDevice?
    @Published private(set) var preference: MicrophonePreference
    @Published private(set) var level: Double = 0
    @Published private(set) var isTesting = false
    @Published private(set) var testError: String?

    private let listing: any AudioInputDeviceListing
    private let defaults: UserDefaults
    private let permission: any MicrophonePermissionProviding
    private var stopObserving: (@Sendable () -> Void)?
    private var tester: MicrophoneLevelTester?
    private var testedDeviceID: String?
    private var levelTask: Task<Void, Never>?

    init(
        listing: any AudioInputDeviceListing = CoreAudioInputDevices(),
        defaults: UserDefaults = .standard,
        permission: any MicrophonePermissionProviding = SystemMicrophonePermissionProvider()
    ) {
        self.listing = listing
        self.defaults = defaults
        self.permission = permission
        preference = .load(from: defaults)
    }

    /// The saved microphone is not connected right now.
    var isSelectionMissing: Bool {
        guard let uid = preference.uid else { return false }
        return !devices.contains { $0.id == uid }
    }

    func activate() {
        refresh()
        guard stopObserving == nil else { return }
        stopObserving = listing.observeChanges { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
    }

    func deactivate() {
        stopTest()
        stopObserving?()
        stopObserving = nil
    }

    func select(uid: String?) {
        let name = uid.flatMap { uid in devices.first { $0.id == uid }?.name }
        preference = MicrophonePreference(uid: uid, name: name ?? (uid == preference.uid ? preference.name : nil))
        preference.save(to: defaults)
        testError = nil
        restartTestIfDeviceChanged()
    }

    func refresh() {
        devices = listing.inputDevices()
        defaultDevice = listing.defaultInputDevice()
        restartTestIfDeviceChanged()
    }

    func toggleTest() async {
        if isTesting {
            stopTest()
        } else {
            await startTest()
        }
    }

    func startTest() async {
        guard !isTesting else { return }
        testError = nil
        if permission.authorizationStatus == .notDetermined {
            _ = await permission.requestAccess()
        }
        guard permission.authorizationStatus == .authorized else {
            testError = "Allow Noty to use the microphone in System Settings → Privacy & Security → Microphone."
            return
        }
        do {
            let device = try preference.resolve(in: listing)
            let tester = MicrophoneLevelTester()
            try tester.start(device: device)
            self.tester = tester
            testedDeviceID = device.id
            isTesting = true
            levelTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
                    self?.level = Double(tester.meter.sampleAndDecay())
                }
            }
        } catch {
            let issue = RecordingIssueMapper.issue(from: error)
            if issue.code == "capture.stream-failed" {
                testError = "This input couldn’t start. Check its connection or choose another input, then test again."
            } else {
                testError = issue.message
            }
        }
    }

    func stopTest() {
        levelTask?.cancel()
        levelTask = nil
        tester?.stop()
        tester = nil
        testedDeviceID = nil
        isTesting = false
        level = 0
    }

    private func restartTestIfDeviceChanged() {
        guard isTesting else { return }
        let current = try? preference.resolve(in: listing)
        guard current?.id != testedDeviceID else { return }
        stopTest()
        Task { await startTest() }
    }
}

/// Runs a throwaway engine on one input device to drive the Settings level meter.
final class MicrophoneLevelTester {
    let meter = RecordingAudioMeter()
    private let engine = AVAudioEngine()

    func start(device: AudioInputDevice) throws {
        try engine.useInputDevice(device)
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureServiceError.microphoneUnavailable
        }
        let meter = meter
        // Rebinding the input can leave the output bus at the previous device's sample rate.
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            guard let channels = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength) * (buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1)
            let channelCount = buffer.format.isInterleaved ? 1 : Int(buffer.format.channelCount)
            var peak: Float = 0
            for channel in 0 ..< channelCount {
                for frame in 0 ..< frames {
                    peak = max(peak, abs(channels[channel][frame]))
                }
            }
            meter.observe(samples: [peak])
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureServiceError.streamFailure("“\(device.name)” could not start (\(error.localizedDescription)).")
        }
    }

    func stop() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }
}
