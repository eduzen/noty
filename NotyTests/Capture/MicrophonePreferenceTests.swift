import Foundation
@testable import Noty
import XCTest

final class MicrophonePreferenceTests: XCTestCase {
    private let builtIn = AudioInputDevice(id: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", objectID: 10)
    private let scarlett = AudioInputDevice(id: "AppleUSBAudioEngine:Focusrite", name: "Scarlett 2i2 USB", objectID: 20)

    func testNoChoiceFollowsSystemDefault() throws {
        let devices = FakeInputDevices(devices: [builtIn, scarlett], defaultDevice: builtIn)

        XCTAssertEqual(try MicrophonePreference(uid: nil).resolve(in: devices), builtIn)
    }

    func testChosenMicrophoneWinsOverSystemDefault() throws {
        let devices = FakeInputDevices(devices: [builtIn, scarlett], defaultDevice: builtIn)

        XCTAssertEqual(try MicrophonePreference(uid: scarlett.id, name: scarlett.name).resolve(in: devices), scarlett)
    }

    func testMissingChosenMicrophoneFailsInsteadOfFallingBack() {
        let devices = FakeInputDevices(devices: [builtIn], defaultDevice: builtIn)

        XCTAssertThrowsError(try MicrophonePreference(uid: scarlett.id, name: scarlett.name).resolve(in: devices)) {
            XCTAssertEqual($0 as? CaptureServiceError, .selectedMicrophoneUnavailable("Scarlett 2i2 USB"))
        }
    }

    func testNoDefaultInputIsUnavailable() {
        let devices = FakeInputDevices(devices: [], defaultDevice: nil)

        XCTAssertThrowsError(try MicrophonePreference(uid: nil).resolve(in: devices)) {
            XCTAssertEqual($0 as? CaptureServiceError, .microphoneUnavailable)
        }
    }

    func testSaveAndLoadRoundTripAndClearingRemovesName() throws {
        let suite = "MicrophonePreferenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        MicrophonePreference(uid: scarlett.id, name: scarlett.name).save(to: defaults)
        XCTAssertEqual(.load(from: defaults), MicrophonePreference(uid: scarlett.id, name: scarlett.name))

        MicrophonePreference(uid: nil, name: scarlett.name).save(to: defaults)
        XCTAssertEqual(.load(from: defaults), MicrophonePreference(uid: nil, name: nil))
    }
}

private struct FakeInputDevices: AudioInputDeviceListing {
    let devices: [AudioInputDevice]
    let defaultDevice: AudioInputDevice?

    func inputDevices() -> [AudioInputDevice] {
        devices
    }

    func defaultInputDevice() -> AudioInputDevice? {
        defaultDevice
    }

    func observeChanges(_: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        {}
    }
}
