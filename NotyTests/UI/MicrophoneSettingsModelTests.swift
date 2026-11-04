import AVFoundation
import Foundation
@testable import Noty
import XCTest

@MainActor
final class MicrophoneSettingsModelTests: XCTestCase {
    private let builtIn = AudioInputDevice(id: "built-in", name: "Built-in input", objectID: 10)

    func testChoosingAnotherInputClearsPreviousTestFailure() async throws {
        let suite = "MicrophoneSettingsModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        MicrophonePreference(uid: "disconnected", name: "Headset").save(to: defaults)
        let model = MicrophoneSettingsModel(
            listing: SettingsInputDevices(device: builtIn),
            defaults: defaults,
            permission: SettingsMicrophonePermission()
        )
        model.activate()
        defer { model.deactivate() }
        await model.startTest()
        XCTAssertNotNil(model.testError)

        model.select(uid: builtIn.id)

        XCTAssertNil(model.testError)
        XCTAssertEqual(MicrophonePreference.load(from: defaults).uid, builtIn.id)
    }
}

private struct SettingsInputDevices: AudioInputDeviceListing {
    let device: AudioInputDevice

    func inputDevices() -> [AudioInputDevice] {
        [device]
    }

    func defaultInputDevice() -> AudioInputDevice? {
        device
    }

    func observeChanges(_: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        {}
    }
}

private struct SettingsMicrophonePermission: MicrophonePermissionProviding {
    var authorizationStatus: AVAuthorizationStatus {
        .authorized
    }

    func requestAccess() async -> Bool {
        true
    }
}
