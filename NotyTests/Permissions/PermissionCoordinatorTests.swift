import AVFoundation
import XCTest
@testable import Noty

final class PermissionCoordinatorTests: XCTestCase {
    func testNotDeterminedMicrophoneIsRequestedDuringPreparation() async throws {
        let microphone = FakeMicrophone(status: .notDetermined, requestResult: true)
        let screen = FakeScreenRecording(authorized: true)
        let coordinator = PermissionCoordinator(microphone: microphone, screenRecording: screen, audioInputEntitlement: FakeEntitlement(present: true))

        let grant = try await coordinator.prepareForRecording()

        XCTAssertTrue(grant.microphone)
        XCTAssertEqual(microphone.requestCount, 1)
        XCTAssertEqual(screen.requestCount, 0)
    }
    func testAuthorizedPermissionsProduceGrantWithoutPrompting() async throws {
        let microphone = FakeMicrophone(status: .authorized)
        let screen = FakeScreenRecording(authorized: true)
        let coordinator = PermissionCoordinator(microphone: microphone, screenRecording: screen, audioInputEntitlement: FakeEntitlement(present: true))

        let grant = try await coordinator.prepareForRecording()

        XCTAssertTrue(grant.microphone)
        XCTAssertTrue(grant.screenRecording)
        XCTAssertEqual(microphone.requestCount, 0)
        XCTAssertEqual(screen.requestCount, 0)
    }


    func testDeniedMicrophoneHasActionableSettingsURLAndDoesNotRequestScreenPermission() async {
        let screen = FakeScreenRecording(authorized: false)
        let coordinator = PermissionCoordinator(microphone: FakeMicrophone(status: .denied), screenRecording: screen, audioInputEntitlement: FakeEntitlement(present: true))

        do {
            _ = try await coordinator.prepareForRecording()
            XCTFail("Expected denied microphone issue")
        } catch let issue as RecordingIssue {
            XCTAssertEqual(issue.code, "permission.microphone-denied")
            XCTAssertNotNil(issue.recoveryURL)
            XCTAssertTrue(issue.message.contains("Microphone"))
            XCTAssertTrue(issue.isRetryAllowed)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(screen.requestCount, 0)
    }

    func testAuthorizedMicrophoneAndDeniedScreenRecordingRemainSeparate() async {
        let screen = FakeScreenRecording(authorized: false, requestResult: false)
        let coordinator = PermissionCoordinator(microphone: FakeMicrophone(status: .authorized), screenRecording: screen, audioInputEntitlement: FakeEntitlement(present: true))

        do {
            _ = try await coordinator.prepareForRecording()
            XCTFail("Expected Screen Recording issue")
        } catch let issue as RecordingIssue {
            XCTAssertEqual(issue.code, "permission.screen-recording-denied")
            XCTAssertNotNil(issue.recoveryURL)
            XCTAssertTrue(issue.message.contains("Screen & System Audio Recording"))
            XCTAssertEqual(screen.requestCount, 1)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testNewlyGrantedScreenRecordingRequiresRelaunch() async {
        let screen = FakeScreenRecording(authorized: false, requestResult: true)
        let coordinator = PermissionCoordinator(microphone: FakeMicrophone(status: .authorized), screenRecording: screen, audioInputEntitlement: FakeEntitlement(present: true))

        do {
            _ = try await coordinator.prepareForRecording()
            XCTFail("Expected relaunch issue")
        } catch let issue as RecordingIssue {
            XCTAssertEqual(issue.code, "permission.screen-recording-relaunch-required")
            XCTAssertNotNil(issue.recoveryURL)
            XCTAssertTrue(issue.message.contains("reopen Noty"))
            XCTAssertFalse(issue.isRetryAllowed)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRestrictedMicrophoneAndMissingEntitlementAreActionable() async {
        let restricted = PermissionCoordinator(microphone: FakeMicrophone(status: .restricted), screenRecording: FakeScreenRecording(authorized: true), audioInputEntitlement: FakeEntitlement(present: true))
        do {
            _ = try await restricted.prepareForRecording()
            XCTFail("Expected restricted issue")
        } catch let issue as RecordingIssue {
            XCTAssertEqual(issue.code, "permission.microphone-restricted")
            XCTAssertNotNil(issue.recoveryURL)
        } catch { XCTFail("Unexpected error: \(error)") }

        let missing = PermissionCoordinator(microphone: FakeMicrophone(status: .authorized), screenRecording: FakeScreenRecording(authorized: true), audioInputEntitlement: FakeEntitlement(present: false))
        do {
            _ = try await missing.prepareForRecording()
            XCTFail("Expected missing entitlement issue")
        } catch let issue as RecordingIssue {
            XCTAssertEqual(issue.code, "permission.audio-input-entitlement-missing")
            XCTAssertTrue(issue.message.contains("Audio Input"))
        } catch { XCTFail("Unexpected error: \(error)") }
    }
}

private final class FakeMicrophone: MicrophonePermissionProviding {
    let authorizationStatus: AVAuthorizationStatus
    let requestResult: Bool
    private(set) var requestCount = 0

    init(status: AVAuthorizationStatus, requestResult: Bool = false) {
        authorizationStatus = status
        self.requestResult = requestResult
    }

    func requestAccess() async -> Bool {
        requestCount += 1
        return requestResult
    }
}

private final class FakeScreenRecording: ScreenRecordingPermissionProviding {
    let isAuthorized: Bool
    let requestResult: Bool
    private(set) var requestCount = 0

    init(authorized: Bool, requestResult: Bool = false) {
        isAuthorized = authorized
        self.requestResult = requestResult
    }

    func requestAccess() -> Bool {
        requestCount += 1
        return requestResult
    }
}

private struct FakeEntitlement: AudioInputEntitlementProviding {
    let isPresent: Bool
    init(present: Bool) { isPresent = present }
}
