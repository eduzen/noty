import AVFoundation
import CoreGraphics
import Foundation
import Security

protocol MicrophonePermissionProviding {
    var authorizationStatus: AVAuthorizationStatus { get }
    func requestAccess() async -> Bool
}

protocol ScreenRecordingPermissionProviding {
    var isAuthorized: Bool { get }
    func requestAccess() -> Bool
}

protocol AudioInputEntitlementProviding {
    var isPresent: Bool { get }
}

struct PermissionGrant: Equatable, Sendable {
    let microphone: Bool
    let screenRecording: Bool
}

struct SystemMicrophonePermissionProvider: MicrophonePermissionProviding {
    var authorizationStatus: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}

struct SystemScreenRecordingPermissionProvider: ScreenRecordingPermissionProviding {
    var isAuthorized: Bool { CGPreflightScreenCaptureAccess() }
    func requestAccess() -> Bool { CGRequestScreenCaptureAccess() }
}

struct SystemAudioInputEntitlementProvider: AudioInputEntitlementProviding {
    var isPresent: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.security.device.microphone" as CFString, nil) else {
            return false
        }
        return (value as? Bool) == true
    }
}

struct PermissionCoordinator {
    private let microphone: MicrophonePermissionProviding
    private let screenRecording: ScreenRecordingPermissionProviding
    private let audioInputEntitlement: AudioInputEntitlementProviding

    init(
        microphone: MicrophonePermissionProviding = SystemMicrophonePermissionProvider(),
        screenRecording: ScreenRecordingPermissionProviding = SystemScreenRecordingPermissionProvider(),
        audioInputEntitlement: AudioInputEntitlementProviding = SystemAudioInputEntitlementProvider()
    ) {
        self.microphone = microphone
        self.screenRecording = screenRecording
        self.audioInputEntitlement = audioInputEntitlement
    }

    func prepareForRecording() async throws -> PermissionGrant {
        guard audioInputEntitlement.isPresent else {
            throw RecordingIssue(
                code: "permission.audio-input-entitlement-missing",
                message: "Noty is missing its Audio Input entitlement. Reinstall or rebuild Noty with Audio Input enabled.",
                isRetryAllowed: false
            )
        }

        switch microphone.authorizationStatus {
        case .notDetermined:
            guard await microphone.requestAccess() else { throw Self.microphoneDenied() }
        case .authorized:
            break
        case .denied:
            throw Self.microphoneDenied()
        case .restricted:
            throw RecordingIssue(
                code: "permission.microphone-restricted",
                message: "Microphone access is restricted by this Mac. Ask your administrator to allow microphone access.",
                recoveryURL: Self.privacySettingsURL,
                isRetryAllowed: false
            )
        @unknown default:
            throw RecordingIssue(
                code: "permission.microphone-unavailable",
                message: "Noty could not determine microphone access. Check Microphone privacy settings and try again.",
                recoveryURL: Self.privacySettingsURL,
                isRetryAllowed: true
            )
        }

        guard screenRecording.isAuthorized else {
            if screenRecording.requestAccess() {
                throw RecordingIssue(
                    code: "permission.screen-recording-relaunch-required",
                    message: "Screen Recording access was granted. Quit and reopen Noty before starting a recording.",
                    recoveryURL: Self.screenRecordingSettingsURL,
                    isRetryAllowed: false
                )
            }
            throw RecordingIssue(
                code: "permission.screen-recording-denied",
                message: "Allow Noty in System Settings → Privacy & Security → Screen & System Audio Recording, then try again.",
                recoveryURL: Self.screenRecordingSettingsURL,
                isRetryAllowed: true
            )
        }

        return PermissionGrant(microphone: true, screenRecording: true)
    }

    private static func microphoneDenied() -> RecordingIssue {
        RecordingIssue(
            code: "permission.microphone-denied",
            message: "Allow Noty to use the microphone in System Settings → Privacy & Security → Microphone, then try again.",
            recoveryURL: privacySettingsURL,
            isRetryAllowed: true
        )
    }

    private static let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    private static let screenRecordingSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
}
