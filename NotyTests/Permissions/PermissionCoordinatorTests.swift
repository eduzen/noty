import AVFoundation
@testable import Noty
import XCTest

final class PermissionCoordinatorTests: XCTestCase {
    func testNotDeterminedMicrophoneIsRequestedDuringPreparation() async throws {
        let microphone = FakeMicrophone(status: .notDetermined, requestResult: true)
        let coordinator = PermissionCoordinator(
            microphone: microphone,
            audioInputEntitlement: FakeEntitlement(present: true)
        )

        let grant = try await coordinator.prepareForRecording()

        XCTAssertTrue(grant.microphone)
        XCTAssertEqual(microphone.requestCount, 1)
    }

    func testAuthorizedMicrophoneProducesGrantWithoutPrompting() async throws {
        let microphone = FakeMicrophone(status: .authorized)
        let coordinator = PermissionCoordinator(
            microphone: microphone,
            audioInputEntitlement: FakeEntitlement(present: true)
        )

        let grant = try await coordinator.prepareForRecording()

        XCTAssertTrue(grant.microphone)
        XCTAssertEqual(microphone.requestCount, 0)
    }

    func testDeniedMicrophoneHasActionableSettingsURL() async {
        let coordinator = PermissionCoordinator(
            microphone: FakeMicrophone(status: .denied),
            audioInputEntitlement: FakeEntitlement(present: true)
        )

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
    }

    func testMicrophoneDeniedAtPromptIsActionable() async {
        let coordinator = PermissionCoordinator(
            microphone: FakeMicrophone(status: .notDetermined, requestResult: false),
            audioInputEntitlement: FakeEntitlement(present: true)
        )

        do {
            _ = try await coordinator.prepareForRecording()
            XCTFail("Expected denied microphone issue")
        } catch let issue as RecordingIssue {
            XCTAssertEqual(issue.code, "permission.microphone-denied")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRestrictedMicrophoneAndMissingEntitlementAreActionable() async {
        let restricted = PermissionCoordinator(
            microphone: FakeMicrophone(status: .restricted),
            audioInputEntitlement: FakeEntitlement(present: true)
        )
        do {
            _ = try await restricted.prepareForRecording()
            XCTFail("Expected restricted issue")
        } catch let issue as RecordingIssue {
            XCTAssertEqual(issue.code, "permission.microphone-restricted")
            XCTAssertNotNil(issue.recoveryURL)
        } catch { XCTFail("Unexpected error: \(error)") }

        let missing = PermissionCoordinator(
            microphone: FakeMicrophone(status: .authorized),
            audioInputEntitlement: FakeEntitlement(present: false)
        )
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

private struct FakeEntitlement: AudioInputEntitlementProviding {
    let isPresent: Bool
    init(present: Bool) {
        isPresent = present
    }
}
