import Foundation
import ScreenCaptureKit

struct ScreenCaptureError: Error, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case permissionDenied
        case interrupted
        case microphoneDisconnected
        case unexpected
    }

    let kind: Kind
    let issue: RecordingIssue

    static func map(_ error: Error) -> ScreenCaptureError {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain,
           nsError.code == -3801 {
            return ScreenCaptureError(
                kind: .permissionDenied,
                issue: RecordingIssue(
                    code: "capture.screen-recording-denied",
                    message: "Screen Recording permission is required to capture audio.",
                    recoveryURL: URL(
                        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                    ),
                    isRetryAllowed: true
                )
            )
        }

        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == NSUserCancelledError {
            return ScreenCaptureError(
                kind: .interrupted,
                issue: RecordingIssue(
                    code: "capture.interrupted",
                    message: "Audio capture was interrupted.",
                    isRetryAllowed: true
                )
            )
        }

        return ScreenCaptureError(
            kind: .unexpected,
            issue: RecordingIssue(
                code: "capture.stream-failed",
                message: error.localizedDescription,
                isRetryAllowed: true
            )
        )
    }
}
