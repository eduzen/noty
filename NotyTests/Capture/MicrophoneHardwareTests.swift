import AVFoundation
import CoreAudio
@testable import Noty
import XCTest

/// Opt in with NOTY_TEST_MICROPHONE_UID to exercise an actual input and its privacy grant.
final class MicrophoneHardwareTests: XCTestCase {
    func testLevelTestStartsOnSelectedInput() throws {
        let device = try selectedDevice()
        let tester = MicrophoneLevelTester()
        try tester.start(device: device)
        tester.stop()
    }

    func testRecordingReceivesSelectedInputsNativeFormat() async throws {
        let device = try selectedDevice()
        let format = nativeFormat(of: device)
        let backend = MicrophoneEngineBackend(preference: {
            MicrophonePreference(uid: device.id, name: device.name)
        })
        addTeardownBlock { await backend.stop() }
        let received = expectation(description: "Selected input delivers native audio")
        // Keep capture alive across delayed startup configuration notifications.
        received.expectedFulfillmentCount = 12
        received.assertForOverFulfill = false
        try await backend.start { packet in
            XCTAssertEqual(packet.sampleRate, format.mSampleRate)
            XCTAssertEqual(packet.channelCount, Int(format.mChannelsPerFrame))
            received.fulfill()
        } onTermination: { termination in
            XCTFail("Unexpected microphone termination: \(termination)")
        }
        await fulfillment(of: [received], timeout: 5)
    }

    private func selectedDevice() throws -> AudioInputDevice {
        guard let uid = ProcessInfo.processInfo.environment["NOTY_TEST_MICROPHONE_UID"] else {
            throw XCTSkip("Set NOTY_TEST_MICROPHONE_UID to test an available input with microphone access.")
        }
        return try XCTUnwrap(CoreAudioInputDevices().inputDevices().first { $0.id == uid })
    }

    private func nativeFormat(of device: AudioInputDevice) -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(device.objectID, &address, 0, nil, &size, &format)
        XCTAssertEqual(status, noErr)
        return format
    }
}
