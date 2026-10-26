import Foundation

protocol CaptureService: AnyObject {
    var packets: AsyncThrowingStream<CapturedAudioPacket, Error> { get }
    var terminations: AsyncStream<CaptureTermination> { get }
    func start() async throws
    func stop() async
}

enum CaptureTermination: Equatable, Sendable {
    case userStopped
    case systemAudioDenied(RecordingIssue)
    case interrupted(RecordingIssue)
    case microphoneDisconnected(RecordingIssue)
    case unexpected(RecordingIssue)
    case queueOverflow(RecordingIssue)
}

enum CaptureServiceError: Error, Equatable, Sendable {
    case alreadyStarted
    case notStarted
    case systemAudioDenied
    case microphoneUnavailable
    case invalidAudioFormat
    case queueOverflow
    case streamFailure(String)
}

/// System Settings deep links for the permissions capture needs.
enum CaptureSettingsLinks {
    /// "System Audio Recording Only" (Core Audio taps). Screen Recording is not required.
    static let systemAudio = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
    )
}
